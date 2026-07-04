//! Reads one control-protocol reply off a fd, handling the framed-vs-bare
//! disambiguation. Ported from nether `tools/nether-ctl.c read_reply`: a framed
//! reply normally blocks up to `hang_ms` for its `0x1e<exit>\n`; but once the
//! buffer looks like a bare `ERR`/`OK` line (no 0x1e), settle quickly so a stray
//! unframed reply fails fast instead of hanging. Timeouts are parameters so
//! tests run fast.

const std = @import("std");
const posix = std.posix;
const proto = @import("proto.zig");

pub const DEFAULT_HANG_MS: i32 = 60_000;
pub const DEFAULT_IDLE_MS: i32 = 2_000;
pub const DEFAULT_SETTLE_MS: i32 = 500;

pub const Timeouts = struct {
    hang_ms: i32 = DEFAULT_HANG_MS,
    idle_ms: i32 = DEFAULT_IDLE_MS,
    settle_ms: i32 = DEFAULT_SETTLE_MS,
};

pub const Reply = struct {
    /// Bytes read into the caller's buffer (the whole reply, framed body without
    /// its trailer when framed, or the bare line when not).
    len: usize,
    /// Exit code from a framed trailer; -1 when no frame arrived. A bare `ERR `
    /// line yields exit 1 so a caller expecting a frame does not read it as ok.
    exit: i32,
    /// True when a real `0x1e<exit>\n` frame was parsed.
    framed: bool,
};

/// Read a reply into `buf`. `expect_framed` selects the framed timeout policy
/// (true for reports/commands; false for a fire-and-forget where a bare OK is
/// the norm). Returns the reply, or error on a poll/read failure.
pub fn readReply(fd: posix.fd_t, buf: []u8, expect_framed: bool, t: Timeouts) error{ReadFailed}!Reply {
    var len: usize = 0;
    while (true) {
        const timeout: i32 = if (!expect_framed)
            t.idle_ms
        else if (proto.bareStatusLine(buf[0..len]))
            t.settle_ms
        else
            t.hang_ms;

        var pfd = [1]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
        const pr = posix.system.poll(&pfd, 1, timeout);
        if (pr <= 0) break; // timeout: dead guest (framed) / idle done / ERR settled

        const rc = posix.system.read(fd, buf[len..].ptr, buf.len - len);
        if (rc < 0) {
            if (posix.errno(rc) == .INTR) continue;
            return error.ReadFailed;
        }
        if (rc == 0) break; // EOF
        len += @intCast(rc);

        if (expect_framed) {
            if (proto.parseFrame(buf[0..len])) |f| {
                return .{ .len = f.body.len, .exit = f.exit, .framed = true };
            }
        }
        if (len == buf.len) break; // full: stop (truncated but safe)
    }
    // No frame. A bare `ERR ...` is a failure -> exit 1.
    const exit: i32 = if (proto.bareStatusLine(buf[0..len]) and std.mem.startsWith(u8, buf[0..len], "ERR ")) 1 else -1;
    return .{ .len = len, .exit = exit, .framed = false };
}

// ── Tests ───────────────────────────────────────────────────────────────

const testing = std.testing;
const os = @import("os.zig");

// A socketpair: write canned server bytes into one end, read via readReply on
// the other. libc is linked (see build.zig) so system.socketpair is available.
fn pair() ![2]posix.fd_t {
    var fds: [2]posix.fd_t = undefined;
    const rc = posix.system.socketpair(@intCast(posix.AF.UNIX), posix.SOCK.STREAM, 0, &fds);
    if (rc != 0) return error.SocketpairFailed;
    return fds;
}

test "readReply parses a framed command reply" {
    const fds = try pair();
    defer os.closeFd(fds[0]);
    defer os.closeFd(fds[1]);
    try os.writeAll(fds[1], "lookup ok\x1e0\n");
    var buf: [256]u8 = undefined;
    const r = try readReply(fds[0], &buf, true, .{});
    try testing.expect(r.framed);
    try testing.expectEqual(@as(i32, 0), r.exit);
    try testing.expectEqualStrings("lookup ok", buf[0..r.len]);
}

test "readReply settles fast on a bare ERR (no 30s hang)" {
    const fds = try pair();
    defer os.closeFd(fds[0]);
    defer os.closeFd(fds[1]);
    try os.writeAll(fds[1], "ERR agent not connected\n");
    var buf: [256]u8 = undefined;
    // A tiny settle so the test is fast; a real frame never arrives -> exit 1.
    const r = try readReply(fds[0], &buf, true, .{ .settle_ms = 20, .hang_ms = 20 });
    try testing.expect(!r.framed);
    try testing.expectEqual(@as(i32, 1), r.exit);
    try testing.expectEqualStrings("ERR agent not connected\n", buf[0..r.len]);
}

test "readReply waits for the trailer newline before returning a frame" {
    const fds = try pair();
    defer os.closeFd(fds[0]);
    defer os.closeFd(fds[1]);
    // Send the frame in two writes: body+0x1e+digit, then the newline.
    try os.writeAll(fds[1], "data\x1e7");
    try os.writeAll(fds[1], "\n");
    var buf: [256]u8 = undefined;
    const r = try readReply(fds[0], &buf, true, .{ .hang_ms = 200 });
    try testing.expect(r.framed);
    try testing.expectEqual(@as(i32, 7), r.exit);
    try testing.expectEqualStrings("data", buf[0..r.len]);
}
