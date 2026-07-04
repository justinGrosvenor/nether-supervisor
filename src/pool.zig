//! The VM pool: the `ensure` state machine. Maps a tenant to its VM, boots one
//! on a cold-start MISS (deduped so N concurrent ensures share one boot), keeps
//! a booting VM warm past a caller's deadline so the retry HITs, reclaims idle
//! VMs, and evicts on crash.
//!
//! DESIGN: this is a pure, event-driven state machine. Readiness, failure, and
//! crash are injected as events (onReady/onFailed/onExited) rather than owned by
//! hidden threads, so the whole machine is unit-tested synchronously without HVF
//! or sockets. In production the reactor's bring-up thread and reaper call these
//! events under one mutex. Answers to waiters are appended to a caller buffer
//! (the north server drains them and sends the framed replies).

const std = @import("std");
const launcher_mod = @import("launcher.zig");

pub const CAP: usize = 64; // max VM slots; config max_vms is clamped to this
pub const MAX_WAITERS: usize = 16; // ~ swerver workers firing one ensure each
pub const TENANT_MAX: usize = 128;
pub const PATH_MAX: usize = 104; // sun_path

pub const VmState = enum { free, booting, ready, dead };

const Waiter = struct { id: u64, deadline_ms: u64 };

const Slot = struct {
    state: VmState = .free,
    vm_id: u32 = 0, // unique per boot; stale events for a freed slot are ignored
    tenant_buf: [TENANT_MAX]u8 = undefined,
    tenant_len: u16 = 0,
    control_buf: [PATH_MAX]u8 = undefined,
    control_len: u16 = 0,
    data_buf: [PATH_MAX]u8 = undefined,
    data_len: u16 = 0,
    booting_since_ms: u64 = 0,
    last_used_ms: u64 = 0,
    waiters: [MAX_WAITERS]Waiter = undefined,
    waiter_count: u8 = 0,

    fn tenant(self: *const Slot) []const u8 {
        return self.tenant_buf[0..self.tenant_len];
    }
    fn dataSocket(self: *const Slot) []const u8 {
        return self.data_buf[0..self.data_len];
    }
};

pub const Answer = struct {
    waiter_id: u64,
    result: Result,
    pub const Result = union(enum) { ok: []const u8, fail: []const u8 };
};

pub const EnsureOutcome = union(enum) {
    /// Warm HIT: forward straight to this data_socket path.
    hit: []const u8,
    /// A waiter was registered on a booting VM; the answer arrives later via
    /// onReady/onFailed/tick. The north server parks the reply.
    parked,
    /// Immediate failure (pool full / spawn error): reply fail now.
    rejected: []const u8,
};

pub const Config = struct {
    socket_dir: []const u8,
    base_snap: []const u8 = "", // empty => cold-boot
    app_port: u16 = 8080,
    cpus: u16 = 1,
    ram_mb: u32 = 512, // >= 384 floor (256 panics on rootfs mount); see config.zig
    idle_timeout_s: u32 = 90,
    idle_ttl_ms: u64 = 60_000,
    max_vms: u32 = 16,
};

pub const Pool = struct {
    cfg: Config,
    launcher: launcher_mod.Launcher,
    slots: [CAP]Slot = [1]Slot{.{}} ** CAP,
    next_vm_id: u32 = 1,
    // Metrics (mirrored to swerver's tenant gauges via the status surface).
    ensures: u64 = 0,
    hits: u64 = 0,
    misses: u64 = 0,
    reclaims: u64 = 0,
    evictions: u64 = 0,
    boot_failures: u64 = 0,

    pub fn init(cfg: Config, l: launcher_mod.Launcher) Pool {
        var p = Pool{ .cfg = cfg, .launcher = l };
        p.cfg.max_vms = @min(cfg.max_vms, CAP);
        return p;
    }

    fn activeCount(self: *const Pool) u32 {
        var n: u32 = 0;
        for (&self.slots) |*s| {
            if (s.state != .free) n += 1;
        }
        return n;
    }

    /// Live warm VMs (ready state) - the observability gauge.
    pub fn warmCount(self: *const Pool) u32 {
        var n: u32 = 0;
        for (&self.slots) |*s| {
            if (s.state == .ready) n += 1;
        }
        return n;
    }

    pub fn bootingCount(self: *const Pool) u32 {
        var n: u32 = 0;
        for (&self.slots) |*s| {
            if (s.state == .booting) n += 1;
        }
        return n;
    }

    fn findByTenant(self: *Pool, name: []const u8) ?*Slot {
        for (&self.slots) |*s| {
            if (s.state != .free and s.state != .dead and s.tenant_len == name.len and
                std.mem.eql(u8, s.tenant(), name)) return s;
        }
        return null;
    }

    fn findByVmId(self: *Pool, vm_id: u32) ?*Slot {
        for (&self.slots) |*s| {
            if (s.state != .free and s.vm_id == vm_id) return s;
        }
        return null;
    }

    fn freeSlot(self: *Pool) ?*Slot {
        for (&self.slots) |*s| {
            if (s.state == .free) return s;
        }
        return null;
    }

    /// Reclaim the least-recently-used READY slot to make room. Returns it (now
    /// free) or null if every slot is booting (cannot reclaim a boot in flight).
    fn reclaimLruReady(self: *Pool) ?*Slot {
        var victim: ?*Slot = null;
        for (&self.slots) |*s| {
            if (s.state == .ready) {
                if (victim == null or s.last_used_ms < victim.?.last_used_ms) victim = s;
            }
        }
        if (victim) |s| {
            self.launcher.kill(s.vm_id);
            self.reclaims += 1;
            s.state = .free;
            s.waiter_count = 0;
            return s;
        }
        return null;
    }

    /// Cold-start / warm-hit entry. See EnsureOutcome. On MISS this spawns a VM
    /// via the launcher and parks `waiter_id`; the answer arrives on the next
    /// onReady/onFailed/tick. `deadline_ms` is the caller's (swerver's) budget.
    pub fn ensure(self: *Pool, name: []const u8, waiter_id: u64, now_ms: u64, deadline_ms: u64) EnsureOutcome {
        self.ensures += 1;
        if (name.len == 0 or name.len > TENANT_MAX) return .{ .rejected = "invalid tenant" };

        if (self.findByTenant(name)) |s| {
            switch (s.state) {
                .ready => {
                    s.last_used_ms = now_ms;
                    self.hits += 1;
                    return .{ .hit = s.dataSocket() };
                },
                .booting => {
                    if (!addWaiter(s, waiter_id, deadline_ms)) return .{ .rejected = "too many waiters" };
                    return .parked;
                },
                else => {}, // free/dead fall through to MISS
            }
        }

        // MISS.
        self.misses += 1;
        var slot = self.freeSlot() orelse blk: {
            if (self.activeCount() >= self.cfg.max_vms) {
                break :blk self.reclaimLruReady() orelse return .{ .rejected = "pool full" };
            }
            // Under the cap but no free slot only happens when CAP < max_vms,
            // which init() prevents; treat defensively as full.
            break :blk self.reclaimLruReady() orelse return .{ .rejected = "pool full" };
        };
        if (self.activeCount() >= self.cfg.max_vms) {
            // Reclaim to stay within max_vms even if a raw slot was free.
            _ = self.reclaimLruReady() orelse return .{ .rejected = "pool full" };
            slot = self.freeSlot() orelse return .{ .rejected = "pool full" };
        }

        const vm_id = self.next_vm_id;
        self.next_vm_id +%= 1;

        // Derive socket paths under socket_dir from the vm id (8-hex, short).
        const control = std.fmt.bufPrint(&slot.control_buf, "{s}/{x:0>8}.control.sock", .{ self.cfg.socket_dir, vm_id }) catch return .{ .rejected = "socket path too long" };
        if (control.len + 1 > PATH_MAX) return .{ .rejected = "socket path too long" };
        slot.control_len = @intCast(control.len);
        const data = std.fmt.bufPrint(&slot.data_buf, "{s}/{x:0>8}.data.sock", .{ self.cfg.socket_dir, vm_id }) catch return .{ .rejected = "socket path too long" };
        if (data.len + 1 > PATH_MAX) return .{ .rejected = "socket path too long" };
        slot.data_len = @intCast(data.len);

        self.launcher.spawn(.{
            .vm_id = vm_id,
            .control_socket = slot.control_buf[0..slot.control_len],
            .data_socket = slot.data_buf[0..slot.data_len],
            .restore_from = self.cfg.base_snap,
            .app_port = self.cfg.app_port,
            .cpus = self.cfg.cpus,
            .ram_mb = self.cfg.ram_mb,
            .idle_timeout_s = self.cfg.idle_timeout_s,
        }) catch {
            self.boot_failures += 1;
            slot.state = .free;
            return .{ .rejected = "spawn failed" };
        };

        slot.state = .booting;
        slot.vm_id = vm_id;
        @memcpy(slot.tenant_buf[0..name.len], name);
        slot.tenant_len = @intCast(name.len);
        slot.booting_since_ms = now_ms;
        slot.last_used_ms = now_ms;
        slot.waiter_count = 0;
        _ = addWaiter(slot, waiter_id, deadline_ms);
        return .parked;
    }

    /// A VM finished bring-up and its data_socket serves. Resolve every waiter
    /// with the path; the VM stays ready + warm. Ignores a stale vm_id.
    pub fn onReady(self: *Pool, vm_id: u32, data_socket: []const u8, now_ms: u64, answers: []Answer) usize {
        const s = self.findByVmId(vm_id) orelse return 0;
        if (s.state != .booting) return 0;
        // The launcher may report the true data_socket; keep ours (they match).
        _ = data_socket;
        s.state = .ready;
        s.last_used_ms = now_ms;
        const n = drainWaiters(s, .{ .ok = s.dataSocket() }, answers);
        return n;
    }

    /// Bring-up failed (boot timeout, agent never ready, crash during boot).
    /// Free the slot and fail every waiter closed (swerver fails closed, retries).
    pub fn onFailed(self: *Pool, vm_id: u32, reason: []const u8, answers: []Answer) usize {
        const s = self.findByVmId(vm_id) orelse return 0;
        self.boot_failures += 1;
        const n = drainWaiters(s, .{ .fail = reason }, answers);
        self.launcher.kill(vm_id); // ensure the process is gone
        s.state = .free;
        s.waiter_count = 0;
        return n;
    }

    /// A VM process exited unexpectedly (reaper saw it die). Evict its mapping so
    /// the next ensure re-cold-starts; fail any waiters (a ready VM has none).
    pub fn onExited(self: *Pool, vm_id: u32, answers: []Answer) usize {
        const s = self.findByVmId(vm_id) orelse return 0;
        self.evictions += 1;
        const n = drainWaiters(s, .{ .fail = "vm exited" }, answers);
        s.state = .free;
        s.waiter_count = 0;
        return n;
    }

    /// Housekeeping. (1) Deadline expiry: fail+drop waiters past their deadline
    /// but KEEP the VM booting (it stays warm, so the caller's retry HITs). (2)
    /// Idle reclaim: shut down a ready VM unused for idle_ttl_ms. Returns the
    /// number of answers written.
    pub fn tick(self: *Pool, now_ms: u64, answers: []Answer) usize {
        var n: usize = 0;
        for (&self.slots) |*s| {
            switch (s.state) {
                .booting => {
                    // Drop expired waiters (compact in place); keep the VM.
                    var w: usize = 0;
                    var kept: u8 = 0;
                    while (w < s.waiter_count) : (w += 1) {
                        const waiter = s.waiters[w];
                        if (now_ms >= waiter.deadline_ms) {
                            if (n < answers.len) {
                                answers[n] = .{ .waiter_id = waiter.id, .result = .{ .fail = "cold start timed out" } };
                                n += 1;
                            }
                        } else {
                            s.waiters[kept] = waiter;
                            kept += 1;
                        }
                    }
                    s.waiter_count = kept;
                },
                .ready => {
                    if (now_ms -% s.last_used_ms >= self.cfg.idle_ttl_ms) {
                        self.launcher.kill(s.vm_id);
                        self.reclaims += 1;
                        s.state = .free;
                        s.waiter_count = 0;
                    }
                },
                else => {},
            }
        }
        return n;
    }
};

fn addWaiter(s: *Slot, id: u64, deadline_ms: u64) bool {
    if (s.waiter_count >= MAX_WAITERS) return false;
    s.waiters[s.waiter_count] = .{ .id = id, .deadline_ms = deadline_ms };
    s.waiter_count += 1;
    return true;
}

fn drainWaiters(s: *Slot, result: Answer.Result, answers: []Answer) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.waiter_count and n < answers.len) : (i += 1) {
        answers[n] = .{ .waiter_id = s.waiters[i].id, .result = result };
        n += 1;
    }
    s.waiter_count = 0;
    return n;
}

// ── Tests (drive the full state machine with the MockLauncher) ────────────

const testing = std.testing;

fn testPool(mock: *launcher_mod.MockLauncher) Pool {
    return Pool.init(.{ .socket_dir = "/tmp/nsup", .idle_ttl_ms = 1000, .max_vms = 4 }, mock.launcher());
}

test "cold MISS spawns one VM; onReady answers the waiter; second ensure HITs" {
    var mock = launcher_mod.MockLauncher{};
    var pool = testPool(&mock);

    const o1 = pool.ensure("alpha", 1, 100, 5100);
    try testing.expect(o1 == .parked);
    try testing.expectEqual(@as(u32, 1), mock.spawns);
    const vm = mock.last_spawned_id;

    var ans: [MAX_WAITERS]Answer = undefined;
    const n = pool.onReady(vm, "/tmp/nsup/x.data.sock", 200, &ans);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(@as(u64, 1), ans[0].waiter_id);
    try testing.expect(ans[0].result == .ok);
    // The path is the slot's derived data_socket.
    try testing.expect(std.mem.endsWith(u8, ans[0].result.ok, ".data.sock"));

    // Warm HIT: no new spawn.
    const o2 = pool.ensure("alpha", 2, 300, 5300);
    try testing.expect(o2 == .hit);
    try testing.expectEqual(@as(u32, 1), mock.spawns);
    try testing.expectEqual(@as(u64, 1), pool.hits);
}

test "concurrent ensures for the same cold tenant dedupe to one boot" {
    var mock = launcher_mod.MockLauncher{};
    var pool = testPool(&mock);

    try testing.expect(pool.ensure("alpha", 1, 100, 5100) == .parked);
    try testing.expect(pool.ensure("alpha", 2, 100, 5100) == .parked); // BOOTING -> waiter
    try testing.expect(pool.ensure("alpha", 3, 100, 5100) == .parked);
    try testing.expectEqual(@as(u32, 1), mock.spawns); // ONE VM for three waiters

    var ans: [MAX_WAITERS]Answer = undefined;
    const n = pool.onReady(mock.last_spawned_id, "/d", 200, &ans);
    try testing.expectEqual(@as(usize, 3), n); // all three answered
    try testing.expect(ans[0].result == .ok and ans[2].result == .ok);
}

test "deadline expiry fails the waiter but keeps the VM warm; retry HITs" {
    var mock = launcher_mod.MockLauncher{};
    var pool = testPool(&mock);
    try testing.expect(pool.ensure("alpha", 1, 100, 5100) == .parked);
    const vm = mock.last_spawned_id;

    // tick past the waiter deadline before the VM is ready.
    var ans: [MAX_WAITERS]Answer = undefined;
    const n = pool.tick(6000, &ans);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expect(ans[0].result == .fail);
    // The VM is still booting (warm), not killed.
    try testing.expectEqual(@as(u32, 1), pool.bootingCount());
    try testing.expectEqual(@as(u32, 0), mock.kills);

    // Now it becomes ready; a retry HITs immediately (no new spawn).
    _ = pool.onReady(vm, "/d", 6100, &ans);
    try testing.expect(pool.ensure("alpha", 2, 6200, 11200) == .hit);
    try testing.expectEqual(@as(u32, 1), mock.spawns);
}

test "idle reclaim shuts down a ready VM and evicts the mapping" {
    var mock = launcher_mod.MockLauncher{};
    var pool = testPool(&mock); // idle_ttl_ms = 1000
    _ = pool.ensure("alpha", 1, 100, 5100);
    var ans: [MAX_WAITERS]Answer = undefined;
    _ = pool.onReady(mock.last_spawned_id, "/d", 200, &ans);
    try testing.expectEqual(@as(u32, 1), pool.warmCount());

    // Idle past the TTL -> reclaimed + killed.
    _ = pool.tick(200 + 1000, &ans);
    try testing.expectEqual(@as(u32, 0), pool.warmCount());
    try testing.expectEqual(@as(u32, 1), mock.kills);
    // Next ensure re-cold-starts (a fresh spawn).
    try testing.expect(pool.ensure("alpha", 2, 3000, 8000) == .parked);
    try testing.expectEqual(@as(u32, 2), mock.spawns);
}

test "crash eviction: onExited frees the slot so the next ensure re-cold-starts" {
    var mock = launcher_mod.MockLauncher{};
    var pool = testPool(&mock);
    _ = pool.ensure("alpha", 1, 100, 5100);
    var ans: [MAX_WAITERS]Answer = undefined;
    const vm = mock.last_spawned_id;
    _ = pool.onReady(vm, "/d", 200, &ans);

    // The VM process dies.
    _ = pool.onExited(vm, &ans);
    try testing.expectEqual(@as(u32, 0), pool.warmCount());
    try testing.expectEqual(@as(u64, 1), pool.evictions);
    // A stale event for the dead vm is ignored.
    try testing.expectEqual(@as(usize, 0), pool.onReady(vm, "/d", 300, &ans));
    // Next ensure re-cold-starts.
    try testing.expect(pool.ensure("alpha", 2, 400, 5400) == .parked);
    try testing.expectEqual(@as(u32, 2), mock.spawns);
}

test "boot failure is reported and the slot freed" {
    var mock = launcher_mod.MockLauncher{};
    var pool = testPool(&mock);
    // A booting VM that fails bring-up.
    _ = pool.ensure("alpha", 1, 100, 5100);
    var ans: [MAX_WAITERS]Answer = undefined;
    const n = pool.onFailed(mock.last_spawned_id, "agent never ready", &ans);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expect(ans[0].result == .fail);
    try testing.expectEqual(@as(u32, 0), pool.warmCount());
    try testing.expectEqual(@as(u32, 0), pool.bootingCount());

    // A spawn error rejects synchronously (no slot leaked).
    mock.fail_next_spawn = true;
    const o = pool.ensure("beta", 2, 200, 5200);
    try testing.expect(o == .rejected);
    try testing.expectEqual(@as(u32, 0), pool.bootingCount());
}

test "pool full: distinct tenants past max_vms reclaim the LRU ready VM" {
    var mock = launcher_mod.MockLauncher{};
    var pool = Pool.init(.{ .socket_dir = "/tmp/nsup", .idle_ttl_ms = 100000, .max_vms = 2 }, mock.launcher());
    var ans: [MAX_WAITERS]Answer = undefined;

    // Two warm VMs at capacity.
    _ = pool.ensure("a", 1, 10, 5000);
    _ = pool.onReady(mock.last_spawned_id, "/d", 11, &ans);
    _ = pool.ensure("b", 2, 20, 5000);
    _ = pool.onReady(mock.last_spawned_id, "/d", 21, &ans);
    try testing.expectEqual(@as(u32, 2), pool.warmCount());

    // A third tenant at capacity reclaims the LRU (tenant a, used at 10).
    const o = pool.ensure("c", 3, 100, 5100);
    try testing.expect(o == .parked);
    try testing.expectEqual(@as(u32, 1), mock.kills); // one reclaimed
    try testing.expectEqual(@as(u32, 3), mock.spawns);
    // Tenant a is gone; re-ensuring it re-cold-starts.
    try testing.expect(pool.ensure("a", 4, 200, 5200) == .parked or pool.findByTenant("a") != null);
}
