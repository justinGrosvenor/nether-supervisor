//! Wires the RealLauncher to the pool state machine and runs the north control
//! loop. Bring-up is ASYNC: the north accept loop spawns one thread per swerver
//! connection, so a multi-second cold boot on one tenant never blocks ensures on
//! another. Concurrent ensures for the SAME cold tenant dedupe to one boot - the
//! first caller becomes the bring-up owner (drives the VM to serving off-lock);
//! the rest poll the pool until the owner marks it ready. A spinlock guards the
//! pool + the owner claim (held only for the microsecond state transitions; the
//! slow I/O runs outside it). A housekeeping thread ticks idle-reclaim/deadline.

const std = @import("std");
const c = std.c;
const config = @import("config.zig");
const os = @import("os.zig");
const proto = @import("proto.zig");
const pool_mod = @import("pool.zig");
const launcher_mod = @import("launcher.zig");
const boot = @import("boot.zig");
const control_client = @import("control_client.zig");
const control_server = @import("control_server.zig");
const status = @import("status.zig");
const log = @import("log.zig");
const Lock = @import("lock.zig").Lock;

/// Housekeeping cadence: reap + idle-reclaim + waiter-deadline sweep.
const HOUSEKEEP_MS: u64 = 250;
/// Waiter poll interval while its bring-up owner drives the boot.
const WAITER_POLL_MS: u64 = 10;

/// Set by SIGTERM/SIGINT (async-signal-safe: a single atomic store). The
/// housekeeping thread observes it and drives graceful teardown.
var g_shutdown = std.atomic.Value(bool).init(false);

fn handleShutdownSignal(_: std.posix.SIG) callconv(.c) void {
    g_shutdown.store(true, .release);
}

/// Tracks a spawned VM process so the launcher can kill it and bring-up can find
/// its sockets. Indexed alongside pool slots by vm_id.
const VmProc = struct {
    active: bool = false,
    vm_id: u32 = 0,
    pid: c.pid_t = 0,
    /// Set once when a connection thread claims the bring-up for this VM, so
    /// concurrent ensures for the same cold tenant produce exactly one driver.
    bringup_started: bool = false,
};

pub const Supervisor = struct {
    cfg: config.Config,
    pool: pool_mod.Pool = undefined,
    real: boot.RealLauncher,
    vms: [pool_mod.CAP]VmProc = [1]VmProc{.{}} ** pool_mod.CAP,
    next_waiter: u64 = 1,
    listen_fd: std.posix.fd_t = -1,
    /// Backs the absolute base-snapshot path once baked (nether jails the
    /// snapshot into the base VM cwd, so the real fork source is derived, not
    /// the config value). cfg/pool base_snap slices point in here after bake.
    base_snap_buf: [512]u8 = undefined,
    /// Guards the pool + the vms[] bring-up-owner claim across connection
    /// threads and the housekeeping thread. Held only for state transitions.
    lock: Lock = .{},
    /// The optional /status + /metrics surface (lives here so its thread has a
    /// stable pointer). Only initialized + started when status_addr is set.
    status_server: status.Server = undefined,

    /// Reserved vm id for the transient base VM (the pool issues ids from 1).
    const BASE_ID: u32 = 0;

    pub fn init(cfg: config.Config) Supervisor {
        return .{
            .cfg = cfg,
            .real = .{
                .nether_bin = cfg.nether_bin,
                .kernels_dir = cfg.kernels_dir,
                .work_root = cfg.work_root,
                .app_port = cfg.app_port,
                .cpus = cfg.cpus,
                .ram_mb = cfg.ram_mb,
                .idle_timeout_s = cfg.idle_timeout_s,
            },
        };
    }

    /// Two-step init: the pool's launcher captures &self, so wire it once the
    /// Supervisor has a stable address.
    pub fn wire(self: *Supervisor) void {
        self.pool = pool_mod.Pool.init(.{
            .socket_dir = self.cfg.socket_dir,
            .base_snap = self.cfg.base_snap,
            .app_port = self.cfg.app_port,
            .cpus = self.cfg.cpus,
            .ram_mb = self.cfg.ram_mb,
            .idle_timeout_s = self.cfg.idle_timeout_s,
            .idle_ttl_ms = self.cfg.idle_ttl_ms,
            .max_vms = self.cfg.max_vms,
        }, self.launcher());
    }

    fn launcher(self: *Supervisor) launcher_mod.Launcher {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable = launcher_mod.Launcher.VTable{ .spawn = spawnImpl, .kill = killImpl };

    fn spawnImpl(ctx: *anyopaque, spec: launcher_mod.LaunchSpec) launcher_mod.LaunchError!void {
        const self: *Supervisor = @ptrCast(@alignCast(ctx));
        // Warm-fork when the pool handed us a base snapshot to restore from
        // (run() bakes it before accepting); otherwise cold-boot.
        const pid = if (spec.restore_from.len > 0)
            self.real.spawnFork(spec.vm_id, spec.control_socket, spec.data_socket, spec.restore_from) catch return error.SpawnFailed
        else
            self.real.spawnCold(spec.vm_id, spec.control_socket, spec.data_socket) catch return error.SpawnFailed;
        for (&self.vms) |*v| {
            if (!v.active) {
                v.* = .{ .active = true, .vm_id = spec.vm_id, .pid = pid };
                return;
            }
        }
        // No tracking slot: reap the process we just spawned and fail.
        os.killPid(pid, os.SIGTERM);
        return error.PoolFull;
    }

    fn killImpl(ctx: *anyopaque, vm_id: u32) void {
        const self: *Supervisor = @ptrCast(@alignCast(ctx));
        for (&self.vms) |*v| {
            if (v.active and v.vm_id == vm_id) {
                os.killPid(v.pid, os.SIGTERM);
                v.active = false;
                return;
            }
        }
    }

    /// Claim the bring-up for `vm_id`. Returns true for exactly the first caller
    /// (the owner, which drives the boot); false for later callers (waiters, who
    /// poll). MUST be called under self.lock.
    fn claimBringup(self: *Supervisor, vm_id: u32) bool {
        for (&self.vms) |*v| {
            if (v.active and v.vm_id == vm_id) {
                if (v.bringup_started) return false;
                v.bringup_started = true;
                return true;
            }
        }
        return false; // untracked: treat as non-owner (defensive)
    }

    fn nowMs() u64 {
        const ts = os.monotonicMs();
        return ts;
    }

    /// A consistent snapshot of the pool gauges for the status surface. Takes the
    /// lock so counts + counters are read atomically w.r.t. state transitions.
    fn snapshotGauges(self: *Supervisor) status.Gauges {
        self.lock.lock();
        defer self.lock.unlock();
        return .{
            .vms_warm = self.pool.warmCount(),
            .vms_booting = self.pool.bootingCount(),
            .ensures = self.pool.ensures,
            .hits = self.pool.hits,
            .misses = self.pool.misses,
            .reclaims = self.pool.reclaims,
            .evictions = self.pool.evictions,
            .boot_failures = self.pool.boot_failures,
        };
    }

    /// Provider callback for status.Server (casts the ctx back to *Supervisor).
    fn statusSnapshot(ctx: *anyopaque) status.Gauges {
        const self: *Supervisor = @ptrCast(@alignCast(ctx));
        return self.snapshotGauges();
    }

    /// Start the /status + /metrics surface on its own thread when configured.
    /// Parses status_addr as ip:port; a malformed addr disables it (logged).
    fn startStatus(self: *Supervisor) void {
        if (self.cfg.status_addr.len == 0) return;
        const colon = std.mem.lastIndexOfScalar(u8, self.cfg.status_addr, ':') orelse {
            log.err("status_addr '{s}' missing :port; status surface off", .{self.cfg.status_addr});
            return;
        };
        const port = std.fmt.parseInt(u16, self.cfg.status_addr[colon + 1 ..], 10) catch {
            log.err("status_addr '{s}' has a bad port; status surface off", .{self.cfg.status_addr});
            return;
        };
        self.status_server = .{
            .ip = self.cfg.status_addr[0..colon],
            .port = port,
            .service_key = self.cfg.status_service_key,
            .provider = .{ .ctx = self, .snapshot = statusSnapshot },
        };
        if (std.Thread.spawn(.{}, status.Server.run, .{&self.status_server})) |t| {
            t.detach();
        } else |e| log.warn("status thread not started: {s}", .{@errorName(e)});
    }

    /// Handle one `ensure <tenant>`. Warm HIT or immediate reject answer inline.
    /// On a cold MISS the caller either OWNS the boot (drives the VM to serving
    /// off-lock, then answers) or WAITS (polls the pool until the owner resolves
    /// it), so N concurrent ensures for one cold tenant share a single boot and
    /// the north loop is never blocked. Writes the framed reply into `out`.
    fn handleEnsure(self: *Supervisor, tenant: []const u8, out: []u8) []const u8 {
        const now = nowMs();
        const deadline = now + self.cfg.boot_budget_ms;

        self.lock.lock();
        const waiter = self.next_waiter;
        self.next_waiter += 1;
        const outcome = self.pool.ensure(tenant, waiter, now, deadline);
        switch (outcome) {
            .hit => |path| {
                const r = proto.buildReply(out, path, 0) catch out[0..0];
                self.lock.unlock();
                log.info("ensure {s}: HIT", .{tenant});
                return r;
            },
            .rejected => |reason| {
                const r = proto.buildReply(out, reason, 1) catch out[0..0];
                self.lock.unlock();
                log.warn("ensure {s}: rejected ({s})", .{ tenant, reason });
                return r;
            },
            .parked => {},
        }

        // Parked on a booting VM. Copy its sockets + decide ownership under lock;
        // the slot buffers can be reclaimed once we release it.
        const info = self.pool.bootingInfo(tenant) orelse {
            self.lock.unlock();
            return proto.buildReply(out, "no booting vm", 1) catch out[0..0];
        };
        var ctl_buf: [os.SUN_PATH_MAX]u8 = undefined;
        var data_buf: [os.SUN_PATH_MAX]u8 = undefined;
        @memcpy(ctl_buf[0..info.control_socket.len], info.control_socket);
        @memcpy(data_buf[0..info.data_socket.len], info.data_socket);
        const ctl = ctl_buf[0..info.control_socket.len];
        const data = data_buf[0..info.data_socket.len];
        const vm_id = info.vm_id;
        const owner = self.claimBringup(vm_id);
        self.lock.unlock();

        if (owner) return self.driveOwner(tenant, vm_id, ctl, data, out);
        return self.waitForOwner(tenant, deadline, out);
    }

    /// Bring-up OWNER: drive the just-spawned VM to serving off-lock, then flip
    /// the pool to ready (which also answers any waiters) and reply.
    fn driveOwner(self: *Supervisor, tenant: []const u8, vm_id: u32, ctl: []const u8, data: []const u8, out: []u8) []const u8 {
        const is_fork = self.cfg.base_snap.len > 0;
        log.info("ensure {s}: {s} vm={x}", .{ tenant, if (is_fork) "fork" else "cold boot", vm_id });

        var answers: [pool_mod.MAX_WAITERS]pool_mod.Answer = undefined;
        boot.bringUp(ctl, data, is_fork, self.cfg.guest_service_prestarted, self.cfg.boot_budget_ms, nowMs) catch |e| {
            log.err("ensure {s}: bring-up failed: {s}", .{ tenant, @errorName(e) });
            self.lock.lock();
            _ = self.pool.onFailed(vm_id, "bring-up failed", &answers);
            self.lock.unlock();
            return proto.buildReply(out, "cold start failed", 1) catch out[0..0];
        };

        self.lock.lock();
        _ = self.pool.onReady(vm_id, data, nowMs(), &answers);
        const r = proto.buildReply(out, data, 0) catch out[0..0];
        self.lock.unlock();
        log.info("ensure {s}: SERVING vm={x}", .{ tenant, vm_id });
        return r;
    }

    /// Bring-up WAITER: another connection owns this tenant's boot. Poll the pool
    /// until it goes ready (reply the path), the boot fails/evicts (fail closed),
    /// or our deadline passes (fail; the VM stays warm so the retry HITs).
    fn waitForOwner(self: *Supervisor, tenant: []const u8, deadline: u64, out: []u8) []const u8 {
        while (true) {
            sleepMs(WAITER_POLL_MS);
            self.lock.lock();
            var pbuf: [os.SUN_PATH_MAX]u8 = undefined;
            if (self.pool.readyPath(tenant, &pbuf)) |p| {
                const r = proto.buildReply(out, p, 0) catch out[0..0];
                self.lock.unlock();
                log.info("ensure {s}: SERVING (waited)", .{tenant});
                return r;
            }
            const still_booting = self.pool.isBooting(tenant);
            self.lock.unlock();
            if (!still_booting) return proto.buildReply(out, "cold start failed", 1) catch out[0..0];
            if (nowMs() > deadline) return proto.buildReply(out, "cold start timed out", 1) catch out[0..0];
        }
    }

    /// One north connection: read lines, dispatch, reply, until EOF.
    fn serveConn(self: *Supervisor, conn: std.posix.fd_t) void {
        var rbuf: [8192]u8 = undefined;
        var rlen: usize = 0;
        var out: [512]u8 = undefined;
        while (true) {
            const n = os.readSome(conn, rbuf[rlen..]) catch return;
            if (n == 0) return; // EOF
            rlen += n;
            // Process complete lines.
            while (std.mem.indexOfScalar(u8, rbuf[0..rlen], '\n')) |nl| {
                const line = std.mem.trim(u8, rbuf[0..nl], " \t\r");
                // Shift the remainder to the front.
                const rest = rbuf[nl + 1 .. rlen];
                std.mem.copyForwards(u8, rbuf[0..rest.len], rest);
                rlen = rest.len;

                if (line.len == 0) continue;
                if (std.mem.eql(u8, line, "__info__")) {
                    const r = proto.buildReply(&out, control_server.INFO_REPORT, 0) catch continue;
                    os.writeAll(conn, r) catch return;
                } else if (std.mem.startsWith(u8, line, "ensure")) {
                    var it = std.mem.tokenizeScalar(u8, line, ' ');
                    _ = it.next();
                    const tenant = it.next() orelse {
                        const r = proto.buildReply(&out, "ensure requires a tenant", 1) catch continue;
                        os.writeAll(conn, r) catch return;
                        continue;
                    };
                    const r = self.handleEnsure(tenant, &out);
                    os.writeAll(conn, r) catch return;
                } else {
                    const r = proto.buildReply(&out, "supervisor: unknown command", 127) catch continue;
                    os.writeAll(conn, r) catch return;
                }
            }
            if (rlen == rbuf.len) rlen = 0; // overlong line: drop (defensive)
        }
    }

    /// Bake the warm-fork base once at startup: cold-boot a base VM, drive it to
    /// serving, `__snapshot__` it to cfg.base_snap, then shut it down. Per-tenant
    /// ensures then fork from that snapshot (~76ms) instead of full cold boots.
    /// The base is NOT tracked in self.vms (it is transient and reaped here).
    /// Remove stale artifacts in the base VM's work dir (<work_root>/00000000/)
    /// so each bake starts pristine. spawnCold recreates the dir and its
    /// contents; a leftover base.snap in particular must not survive.
    fn cleanBaseDir(work_root: []const u8) void {
        for ([_][]const u8{ "base.snap", "nether.conf", "nether.log", "kernels" }) |name| {
            var buf: [600]u8 = undefined;
            const path = std.fmt.bufPrint(&buf, "{s}/{x:0>8}/{s}", .{ work_root, BASE_ID, name }) catch continue;
            os.unlinkPath(path);
        }
    }

    fn bakeBase(self: *Supervisor) !void {
        var cbuf: [os.SUN_PATH_MAX + 32]u8 = undefined;
        var dbuf: [os.SUN_PATH_MAX + 32]u8 = undefined;
        const p = try @import("vm.zig").socketPaths(self.cfg.socket_dir, "base", &cbuf, &dbuf);

        log.info("baking warm-fork base (id={x:0>8})", .{BASE_ID});
        // Start the base from a CLEAN dir. A stale base.snap / conf / kernels
        // symlink / log left by a prior run (or a run with a mismatched nether
        // binary) can otherwise yield a base whose forks misbehave (e.g. hang on
        // shell exec while the data plane still serves). spawnCold recreates the
        // conf + kernels symlink; the base then writes a fresh base.snap.
        cleanBaseDir(self.cfg.work_root);
        const pid = try self.real.spawnCold(BASE_ID, p.control, p.data);
        errdefer os.killPid(pid, os.SIGTERM);

        // Drive the base to a serving state (starts the guest server via SRV).
        try boot.bringUp(p.control, p.data, false, self.cfg.guest_service_prestarted, self.cfg.boot_budget_ms, nowMs);

        // Snapshot the running server + data plane, then shut the base down. The
        // snapshot blocks until the file is on disk, so a successful reply means
        // forks can restore from it. nether jails the snapshot path to the VM's
        // cwd, so pass a bare filename; the real fork source is <base_cwd>/base.snap.
        var client = control_client.Client.connect(p.control) catch return error.BaseSnapshotFailed;
        defer client.close();
        _ = client.handshake(.{ .hang_ms = 2000 }) catch {};
        const ok = client.snapshot("base.snap", .{ .hang_ms = 30000 }) catch return error.BaseSnapshotFailed;
        if (!ok) return error.BaseSnapshotFailed;
        client.shutdown(.{ .hang_ms = 3000 });
        _ = os.waitpidNoHang(pid); // best-effort reap; the base exits on shutdown

        // Point forks at the jailed snapshot's absolute path (config base_snap was
        // only the enable toggle). Both cfg copies drive fork-vs-cold decisions.
        const abs = std.fmt.bufPrint(&self.base_snap_buf, "{s}/{x:0>8}/base.snap", .{ self.cfg.work_root, BASE_ID }) catch return error.PathTooLong;
        self.cfg.base_snap = abs;
        self.pool.cfg.base_snap = abs;
        log.info("warm-fork base ready ({s})", .{abs});
    }

    /// Run the gate: bind the north control socket and serve connections. Blocks.
    pub fn run(self: *Supervisor) !void {
        installSignals();

        // Warm-fork mode: bake the base before accepting so the first ensure can
        // already fork. If the bake fails, fall back to cold-boot (clear the base
        // in both config copies so ensure hands out restore_from="").
        if (self.cfg.base_snap.len > 0) {
            self.bakeBase() catch |e| {
                log.err("base bake failed ({s}); falling back to cold-boot", .{@errorName(e)});
                self.cfg.base_snap = "";
                self.pool.cfg.base_snap = "";
            };
        }

        self.listen_fd = try os.listenUnix(self.cfg.control_socket);
        log.info("north control socket listening at {s}", .{self.cfg.control_socket});

        // Housekeeping thread: reap + idle-reclaim + waiter-deadline sweep.
        if (std.Thread.spawn(.{}, housekeep, .{self})) |t| t.detach() else |e| {
            log.warn("housekeeping thread not started: {s}", .{@errorName(e)});
        }
        // Optional observability surface (/status + /metrics).
        self.startStatus();

        // One thread per north connection so a slow cold boot on one tenant never
        // blocks ensures on another (the pool dedupes same-tenant boots).
        while (true) {
            const conn = os.acceptConn(self.listen_fd) catch continue;
            if (std.Thread.spawn(.{}, connThread, .{ self, conn })) |t| {
                t.detach();
            } else |e| {
                log.err("conn thread spawn failed: {s}; closing", .{@errorName(e)});
                os.closeFd(conn);
            }
        }
    }

    /// Per-connection worker: serve the connection to EOF, then close it.
    fn connThread(self: *Supervisor, conn: std.posix.fd_t) void {
        self.serveConn(conn);
        os.closeFd(conn);
    }

    /// Periodic pool maintenance: reap dead children (crash-eviction), idle-
    /// reclaim ready VMs, and deadline-sweep booting waiters. Also the shutdown
    /// watcher: on SIGTERM/SIGINT it drains every VM's bill and exits. Deadline
    /// answers are dropped here (waiters handle their own deadline inline in
    /// waitForOwner); the VM is kept warm regardless.
    fn housekeep(self: *Supervisor) void {
        var answers: [pool_mod.MAX_WAITERS]pool_mod.Answer = undefined;
        while (true) {
            sleepMs(HOUSEKEEP_MS);
            if (g_shutdown.load(.acquire)) {
                self.teardownAll();
                log.info("shutdown: signaled all VMs; exiting", .{});
                std.c.exit(0);
            }
            self.lock.lock();
            self.reapDead(&answers);
            _ = self.pool.tick(nowMs(), &answers);
            self.lock.unlock();
        }
    }

    /// Reap dead child processes (WNOHANG). A VM that dies while still mapped is
    /// an unexpected crash: evict its tenant so the next ensure re-boots. A VM we
    /// killed intentionally (idle-reclaim / onFailed) is already inactive - we
    /// just clear the zombie. MUST be called under self.lock.
    fn reapDead(self: *Supervisor, answers: []pool_mod.Answer) void {
        while (true) {
            const w = os.reapAnyNoHang();
            if (!w.reaped) break;
            for (&self.vms) |*v| {
                if (v.pid == w.pid and v.pid != 0) {
                    if (v.active) {
                        log.warn("vm={x} exited unexpectedly (code={d}); evicting", .{ v.vm_id, w.exit_code });
                        _ = self.pool.onExited(v.vm_id, answers);
                    }
                    v.* = .{}; // tracking slot free; pid reaped
                    break;
                }
            }
        }
    }

    /// SIGTERM every owned VM so nether drains its final-usage bill on the way
    /// out. Best-effort graceful teardown; takes the lock itself.
    fn teardownAll(self: *Supervisor) void {
        self.lock.lock();
        defer self.lock.unlock();
        var n: u32 = 0;
        for (&self.vms) |*v| {
            if (v.active) {
                os.killPid(v.pid, os.SIGTERM);
                n += 1;
            }
        }
        if (n > 0) log.info("teardown: SIGTERM sent to {d} VM(s)", .{n});
    }

    /// Install SIGTERM/SIGINT handlers that flip the shutdown flag the
    /// housekeeping thread watches. SIGPIPE is ignored so a swerver connection
    /// closing mid-write never kills the supervisor.
    fn installSignals() void {
        const sa = std.posix.Sigaction{
            .handler = .{ .handler = handleShutdownSignal },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.TERM, &sa, null);
        std.posix.sigaction(std.posix.SIG.INT, &sa, null);
        const ign = std.posix.Sigaction{
            .handler = .{ .handler = std.posix.SIG.IGN },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.PIPE, &ign, null);
    }
};

fn sleepMs(ms: u64) void {
    var req = std.posix.timespec{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * std.time.ns_per_ms) };
    _ = std.c.nanosleep(&req, null);
}
