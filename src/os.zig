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

/// Create a directory, ignoring "already exists". `path` must be NUL-terminated.
pub fn mkdirZ(path: [*:0]const u8) void {
    _ = std.c.mkdir(path, 0o755);
}

/// Force-create a symlink (unlink any existing link first). NUL-terminated.
pub fn symlinkForceZ(target: [*:0]const u8, link: [*:0]const u8) void {
    _ = std.c.unlink(link);
    _ = std.c.symlink(target, link);
}

/// Write `data` to `path` (create/truncate). Resolved relative to cwd (or
/// absolute). Uses openat(AT.FDCWD) since std.fs.cwd is gone in 0.16.
pub fn writeFile(path: []const u8, data: []const u8) !void {
    const fd = try posix.openat(posix.AT.FDCWD, path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    defer closeFd(fd);
    var off: usize = 0;
    while (off < data.len) {
        const rc = posix.system.write(fd, data[off..].ptr, data.len - off);
        if (rc < 0) {
            if (posix.errno(rc) == .INTR) continue;
            return error.WriteFailed;
        }
        if (rc == 0) return error.WriteFailed;
        off += @intCast(rc);
    }
}

/// SIGTERM as a c_int (std.posix.SIG.TERM is an enum on macOS in 0.16).
pub const SIGTERM: c_int = @intFromEnum(std.posix.SIG.TERM);

pub const WaitOutcome = struct { reaped: bool, exit_code: u8 };

/// Non-blocking reap. Returns reaped=false if the child is still running.
pub fn waitpidNoHang(pid: std.c.pid_t) WaitOutcome {
    var status: c_int = 0;
    const WNOHANG = 1;
    const rc = std.c.waitpid(pid, &status, WNOHANG);
    if (rc == 0) return .{ .reaped = false, .exit_code = 0 }; // still running
    if (rc < 0) return .{ .reaped = true, .exit_code = 255 }; // no such child
    // WIFEXITED / WEXITSTATUS (low byte layout is portable enough here).
    const exited = (status & 0x7f) == 0;
    const code: u8 = if (exited) @intCast((status >> 8) & 0xff) else 255;
    return .{ .reaped = true, .exit_code = code };
}

pub fn killPid(pid: std.c.pid_t, sig: c_int) void {
    _ = std.c.kill(pid, @enumFromInt(sig));
}

pub const ReapResult = struct { reaped: bool, pid: std.c.pid_t, exit_code: u8 };

/// Reap ANY one dead child without blocking (waitpid(-1, WNOHANG)). Returns
/// reaped=false when no child has died (or there are no children). The reaper
/// loops this to drain every zombie each tick; a matched pid drives crash
/// eviction.
pub fn reapAnyNoHang() ReapResult {
    var status: c_int = 0;
    const WNOHANG = 1;
    const rc = std.c.waitpid(-1, &status, WNOHANG);
    if (rc <= 0) return .{ .reaped = false, .pid = 0, .exit_code = 0 };
    const exited = (status & 0x7f) == 0;
    const code: u8 = if (exited) @intCast((status >> 8) & 0xff) else 255;
    return .{ .reaped = true, .pid = rc, .exit_code = code };
}

/// Monotonic milliseconds (std.posix.clock_gettime is gone in 0.16; use the
/// system call directly like swerver's clock.zig).
pub fn monotonicMs() u64 {
    var ts: posix.timespec = undefined;
    if (posix.system.clock_gettime(posix.CLOCK.MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / std.time.ns_per_ms;
}

/// mkdir a path (NUL-terminated from a slice), ignoring "already exists".
pub fn mkdirPath(path: []const u8) void {
    var buf: [512]u8 = undefined;
    if (path.len + 1 > buf.len) return;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    mkdirZ(@ptrCast(&buf));
}

/// open(2) helpers for the post-fork child (NUL-terminated, libc). Return the
/// fd or error.OpenFailed.
pub fn openReadZ(path: [*:0]const u8) error{OpenFailed}!posix.fd_t {
    const rc = std.c.open(path, .{ .ACCMODE = .RDONLY }, @as(c_uint, 0));
    if (rc < 0) return error.OpenFailed;
    return rc;
}
pub fn openWriteZ(path: [*:0]const u8) error{OpenFailed}!posix.fd_t {
    const rc = std.c.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(c_uint, 0o644));
    if (rc < 0) return error.OpenFailed;
    return rc;
}

pub const ListenError = error{ PathTooLong, SocketFailed, BindFailed, ListenFailed };

/// Bind + listen a UNIX-domain stream socket at `path` (unlinking any stale
/// socket first). Returns the listening fd.
pub fn listenUnix(path: []const u8) ListenError!posix.fd_t {
    if (path.len + 1 > SUN_PATH_MAX) return error.PathTooLong;
    var path_z: [SUN_PATH_MAX]u8 = undefined;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;
    _ = std.c.unlink(@ptrCast(&path_z));

    const domain: c_uint = @intCast(posix.AF.UNIX);
    const rc = posix.system.socket(domain, posix.SOCK.STREAM, 0);
    if (rc < 0) return error.SocketFailed;
    const fd: posix.fd_t = @intCast(rc);
    errdefer closeFd(fd);

    var sa: posix.sockaddr.un = .{ .path = undefined };
    @memset(&sa.path, 0);
    @memcpy(sa.path[0..path.len], path);
    if (posix.system.bind(fd, @ptrCast(&sa), @sizeOf(posix.sockaddr.un)) != 0) return error.BindFailed;
    if (posix.system.listen(fd, 16) != 0) return error.ListenFailed;
    return fd;
}

pub const TcpError = error{ BadAddress, SocketFailed, BindFailed, ListenFailed };

/// Parse a dotted-quad IPv4 string into a host-order u32. Returns null on any
/// malformed octet (too many parts, >255, non-digit).
pub fn parseIpv4(ip: []const u8) ?u32 {
    var addr: u32 = 0;
    var parts: usize = 0;
    var it = std.mem.splitScalar(u8, ip, '.');
    while (it.next()) |part| {
        if (parts >= 4 or part.len == 0 or part.len > 3) return null;
        const octet = std.fmt.parseInt(u8, part, 10) catch return null;
        addr = (addr << 8) | octet;
        parts += 1;
    }
    if (parts != 4) return null;
    return addr;
}

/// Bind + listen a TCP socket at `ip:port` (SO_REUSEADDR). Returns the listening
/// fd. Used by the optional status/metrics surface; loopback-only in practice.
pub fn listenTcp(ip: []const u8, port: u16) TcpError!posix.fd_t {
    const host_addr = parseIpv4(ip) orelse return error.BadAddress;
    const domain: c_uint = @intCast(posix.AF.INET);
    const rc = posix.system.socket(domain, posix.SOCK.STREAM, 0);
    if (rc < 0) return error.SocketFailed;
    const fd: posix.fd_t = @intCast(rc);
    errdefer closeFd(fd);

    const one: c_int = 1;
    _ = posix.system.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, @ptrCast(&one), @sizeOf(c_int));

    var sa: posix.sockaddr.in = .{
        .family = @intCast(posix.AF.INET),
        .port = std.mem.nativeToBig(u16, port),
        .addr = std.mem.nativeToBig(u32, host_addr),
        .zero = [_]u8{0} ** 8,
    };
    if (posix.system.bind(fd, @ptrCast(&sa), @sizeOf(posix.sockaddr.in)) != 0) return error.BindFailed;
    if (posix.system.listen(fd, 16) != 0) return error.ListenFailed;
    return fd;
}

/// Accept one connection (blocking). Returns the connected fd.
pub fn acceptConn(listen_fd: posix.fd_t) error{AcceptFailed}!posix.fd_t {
    const rc = posix.system.accept(listen_fd, null, null);
    if (rc < 0) return error.AcceptFailed;
    return @intCast(rc);
}

/// Read some bytes (blocking). Returns 0 on EOF.
pub fn readSome(fd: posix.fd_t, buf: []u8) error{ReadFailed}!usize {
    while (true) {
        const rc = posix.system.read(fd, buf.ptr, buf.len);
        if (rc < 0) {
            if (posix.errno(rc) == .INTR) continue;
            return error.ReadFailed;
        }
        return @intCast(rc);
    }
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
