//! Small OS shims for APIs removed in Zig 0.16 stable (std.posix.close,
//! std.fs.cwd file reads) plus a couple of convenience helpers the supervisor
//! reuses. Mirrors the pattern swerver uses in src/runtime/clock.zig.

const std = @import("std");
const posix = std.posix;

/// Close a file descriptor (replacement for the removed std.posix.close).
pub fn closeFd(fd: posix.fd_t) void {
    _ = posix.system.close(fd);
}

/// Read an entire file (resolved relative to the process cwd) into a freshly
/// allocated buffer, capped at `max`. Returns error.FileNotFound when absent so
/// callers can fall back to defaults. The caller owns and frees the result.
pub fn readFileCwdAlloc(gpa: std.mem.Allocator, path: []const u8, max: usize) ![]u8 {
    const fd = try posix.openat(posix.AT.FDCWD, path, .{}, 0);
    defer closeFd(fd);

    var buf = try gpa.alloc(u8, max);
    errdefer gpa.free(buf);
    var total: usize = 0;
    while (total < max) {
        const n = try posix.read(fd, buf[total..]);
        if (n == 0) break;
        total += n;
    }
    if (total == max) return error.FileTooLarge;
    return gpa.realloc(buf, total);
}
