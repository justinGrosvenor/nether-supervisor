//! nether-supervisor: the 1c VM supervisor for the two-tier microVM platform.
//!
//! North side: a Unix control socket swerver's `wasm_control_socket` dials;
//! answers `ensure <tenant>` with the tenant's warm VM `data_socket` path.
//! South side: owns a pool of real `nether` processes (spawn/fork, drive,
//! reclaim). See docs/ and the plan. Phase 0 is the scaffold: load config,
//! validate, and report; the reactor lands in later phases.

const std = @import("std");
const config = @import("config.zig");
const os = @import("os.zig");
const log = @import("log.zig");

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    // Config is read from `nether-supervisor.conf` in the process cwd, mirroring
    // nether's own file-in-cwd convention. Absent is fine: all keys have
    // defaults. (argv + NSUP_* env overrides are a tracked follow-up, pending
    // the 0.16 std.Io env/args API.)
    var cfg = config.init(gpa);
    defer cfg.deinit();

    if (os.readFileCwdAlloc(gpa, config.DEFAULT_PATH, 1 << 20)) |text| {
        defer gpa.free(text);
        const unknown = try cfg.parseText(text);
        if (unknown > 0) log.warn("config '{s}': {d} unknown key(s) ignored", .{ config.DEFAULT_PATH, unknown });
        log.info("config loaded from {s}", .{config.DEFAULT_PATH});
    } else |e| switch (e) {
        error.FileNotFound => log.info("no {s} in cwd; using defaults", .{config.DEFAULT_PATH}),
        else => return e,
    }

    cfg.validateSunPath() catch |e| {
        log.err("config socket paths do not fit sun_path ({d}): {s}", .{ config.SUN_PATH_MAX, @errorName(e) });
        return e;
    };

    log.info("config loaded: control_socket={s} socket_dir={s} launcher={s} max_vms={d} base_snap={s}", .{
        cfg.control_socket,
        cfg.socket_dir,
        cfg.launcher_mode,
        cfg.max_vms,
        if (cfg.base_snap.len == 0) "(cold-boot)" else cfg.base_snap,
    });

    // Phase 0 stops here: the reactor + pool land in later phases. Exit clean so
    // the scaffold is runnable (`zig build run -- nether-supervisor.conf`).
    log.info("scaffold ready (reactor not yet wired; see the plan build order)", .{});
}
