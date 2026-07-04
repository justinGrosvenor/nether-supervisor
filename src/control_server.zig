//! North side: the control socket swerver's `wasm_control_socket` dials. Speaks
//! the nether control protocol (proto_version=1) so swerver's control_client
//! talks to the supervisor exactly as it would to a real nether. Answers:
//!   __info__        -> a framed proto_version=1 report.
//!   ensure <tenant> -> the tenant's warm VM data_socket path (framed exit 0),
//!                      or a framed failure (exit 1).
//! The line dispatch is a pure function so it is unit-tested without a socket;
//! the accept loop is a thin wrapper (Phase V uses a simple blocking loop; the
//! poll reactor + pool wiring land in Phase 3).

const std = @import("std");
const proto = @import("proto.zig");

/// The report answered to `__info__`. Static; advertises proto_version=1 so
/// swerver's handshake accepts us as a v1 control endpoint.
pub const INFO_REPORT = "nether-supervisor\nproto_version=1\nbackend=supervisor\n";

/// Result of resolving `ensure <tenant>`: a socket path (success) or a reason
/// (failure). The path/reason slices must outlive the reply build.
pub const EnsureResult = union(enum) {
    ok: []const u8, // data_socket path
    fail: []const u8, // reason
};

/// Callback the accept loop invokes for `ensure <tenant>`. `ctx` is the pool.
pub const EnsureFn = *const fn (ctx: *anyopaque, tenant: []const u8) EnsureResult;

/// Outcome of dispatching one request line.
pub const Dispatch = union(enum) {
    /// A framed reply to send back (slice into `out`).
    reply: []const u8,
    /// A blank line (swerver appends a trailing newline): send nothing.
    ignore,
};

/// Handle one request line (without its trailing newline), writing any reply
/// into `out`. Pure except for the ensure callback. Unknown verbs get a framed
/// error so a caller never hangs.
pub fn handleLine(
    line: []const u8,
    ensure_fn: EnsureFn,
    ctx: *anyopaque,
    out: []u8,
) error{NoSpace}!Dispatch {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0) return .ignore;

    if (std.mem.eql(u8, trimmed, "__info__")) {
        return .{ .reply = try proto.buildReply(out, INFO_REPORT, 0) };
    }

    if (std.mem.startsWith(u8, trimmed, "ensure")) {
        // "ensure <tenant>" - split on the first space.
        var it = std.mem.tokenizeScalar(u8, trimmed, ' ');
        _ = it.next(); // "ensure"
        const tenant = it.next() orelse {
            return .{ .reply = try proto.buildReply(out, "ensure requires a tenant", 1) };
        };
        switch (ensure_fn(ctx, tenant)) {
            .ok => |path| return .{ .reply = try proto.buildReply(out, path, 0) },
            .fail => |reason| return .{ .reply = try proto.buildReply(out, reason, 1) },
        }
    }

    // Unknown verb: a framed error (exit 127), mirroring the stub.
    return .{ .reply = try proto.buildReply(out, "supervisor: unknown command", 127) };
}

// ── Tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

const StubPool = struct {
    reply_path: []const u8,
    known_tenant: []const u8,
    calls: usize = 0,

    fn ensure(ctx: *anyopaque, tenant: []const u8) EnsureResult {
        const self: *StubPool = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        if (std.mem.eql(u8, tenant, self.known_tenant)) return .{ .ok = self.reply_path };
        return .{ .fail = "no VM socket for tenant" };
    }
};

test "handleLine: __info__ answers a framed proto_version=1 report" {
    var pool = StubPool{ .reply_path = "/tmp/x.sock", .known_tenant = "alpha" };
    var out: [256]u8 = undefined;
    const d = try handleLine("__info__", StubPool.ensure, &pool, &out);
    switch (d) {
        .reply => |r| {
            try testing.expect(std.mem.endsWith(u8, r, "\x1e0\n"));
            try testing.expect(proto.verifyProtoVersion(r));
        },
        .ignore => return error.Unexpected,
    }
}

test "handleLine: ensure <known> returns the data_socket path framed exit 0" {
    var pool = StubPool{ .reply_path = "/tmp/nsup/alpha.data.sock", .known_tenant = "alpha" };
    var out: [256]u8 = undefined;
    const d = try handleLine("ensure alpha", StubPool.ensure, &pool, &out);
    try testing.expectEqualStrings("/tmp/nsup/alpha.data.sock\x1e0\n", d.reply);
    try testing.expectEqual(@as(usize, 1), pool.calls);
}

test "handleLine: ensure <unknown> fails framed exit 1; missing arg fails" {
    var pool = StubPool{ .reply_path = "/tmp/x.sock", .known_tenant = "alpha" };
    var out: [256]u8 = undefined;
    const d = try handleLine("ensure beta", StubPool.ensure, &pool, &out);
    try testing.expectEqualStrings("no VM socket for tenant\x1e1\n", d.reply);
    const d2 = try handleLine("ensure", StubPool.ensure, &pool, &out);
    try testing.expect(std.mem.endsWith(u8, d2.reply, "\x1e1\n"));
}

test "handleLine: blank line is ignored; unknown verb is a framed error" {
    var pool = StubPool{ .reply_path = "/tmp/x.sock", .known_tenant = "alpha" };
    var out: [256]u8 = undefined;
    try testing.expect((try handleLine("", StubPool.ensure, &pool, &out)) == .ignore);
    try testing.expect((try handleLine("   ", StubPool.ensure, &pool, &out)) == .ignore);
    const d = try handleLine("__frobnicate__", StubPool.ensure, &pool, &out);
    try testing.expect(std.mem.endsWith(u8, d.reply, "\x1e127\n"));
}
