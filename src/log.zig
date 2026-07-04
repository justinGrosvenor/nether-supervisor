//! Thin structured-logging helper. Prefixes lines with a level tag and the
//! component. Writes to stderr, line-buffered per call. No dependencies.

const std = @import("std");

// NOTE: single-writer for now (Phase 0 is single-threaded). When the reactor +
// bring-up threads land (Phase 3), wrap emit() in a mutex so interleaved log
// lines from worker threads stay whole.
fn emit(comptime level: []const u8, comptime fmt: []const u8, args: anytype) void {
    var buf: [2048]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "[nsup] " ++ level ++ " " ++ fmt ++ "\n", args) catch {
        // Message too long for the stack buffer: emit a truncation marker
        // rather than dropping it silently.
        std.debug.print("[nsup] " ++ level ++ " <log line too long>\n", .{});
        return;
    };
    std.debug.print("{s}", .{line});
}

pub fn info(comptime fmt: []const u8, args: anytype) void {
    emit("INFO", fmt, args);
}

pub fn warn(comptime fmt: []const u8, args: anytype) void {
    emit("WARN", fmt, args);
}

pub fn err(comptime fmt: []const u8, args: anytype) void {
    emit("ERR ", fmt, args);
}
