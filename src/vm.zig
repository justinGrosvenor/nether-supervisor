//! One microVM instance: generate its `nether.conf`, launch it in its own cwd,
//! drive it to readiness, and reclaim it. nether reads config + `kernels/` from
//! its process cwd and takes no CLI args, so each VM gets a private working
//! directory. This module currently lands the pure conf-generation + the VM
//! spec; launch/readiness/shutdown build on top (Phase V/3).

const std = @import("std");
const config = @import("config.zig");

/// The per-VM parameters the supervisor allocates before boot.
pub const Spec = struct {
    /// Short id used in socket names + cwd (keep it short for sun_path).
    id: []const u8,
    control_socket: []const u8,
    data_socket: []const u8,
    /// Snapshot base to fork from; empty => cold-boot.
    restore_from: []const u8 = "",
    app_port: u16,
    cpus: u16,
    ram_mb: u32,
    idle_timeout_s: u32,
    idle_timeout_ms: ?u64 = null,
};

/// Nether observes the connections. Enforce the smaller enabled idle limit
/// there; the supervisor must not infer idleness from ensure timestamps.
pub fn effectiveIdleMs(ttl_ms: u64, timeout_s: u32) u64 {
    const timeout_ms = @as(u64, timeout_s) * 1000;
    return if (ttl_ms == 0) timeout_ms else if (timeout_ms == 0) ttl_ms else @min(ttl_ms, timeout_ms);
}

/// Write the VM's `nether.conf` body into `out`. Cold-boot and fork differ only
/// by the `restore=1` + `restore_from=<base>` lines. Returns the written slice.
/// Pure + deterministic so it is unit-tested byte-for-byte.
pub fn bootConfText(out: []u8, spec: Spec) error{NoSpace}![]u8 {
    var n: usize = 0;
    n += (std.fmt.bufPrint(out[n..], "control_socket = {s}\n", .{spec.control_socket}) catch return error.NoSpace).len;
    n += (std.fmt.bufPrint(out[n..], "data_socket = {s}\n", .{spec.data_socket}) catch return error.NoSpace).len;
    n += (std.fmt.bufPrint(out[n..], "app_port = {d}\n", .{spec.app_port}) catch return error.NoSpace).len;
    n += (std.fmt.bufPrint(out[n..], "cpus = {d}\n", .{spec.cpus}) catch return error.NoSpace).len;
    n += (std.fmt.bufPrint(out[n..], "ram_mb = {d}\n", .{spec.ram_mb}) catch return error.NoSpace).len;
    // Keep seconds for compatibility; updated Nether uses the millisecond override.
    n += (std.fmt.bufPrint(out[n..], "idle_timeout_s = {d}\n", .{spec.idle_timeout_s}) catch return error.NoSpace).len;
    if (spec.idle_timeout_ms) |ms| {
        n += (std.fmt.bufPrint(out[n..], "idle_timeout_ms = {d}\n", .{ms}) catch return error.NoSpace).len;
    }
    if (spec.restore_from.len > 0) {
        n += (std.fmt.bufPrint(out[n..], "restore = 1\n", .{}) catch return error.NoSpace).len;
        n += (std.fmt.bufPrint(out[n..], "restore_from = {s}\n", .{spec.restore_from}) catch return error.NoSpace).len;
    }
    return out[0..n];
}

/// Derive a VM's socket paths under a directory, guarding sun_path length.
/// `<dir>/<id>.control.sock` and `<dir>/<id>.data.sock`.
pub fn socketPaths(
    dir: []const u8,
    id: []const u8,
    control_out: []u8,
    data_out: []u8,
) error{PathTooLong}!struct { control: []const u8, data: []const u8 } {
    const control = std.fmt.bufPrint(control_out, "{s}/{s}.control.sock", .{ dir, id }) catch return error.PathTooLong;
    if (control.len + 1 > config.SUN_PATH_MAX) return error.PathTooLong;
    const data = std.fmt.bufPrint(data_out, "{s}/{s}.data.sock", .{ dir, id }) catch return error.PathTooLong;
    if (data.len + 1 > config.SUN_PATH_MAX) return error.PathTooLong;
    return .{ .control = control, .data = data };
}

// ── Tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

test "idle policy uses the smaller enabled limit without rounding" {
    try testing.expectEqual(@as(u64, 1501), effectiveIdleMs(1501, 90));
    try testing.expectEqual(@as(u64, 1000), effectiveIdleMs(60_000, 1));
    try testing.expectEqual(@as(u64, 90_000), effectiveIdleMs(0, 90));
    try testing.expectEqual(@as(u64, 1501), effectiveIdleMs(1501, 0));
    try testing.expectEqual(@as(u64, 0), effectiveIdleMs(0, 0));
}

test "bootConfText: cold-boot omits restore lines" {
    var buf: [512]u8 = undefined;
    const text = try bootConfText(&buf, .{
        .id = "ab12cd34",
        .control_socket = "/tmp/nsup/ab12cd34.control.sock",
        .data_socket = "/tmp/nsup/ab12cd34.data.sock",
        .app_port = 8080,
        .cpus = 1,
        .ram_mb = 256,
        .idle_timeout_s = 90,
    });
    try testing.expectEqualStrings(
        \\control_socket = /tmp/nsup/ab12cd34.control.sock
        \\data_socket = /tmp/nsup/ab12cd34.data.sock
        \\app_port = 8080
        \\cpus = 1
        \\ram_mb = 256
        \\idle_timeout_s = 90
        \\
    , text);
}

test "bootConfText: fork adds restore lines" {
    var buf: [512]u8 = undefined;
    const text = try bootConfText(&buf, .{
        .id = "ff00ff00",
        .control_socket = "/tmp/nsup/ff00ff00.control.sock",
        .data_socket = "/tmp/nsup/ff00ff00.data.sock",
        .restore_from = "/tmp/nsup/base.snap",
        .app_port = 8080,
        .cpus = 2,
        .ram_mb = 512,
        .idle_timeout_s = 120,
    });
    try testing.expect(std.mem.indexOf(u8, text, "restore = 1\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "restore_from = /tmp/nsup/base.snap\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "cpus = 2\n") != null);
}

test "socketPaths builds names and rejects an over-long dir" {
    var c: [config.SUN_PATH_MAX + 64]u8 = undefined;
    var d: [config.SUN_PATH_MAX + 64]u8 = undefined;
    const p = try socketPaths("/tmp/nsup", "abcd1234", &c, &d);
    try testing.expectEqualStrings("/tmp/nsup/abcd1234.control.sock", p.control);
    try testing.expectEqualStrings("/tmp/nsup/abcd1234.data.sock", p.data);

    const long_dir = "/" ++ ("x" ** 100);
    try testing.expectError(error.PathTooLong, socketPaths(long_dir, "abcd1234", &c, &d));
}
