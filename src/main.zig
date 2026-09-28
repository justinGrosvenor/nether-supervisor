//! nether-supervisor: a tenant VM pool for Nether.
//!
//! North side: a Unix control socket swerver's `wasm_control_socket` dials;
//! answers `ensure <tenant>` with the tenant's warm VM `data_socket` path.
//! South side: owns a pool of real `nether` processes (spawn/fork, drive,
//! reclaim). Loads configuration and starts the supervisor's control listener,
//! per-connection workers, housekeeping, and optional status endpoints.

const std = @import("std");
const config = @import("config.zig");
const os = @import("os.zig");
const log = @import("log.zig");
const Supervisor = @import("supervisor.zig").Supervisor;

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

    log.info("config loaded: control_socket={s} socket_dir={s} nether_bin={s} kernels={s} max_vms={d} ram_mb={d} base_snap={s}", .{
        cfg.control_socket,
        cfg.socket_dir,
        cfg.nether_bin,
        cfg.kernels_dir,
        cfg.max_vms,
        cfg.ram_mb,
        if (cfg.base_snap.len == 0) "(cold-boot)" else cfg.base_snap,
    });

    // Ensure the socket + work directories exist before binding/spawning.
    os.mkdirPath(cfg.socket_dir);
    os.mkdirPath(cfg.work_root);

    // Run the supervisor (binds the north control socket, serves ensure).
    var sup = Supervisor.init(cfg);
    sup.wire();
    try sup.run();
}
