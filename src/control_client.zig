//! South-side driver for ONE VM's control socket. The supervisor holds the
//! primary control slot on each VM: it connects first, handshakes (__info__ +
//! proto_version check), then drives commands (a shell line to bring the tenant
//! server up, __snapshot__ to bake a base, __shutdown__ to reclaim). One command
//! at a time; each reply is read to completion before the next (the protocol is
//! serial). Blocking with poll timeouts (the reader owns the SETTLE_MS grace).

const std = @import("std");
const posix = std.posix;
const os = @import("os.zig");
const proto = @import("proto.zig");
const reader = @import("control_reader.zig");

pub const Client = struct {
    fd: posix.fd_t,
    reply_buf: [64 * 1024]u8 = undefined,

    pub const Error = error{
        Connect,
        Write,
        Read,
        ProtoMismatch,
        NoReply,
    };

    /// Connect to a VM's control socket. The socket accepts before the guest
    /// boots (nether host-intercepts reports), so this succeeds early.
    pub fn connect(path: []const u8) Error!Client {
        const fd = os.connectUnix(path) catch return error.Connect;
        return .{ .fd = fd };
    }

    pub fn close(self: *Client) void {
        os.closeFd(self.fd);
    }

    /// Send `__info__` and verify `proto_version=1`. Returns the raw report
    /// (into an internal buffer) on success. Fast: the report is host-intercepted
    /// and answers immediately even before the guest agent is up.
    pub fn handshake(self: *Client, t: reader.Timeouts) Error![]const u8 {
        os.writeAll(self.fd, "__info__\n") catch return error.Write;
        const r = reader.readReply(self.fd, &self.reply_buf, true, t) catch return error.Read;
        if (r.len == 0) return error.NoReply;
        const report = self.reply_buf[0..r.len];
        if (!proto.verifyProtoVersion(report)) return error.ProtoMismatch;
        return report;
    }

    pub const DriveResult = struct { exit: i32, body: []const u8, framed: bool };

    /// Drive one control command (a shell line, or a `__verb__`). Appends the
    /// required trailing newline. Returns the framed body + exit, or a bare
    /// line's text with exit -1 (framed=false). The caller decides success.
    pub fn drive(self: *Client, cmd: []const u8, t: reader.Timeouts) Error!DriveResult {
        os.writeAll(self.fd, cmd) catch return error.Write;
        os.writeAll(self.fd, "\n") catch return error.Write;
        const r = reader.readReply(self.fd, &self.reply_buf, true, t) catch return error.Read;
        return .{ .exit = r.exit, .body = self.reply_buf[0..r.len], .framed = r.framed };
    }

    /// Bake a snapshot base at `path` (primary-only; HVF). nether blocks the
    /// reply until the file is on disk, so a framed exit 0 means "ready to fork".
    pub fn snapshot(self: *Client, path: []const u8, t: reader.Timeouts) Error!bool {
        var cmd_buf: [os.SUN_PATH_MAX + 32]u8 = undefined;
        const cmd = std.fmt.bufPrint(&cmd_buf, "__snapshot__ {s}", .{path}) catch return error.Write;
        const r = try self.drive(cmd, t);
        // nether replies `OK snapshot written` (bare) or a framed exit 0.
        return (r.framed and r.exit == 0) or std.mem.startsWith(u8, r.body, "OK ");
    }

    /// Ask the VM to shut down cleanly (primary-only). nether replies a bare
    /// `OK shutting down` then exits with its final-usage bill. Best-effort.
    pub fn shutdown(self: *Client, t: reader.Timeouts) void {
        os.writeAll(self.fd, "__shutdown__\n") catch return;
        var junk: [256]u8 = undefined;
        _ = reader.readReply(self.fd, &junk, true, t) catch {};
    }
};

// ── Tests (drive against a scripted in-process server over a socketpair) ──

const testing = std.testing;

fn pair() ![2]posix.fd_t {
    var fds: [2]posix.fd_t = undefined;
    const rc = posix.system.socketpair(@intCast(posix.AF.UNIX), posix.SOCK.STREAM, 0, &fds);
    if (rc != 0) return error.SocketpairFailed;
    return fds;
}

test "handshake verifies proto_version=1" {
    const fds = try pair();
    defer os.closeFd(fds[1]);
    var client = Client{ .fd = fds[0] };
    defer client.close();
    // Server side: answer __info__ with a proto_version=1 framed report.
    try os.writeAll(fds[1], "nether sandbox info\nproto_version=1\nbackend=fake\n\x1e0\n");
    const report = try client.handshake(.{ .hang_ms = 200 });
    try testing.expect(proto.verifyProtoVersion(report));
}

test "handshake accepts proto_version 2 (framed acks; drive is v2-tolerant)" {
    const fds = try pair();
    defer os.closeFd(fds[1]);
    var client = Client{ .fd = fds[0] };
    defer client.close();
    try os.writeAll(fds[1], "nether sandbox info\nproto_version=2\nbackend=fake\n\x1e0\n");
    const report = try client.handshake(.{ .hang_ms = 200 });
    try testing.expect(proto.verifyProtoVersion(report));
}

test "handshake rejects an unsupported proto_version" {
    const fds = try pair();
    defer os.closeFd(fds[1]);
    var client = Client{ .fd = fds[0] };
    defer client.close();
    try os.writeAll(fds[1], "info\nproto_version=9\n\x1e0\n");
    try testing.expectError(error.ProtoMismatch, client.handshake(.{ .hang_ms = 200 }));
}

test "drive returns a framed exit + body" {
    const fds = try pair();
    defer os.closeFd(fds[1]);
    var client = Client{ .fd = fds[0] };
    defer client.close();
    // Server answers the drive command with a framed exit 0.
    try os.writeAll(fds[1], "r\x1e0\n");
    const res = try client.drive("echo r", .{ .hang_ms = 200 });
    try testing.expect(res.framed);
    try testing.expectEqual(@as(i32, 0), res.exit);
    try testing.expectEqualStrings("r", res.body);
    // Verify the client actually wrote "echo r\n".
    var got: [16]u8 = undefined;
    const n = posix.system.read(fds[1], &got, got.len);
    try testing.expect(n > 0);
    try testing.expectEqualStrings("echo r\n", got[0..@intCast(n)]);
}

test "drive surfaces a bare ERR (guest not ready) without hanging" {
    const fds = try pair();
    defer os.closeFd(fds[1]);
    var client = Client{ .fd = fds[0] };
    defer client.close();
    try os.writeAll(fds[1], "ERR agent not connected\n");
    const res = try client.drive("echo r", .{ .settle_ms = 20, .hang_ms = 20 });
    try testing.expect(!res.framed);
    try testing.expectEqual(@as(i32, 1), res.exit);
}
