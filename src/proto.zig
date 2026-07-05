//! The nether control-protocol wire codec, shared by the north side (reply
//! builder) and the south side (frame parser). Ported from swerver's
//! src/wasm/control_client.zig and nether's tools/nether-ctl.c so the framing is
//! bit-identical to what both already speak. Pure functions, no I/O.
//!
//! Wire shapes (control-protocol.md):
//!  - A framed reply: `<body>0x1e<exit-digits>\n`. Report verbs (__info__ etc.)
//!    and shell commands use this.
//!  - A bare status line: `OK <reason>\n` or `ERR <reason>\n` (no 0x1e).
//!  - Body escaping (so a body cannot forge the trailer): a body 0x1e/0x1f byte
//!    is emitted as `0x1f, (byte ^ 0x40)`; the trailer 0x1e is always raw.

const std = @import("std");

/// Record separator: ends a framed reply body; the trailer is `RS <exit> \n`.
pub const RS: u8 = 0x1e;
/// Escape lead byte for a body 0x1e/0x1f (see the module header).
pub const ESC: u8 = 0x1f;
const ESC_XOR: u8 = 0x40;

/// A complete framed reply parsed out of a receive buffer.
pub const Frame = struct {
    /// The body bytes as they appeared on the wire (still escaped). Call
    /// `unescapeBody` on a mutable copy to recover literal bytes.
    body: []const u8,
    /// Exit code from the trailer.
    exit: u8,
    /// Total bytes this frame occupies from the front of the buffer (body +
    /// trailer, up to and including the newline). The caller consumes these.
    consumed: usize,
};

/// If `buf` holds a complete framed reply (`<body>0x1e<digits>\n`), return it;
/// else null (need more bytes). A leading 0x1e means an empty body. Does NOT
/// interpret a bare `OK`/`ERR` line - use `bareStatusLine` + `completeLine`.
pub fn parseFrame(buf: []const u8) ?Frame {
    const sep = std.mem.indexOfScalar(u8, buf, RS) orelse return null;
    // Trailer is 0x1e<digits>\n; wait for the newline.
    const nl_rel = std.mem.indexOfScalar(u8, buf[sep + 1 ..], '\n') orelse return null;
    const nl = sep + 1 + nl_rel;
    const digits = buf[sep + 1 .. nl];
    var code: u32 = 0;
    var saw_digit = false;
    for (digits) |d| {
        if (d < '0' or d > '9') break;
        code = code * 10 + (d - '0');
        saw_digit = true;
    }
    return .{
        .body = buf[0..sep],
        .exit = if (saw_digit and code <= 255) @intCast(code) else 255,
        .consumed = nl + 1,
    };
}

/// A complete newline-terminated line at the front of `buf`, or null. Used by
/// the reader to detect a bare `OK`/`ERR` status line (which carries no 0x1e).
pub fn completeLine(buf: []const u8) ?[]const u8 {
    const nl = std.mem.indexOfScalar(u8, buf, '\n') orelse return null;
    return buf[0 .. nl + 1];
}

/// Is `buf` a bare control-plane status line (`OK ...` / `ERR ...`, no 0x1e)?
/// A framed reply body could itself begin with "ERR ", so the reader pairs this
/// with a settle timeout: a bare line with no 0x1e arriving within the grace is
/// treated as a status line, not a framed reply. Mirrors nether-ctl read_reply.
pub fn bareStatusLine(buf: []const u8) bool {
    return std.mem.startsWith(u8, buf, "ERR ") or std.mem.startsWith(u8, buf, "OK ");
}

/// Un-escape a framed reply body in place (inverse of the agent's write_escaped):
/// `ESC, X -> X ^ 0x40`; a dangling trailing ESC (its pair truncated away) is
/// dropped. Returns the decoded length (escapes only shrink). Escape-free bodies
/// are byte-identical.
pub fn unescapeBody(buf: []u8) usize {
    var n: usize = 0;
    var esc = false;
    for (buf) |b| {
        if (esc) {
            buf[n] = b ^ ESC_XOR;
            n += 1;
            esc = false;
        } else if (b == ESC) {
            esc = true;
        } else {
            buf[n] = b;
            n += 1;
        }
    }
    return n;
}

/// Build a framed reply `<escaped-body>0x1e<exit>\n` into `out`. The body is
/// escaped so its bytes cannot forge the trailer. Returns the written slice, or
/// error.NoSpace if `out` is too small. This is the north side's reply emitter;
/// it matches what control_stub.py produces (`<path>0x1e0\n` for an escape-free
/// path) and what swerver's control_client parses.
pub fn buildReply(out: []u8, body: []const u8, exit: u8) error{NoSpace}![]u8 {
    var n: usize = 0;
    for (body) |b| {
        if (b == RS or b == ESC) {
            if (n + 2 > out.len) return error.NoSpace;
            out[n] = ESC;
            out[n + 1] = b ^ ESC_XOR;
            n += 2;
        } else {
            if (n + 1 > out.len) return error.NoSpace;
            out[n] = b;
            n += 1;
        }
    }
    // Trailer: RS <exit-digits> \n.
    const trailer = std.fmt.bufPrint(out[n..], "{c}{d}\n", .{ RS, exit }) catch return error.NoSpace;
    return out[0 .. n + trailer.len];
}

/// Verify a __info__ report carries a supported `proto_version` (1 or 2). v2
/// frames every ack (removing the v1 bare/framed ambiguity); the supervisor's
/// drive() already reads framed replies, so it interoperates with either. The
/// reply reader is v1-shaped and works against a v2 server (framed acks parse
/// transparently, bare-line handling simply never triggers).
pub fn verifyProtoVersion(report: []const u8) bool {
    const key = "proto_version=";
    const at = std.mem.indexOf(u8, report, key) orelse return false;
    var i = at + key.len;
    var n: u32 = 0;
    var saw_digit = false;
    while (i < report.len and report[i] >= '0' and report[i] <= '9') : (i += 1) {
        n = n * 10 + (report[i] - '0');
        saw_digit = true;
    }
    return saw_digit and (n == 1 or n == 2);
}

// ── Tests (ported from swerver control_client.zig + new codec tests) ──────

const testing = std.testing;

test "verifyProtoVersion accepts v1 and v2, rejects others" {
    try testing.expect(verifyProtoVersion("nether sandbox info\nproto_version=1\nbackend=hvf\n"));
    try testing.expect(verifyProtoVersion("nether sandbox info\nproto_version=2\nbackend=hvf\n"));
    try testing.expect(!verifyProtoVersion("nether sandbox info\nproto_version=3\n"));
    try testing.expect(!verifyProtoVersion("nether sandbox info\n"));
    try testing.expect(!verifyProtoVersion("proto_version=\n"));
    try testing.expect(verifyProtoVersion("proto_version=1"));
}

test "buildReply emits <path>0x1e0 for an escape-free body (control_stub parity)" {
    var out: [128]u8 = undefined;
    const r = try buildReply(&out, "/tmp/vm-a.sock", 0);
    try testing.expectEqualStrings("/tmp/vm-a.sock\x1e0\n", r);
    const r1 = try buildReply(&out, "no VM socket for tenant", 1);
    try testing.expectEqualStrings("no VM socket for tenant\x1e1\n", r1);
}

test "buildReply escapes a body 0x1e/0x1f so it cannot forge the trailer" {
    var out: [64]u8 = undefined;
    // Body "A<0x1e>B" -> the 0x1e is escaped to 0x1f,0x5e; trailer 0x1e is raw.
    const r = try buildReply(&out, "A\x1eB", 0);
    try testing.expectEqualStrings("A\x1f\x5eB\x1e0\n", r);
}

test "parseFrame + unescapeBody round-trips a body containing literal 0x1e" {
    // A wire frame built by buildReply parses back and un-escapes to the literal.
    var wire: [64]u8 = undefined;
    const framed = try buildReply(&wire, "x\x1ey", 7);
    var recv: [64]u8 = undefined;
    @memcpy(recv[0..framed.len], framed);
    const f = parseFrame(recv[0..framed.len]) orelse return error.NoFrame;
    try testing.expectEqual(@as(u8, 7), f.exit);
    try testing.expectEqual(framed.len, f.consumed);
    var body_buf: [32]u8 = undefined;
    @memcpy(body_buf[0..f.body.len], f.body);
    const decoded = unescapeBody(body_buf[0..f.body.len]);
    try testing.expectEqualStrings("x\x1ey", body_buf[0..decoded]);
}

test "parseFrame is incomplete until the trailer newline lands" {
    try testing.expect(parseFrame("data\x1e0") == null); // 0x1e but no \n
    try testing.expect(parseFrame("data with no sep yet") == null);
    const f = parseFrame("data\x1e0\n") orelse return error.NoFrame;
    try testing.expectEqualStrings("data", f.body);
    try testing.expectEqual(@as(u8, 0), f.exit);
}

test "bareStatusLine + completeLine detect an unframed ERR/OK" {
    try testing.expect(bareStatusLine("ERR agent not connected\n"));
    try testing.expect(bareStatusLine("OK shutting down\n"));
    try testing.expect(!bareStatusLine("data\x1e0\n"));
    try testing.expect(completeLine("ERR x") == null); // no newline yet
    try testing.expectEqualStrings("ERR x\n", completeLine("ERR x\nmore").?);
}

test "unescapeBody drops a dangling trailing escape and keeps escape-free bytes" {
    var b1 = "abc\x1f".*; // dangling ESC
    try testing.expectEqual(@as(usize, 3), unescapeBody(&b1));
    var b2 = "plain".*;
    try testing.expectEqual(@as(usize, 5), unescapeBody(&b2));
    try testing.expectEqualStrings("plain", &b2);
}
