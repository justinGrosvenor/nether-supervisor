//! VM readiness probe. A VM is ready only when its data_socket actually SERVES
//! HTTP - not merely when connect() succeeds. nether's host data-bridge listener
//! binds before the guest boots, so a bare connect() is a false positive; the
//! probe forces an HTTP round-trip through the vsock splice to the in-guest
//! server on app_port. This module has the pure request builder + response check
//! (unit-tested) and the live probe (real I/O, exercised against a real/fake VM).

const std = @import("std");
const posix = std.posix;
const os = @import("os.zig");

/// The minimal HTTP/1.1 request the probe sends. `Connection: close` so the
/// server ends the response at EOF and we do not need to parse Content-Length.
pub const PROBE_REQUEST = "GET /_ready HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";

/// Does `response` begin with a complete HTTP status line (`HTTP/1.x NNN ...\r\n`)?
/// Readiness only needs the tenant server to answer with a valid status line;
/// any status proves the in-guest server is listening and the splice works.
pub fn isServing(response: []const u8) bool {
    if (!std.mem.startsWith(u8, response, "HTTP/1.")) return false;
    const eol = std.mem.indexOf(u8, response, "\r\n") orelse return false;
    const line = response[0..eol];
    // "HTTP/1.1 200 ..." - need a space then 3 digits.
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    _ = it.next() orelse return false; // HTTP/1.x
    const code = it.next() orelse return false;
    if (code.len != 3) return false;
    for (code) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

pub const ProbeError = error{ Connect, Write, Read, NotServing };

/// One live probe attempt: connect the data_socket, send PROBE_REQUEST, read a
/// status line. Returns void on a valid status line, else an error. The caller
/// retries with backoff until the boot budget expires.
pub fn probeOnce(data_socket: []const u8) ProbeError!void {
    const fd = os.connectUnix(data_socket) catch return error.Connect;
    defer os.closeFd(fd);
    // Bound the read so a wedged server does not stall the bring-up thread.
    const tv = posix.timeval{ .sec = 2, .usec = 0 };
    _ = posix.system.setsockopt(fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&tv), @sizeOf(posix.timeval));
    _ = posix.system.setsockopt(fd, posix.SOL.SOCKET, posix.SO.SNDTIMEO, std.mem.asBytes(&tv), @sizeOf(posix.timeval));

    os.writeAll(fd, PROBE_REQUEST) catch return error.Write;

    var buf: [256]u8 = undefined;
    var len: usize = 0;
    while (len < buf.len) {
        const rc = posix.system.read(fd, buf[len..].ptr, buf.len - len);
        if (rc < 0) {
            if (posix.errno(rc) == .INTR) continue;
            return error.Read;
        }
        if (rc == 0) break;
        len += @intCast(rc);
        // A CRLF means the status line is complete; no need to read the body.
        if (std.mem.indexOf(u8, buf[0..len], "\r\n") != null) break;
    }
    if (!isServing(buf[0..len])) return error.NotServing;
}

// ── Tests (pure helpers; live probeOnce is exercised against a real/fake VM) ─

const testing = std.testing;

test "isServing accepts a valid status line, rejects junk" {
    try testing.expect(isServing("HTTP/1.1 200 OK\r\nContent-Length: 9\r\n\r\nvm-served"));
    try testing.expect(isServing("HTTP/1.0 404 Not Found\r\n\r\n"));
    try testing.expect(isServing("HTTP/1.1 503 Service Unavailable\r\n"));
    // Not serving:
    try testing.expect(!isServing("")); // empty (connect but no response)
    try testing.expect(!isServing("HTTP/1.1 200 OK")); // no CRLF yet (incomplete)
    try testing.expect(!isServing("garbage\r\n"));
    try testing.expect(!isServing("HTTP/1.1 2 OK\r\n")); // not 3 digits
    try testing.expect(!isServing("HTTP/1.1 abc OK\r\n"));
}

test "PROBE_REQUEST is a well-formed close-delimited GET" {
    try testing.expect(std.mem.startsWith(u8, PROBE_REQUEST, "GET /_ready HTTP/1.1\r\n"));
    try testing.expect(std.mem.endsWith(u8, PROBE_REQUEST, "\r\n\r\n"));
    try testing.expect(std.mem.indexOf(u8, PROBE_REQUEST, "Connection: close") != null);
}
