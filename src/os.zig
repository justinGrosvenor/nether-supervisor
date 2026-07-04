//! Small OS shims for APIs removed in Zig 0.16 stable (std.posix.close,
//! std.fs.cwd file reads) plus a couple of convenience helpers the supervisor
//! reuses. Mirrors the pattern swerver uses in src/runtime/clock.zig.

const std = @import("std");
const posix = std.posix;

/// macOS sockaddr_un.sun_path is 104 bytes including the NUL; Linux is 108.
pub const SUN_PATH_MAX: usize = 104;

/// Close a file descriptor (replacement for the removed std.posix.close).
pub fn closeFd(fd: posix.fd_t) void {
    _ = posix.system.close(fd);
}

pub const UnixError = error{ PathTooLong, SocketFailed, ConnectFailed };

/// Connect to a UNIX-domain stream socket (blocking). Returns the fd. The south
/// side drives short control commands, so a plain blocking connect is fine.
pub fn connectUnix(path: []const u8) UnixError!posix.fd_t {
    if (path.len + 1 > SUN_PATH_MAX) return error.PathTooLong;
    const domain: c_uint = @intCast(posix.AF.UNIX);
    const rc = posix.system.socket(domain, posix.SOCK.STREAM, 0);
    if (rc < 0) return error.SocketFailed;
    const fd: posix.fd_t = @intCast(rc);
    errdefer closeFd(fd);

    var sa: posix.sockaddr.un = .{ .path = undefined };
    @memset(&sa.path, 0);
    @memcpy(sa.path[0..path.len], path);
    if (posix.system.connect(fd, @ptrCast(&sa), @sizeOf(posix.sockaddr.un)) != 0) return error.ConnectFailed;
    return fd;
}

/// Write all of `data` to `fd`, retrying short writes and EINTR.
pub fn writeAll(fd: posix.fd_t, data: []const u8) error{WriteFailed}!void {
    var sent: usize = 0;
    while (sent < data.len) {
        const rc = posix.system.write(fd, data[sent..].ptr, data.len - sent);
        if (rc < 0) {
            if (posix.errno(rc) == .INTR) continue;
            return error.WriteFailed;
        }
        if (rc == 0) return error.WriteFailed;
        sent += @intCast(rc);
    }
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
