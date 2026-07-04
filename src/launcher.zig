//! The VmLauncher seam: how the pool starts and stops a VM's underlying
//! process. The pool is launcher-agnostic so its state machine can be unit
//! tested against a MockLauncher (no HVF), while production uses a RealLauncher
//! that fork/execs the codesigned `nether` in a per-VM cwd. Real and fake differ
//! ONLY here.
//!
//! Lifecycle: the pool calls `spawn` on a cold-start MISS; the launcher's
//! bring-up (a thread in production; the test itself in unit tests) later feeds
//! the pool `onReady`/`onFailed`. `kill` is best-effort reclaim/teardown.

const std = @import("std");

pub const LaunchSpec = struct {
    /// Stable id the pool assigns; echoed back on ready/failed/exited events.
    vm_id: u32,
    control_socket: []const u8,
    data_socket: []const u8,
    /// Snapshot base to fork from; empty => cold-boot.
    restore_from: []const u8 = "",
    app_port: u16,
    cpus: u16,
    ram_mb: u32,
    idle_timeout_s: u32,
};

pub const LaunchError = error{ SpawnFailed, PoolFull };

/// A thin vtable so the pool holds one `Launcher` regardless of backend.
pub const Launcher = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        spawn: *const fn (ctx: *anyopaque, spec: LaunchSpec) LaunchError!void,
        kill: *const fn (ctx: *anyopaque, vm_id: u32) void,
    };

    pub fn spawn(self: Launcher, spec: LaunchSpec) LaunchError!void {
        return self.vtable.spawn(self.ctx, spec);
    }
    pub fn kill(self: Launcher, vm_id: u32) void {
        self.vtable.kill(self.ctx, vm_id);
    }
};

/// A no-I/O launcher for unit tests: records the last spawn/kill so a test can
/// assert dedupe (one spawn per tenant) and reclaim (kill on evict), then drives
/// readiness by calling the pool's onReady/onFailed directly.
pub const MockLauncher = struct {
    spawns: u32 = 0,
    kills: u32 = 0,
    last_spawned_id: u32 = 0,
    last_killed_id: u32 = 0,
    /// When set, the next spawn fails (to test the launch-error path).
    fail_next_spawn: bool = false,

    pub fn launcher(self: *MockLauncher) Launcher {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable = Launcher.VTable{ .spawn = spawnImpl, .kill = killImpl };

    fn spawnImpl(ctx: *anyopaque, spec: LaunchSpec) LaunchError!void {
        const self: *MockLauncher = @ptrCast(@alignCast(ctx));
        if (self.fail_next_spawn) {
            self.fail_next_spawn = false;
            return error.SpawnFailed;
        }
        self.spawns += 1;
        self.last_spawned_id = spec.vm_id;
    }

    fn killImpl(ctx: *anyopaque, vm_id: u32) void {
        const self: *MockLauncher = @ptrCast(@alignCast(ctx));
        self.kills += 1;
        self.last_killed_id = vm_id;
    }
};

// ── Tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

test "MockLauncher records spawn/kill and honors fail_next_spawn" {
    var mock = MockLauncher{};
    const l = mock.launcher();
    try l.spawn(.{ .vm_id = 7, .control_socket = "/c", .data_socket = "/d", .app_port = 8080, .cpus = 1, .ram_mb = 256, .idle_timeout_s = 90 });
    try testing.expectEqual(@as(u32, 1), mock.spawns);
    try testing.expectEqual(@as(u32, 7), mock.last_spawned_id);

    mock.fail_next_spawn = true;
    try testing.expectError(error.SpawnFailed, l.spawn(.{ .vm_id = 8, .control_socket = "/c", .data_socket = "/d", .app_port = 8080, .cpus = 1, .ram_mb = 256, .idle_timeout_s = 90 }));
    try testing.expectEqual(@as(u32, 1), mock.spawns); // not incremented on failure

    l.kill(7);
    try testing.expectEqual(@as(u32, 1), mock.kills);
    try testing.expectEqual(@as(u32, 7), mock.last_killed_id);
}
