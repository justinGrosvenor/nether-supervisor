//! Optional observability surface: a tiny HTTP server exposing `/status` (JSON)
//! and `/metrics` (Prometheus text), mirroring the pool gauges swerver tracks
//! per tenant. Off unless `status_addr` is configured. Auth is a constant-time
//! service-key check on `Authorization: Bearer <key>` (the seam borrowed from
//! swerver-platform's requireServiceAuth) - loopback-only in practice, but the
//! key stops a same-host process from scraping tenant counts.
//!
//! The gauge source is injected as a Provider (fn + ctx) so this module is
//! unit-tested without a live pool: the Supervisor supplies the real snapshot.

const std = @import("std");
const os = @import("os.zig");
const log = @import("log.zig");

pub const Gauges = struct {
    vms_warm: u32 = 0,
    vms_booting: u32 = 0,
    ensures: u64 = 0,
    hits: u64 = 0,
    misses: u64 = 0,
    reclaims: u64 = 0,
    evictions: u64 = 0,
    boot_failures: u64 = 0,
};

/// Injected gauge source. `snapshot` reads a consistent Gauges (the Supervisor
/// takes its pool lock inside).
pub const Provider = struct {
    ctx: *anyopaque,
    snapshot: *const fn (ctx: *anyopaque) Gauges,
};

/// Constant-time byte compare: fold every byte so the loop time does not depend
/// on where the first mismatch is (no early-exit timing leak on the secret).
/// Length is compared up front; the key length is not itself a secret.
pub fn constantTimeEq(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |x, y| diff |= x ^ y;
    return diff == 0;
}

fn asciiEqlLower(s: []const u8, comptime lower: []const u8) bool {
    if (s.len != lower.len) return false;
    for (s, lower) |c, l| {
        if (std.ascii.toLower(c) != l) return false;
    }
    return true;
}

pub const Request = struct {
    method: []const u8,
    path: []const u8,
    bearer: []const u8 = "", // token from `Authorization: Bearer <t>`, or ""
};

/// Parse just enough of an HTTP request: the request line + a Bearer token.
/// Returns null if the request line is malformed.
pub fn parseRequest(raw: []const u8) ?Request {
    const line_end = std.mem.indexOfScalar(u8, raw, '\n') orelse return null;
    var first = raw[0..line_end];
    if (first.len > 0 and first[first.len - 1] == '\r') first = first[0 .. first.len - 1];
    var it = std.mem.tokenizeScalar(u8, first, ' ');
    const method = it.next() orelse return null;
    const path = it.next() orelse return null;

    var bearer: []const u8 = "";
    var lines = std.mem.splitScalar(u8, raw[line_end + 1 ..], '\n');
    while (lines.next()) |h0| {
        var h = h0;
        if (h.len > 0 and h[h.len - 1] == '\r') h = h[0 .. h.len - 1];
        if (h.len == 0) break; // end of headers
        const name_end = std.mem.indexOfScalar(u8, h, ':') orelse continue;
        if (!asciiEqlLower(h[0..name_end], "authorization")) continue;
        const val = std.mem.trim(u8, h[name_end + 1 ..], " \t");
        if (val.len >= 7 and asciiEqlLower(val[0..7], "bearer ")) {
            bearer = std.mem.trim(u8, val[7..], " \t");
        }
    }
    return .{ .method = method, .path = path, .bearer = bearer };
}

pub fn buildStatusJson(g: Gauges, out: []u8) []const u8 {
    return std.fmt.bufPrint(out, "{{\"vms_warm\":{d},\"vms_booting\":{d},\"ensures\":{d},\"hits\":{d},\"misses\":{d},\"reclaims\":{d},\"evictions\":{d},\"boot_failures\":{d}}}\n", .{
        g.vms_warm, g.vms_booting, g.ensures, g.hits, g.misses, g.reclaims, g.evictions, g.boot_failures,
    }) catch out[0..0];
}

pub fn buildMetrics(g: Gauges, out: []u8) []const u8 {
    return std.fmt.bufPrint(out,
        \\# TYPE nsup_vms_warm gauge
        \\nsup_vms_warm {d}
        \\# TYPE nsup_vms_booting gauge
        \\nsup_vms_booting {d}
        \\# TYPE nsup_ensures_total counter
        \\nsup_ensures_total {d}
        \\# TYPE nsup_hits_total counter
        \\nsup_hits_total {d}
        \\# TYPE nsup_misses_total counter
        \\nsup_misses_total {d}
        \\# TYPE nsup_reclaims_total counter
        \\nsup_reclaims_total {d}
        \\# TYPE nsup_evictions_total counter
        \\nsup_evictions_total {d}
        \\# TYPE nsup_boot_failures_total counter
        \\nsup_boot_failures_total {d}
        \\
    , .{
        g.vms_warm, g.vms_booting, g.ensures, g.hits, g.misses, g.reclaims, g.evictions, g.boot_failures,
    }) catch out[0..0];
}

pub const Server = struct {
    ip: []const u8,
    port: u16,
    service_key: []const u8,
    provider: Provider,

    /// Bind and serve forever. Runs on its own thread; logs and returns if the
    /// bind fails (observability is best-effort, never fatal to the supervisor).
    pub fn run(self: *Server) void {
        const fd = os.listenTcp(self.ip, self.port) catch |e| {
            log.err("status: listen {s}:{d} failed: {s}", .{ self.ip, self.port, @errorName(e) });
            return;
        };
        log.info("status surface listening on {s}:{d}", .{ self.ip, self.port });
        while (true) {
            const conn = os.acceptConn(fd) catch continue;
            self.serveOne(conn);
            os.closeFd(conn);
        }
    }

    fn serveOne(self: *Server, conn: std.posix.fd_t) void {
        var buf: [4096]u8 = undefined;
        const n = os.readSome(conn, &buf) catch return;
        if (n == 0) return;
        const req = parseRequest(buf[0..n]) orelse return writeResp(conn, "400 Bad Request", "text/plain", "bad request\n");

        // Auth (when a key is configured). Constant-time compare.
        if (self.service_key.len > 0 and !constantTimeEq(req.bearer, self.service_key)) {
            return writeResp(conn, "401 Unauthorized", "text/plain", "unauthorized\n");
        }

        var out: [1024]u8 = undefined;
        if (std.mem.eql(u8, req.path, "/status")) {
            const g = self.provider.snapshot(self.provider.ctx);
            writeResp(conn, "200 OK", "application/json", buildStatusJson(g, &out));
        } else if (std.mem.eql(u8, req.path, "/metrics")) {
            const g = self.provider.snapshot(self.provider.ctx);
            writeResp(conn, "200 OK", "text/plain; version=0.0.4", buildMetrics(g, &out));
        } else {
            writeResp(conn, "404 Not Found", "text/plain", "not found\n");
        }
    }
};

fn writeResp(conn: std.posix.fd_t, status: []const u8, ctype: []const u8, body: []const u8) void {
    var hdr: [256]u8 = undefined;
    const h = std.fmt.bufPrint(&hdr, "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ status, ctype, body.len }) catch return;
    os.writeAll(conn, h) catch return;
    os.writeAll(conn, body) catch return;
}

// ── Tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

test "constantTimeEq matches only equal slices" {
    try testing.expect(constantTimeEq("secret", "secret"));
    try testing.expect(!constantTimeEq("secret", "secreu"));
    try testing.expect(!constantTimeEq("secret", "secre"));
    try testing.expect(!constantTimeEq("", "x"));
    try testing.expect(constantTimeEq("", ""));
}

test "parseRequest extracts method, path, bearer" {
    const raw = "GET /metrics HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer abc123\r\n\r\n";
    const r = parseRequest(raw) orelse return error.ParseFailed;
    try testing.expectEqualStrings("GET", r.method);
    try testing.expectEqualStrings("/metrics", r.path);
    try testing.expectEqualStrings("abc123", r.bearer);
}

test "parseRequest tolerates a missing/again-cased auth header" {
    const raw = "GET /status HTTP/1.1\r\nhost: y\r\n\r\n";
    const r = parseRequest(raw) orelse return error.ParseFailed;
    try testing.expectEqualStrings("/status", r.path);
    try testing.expectEqualStrings("", r.bearer);

    const raw2 = "GET /status HTTP/1.1\r\nAUTHORIZATION: bearer TOK\r\n\r\n";
    const r2 = parseRequest(raw2) orelse return error.ParseFailed;
    try testing.expectEqualStrings("TOK", r2.bearer);
}

test "buildStatusJson renders every gauge" {
    var out: [512]u8 = undefined;
    const j = buildStatusJson(.{ .vms_warm = 3, .vms_booting = 1, .ensures = 10, .hits = 7, .misses = 3, .reclaims = 2, .evictions = 1, .boot_failures = 0 }, &out);
    try testing.expectEqualStrings("{\"vms_warm\":3,\"vms_booting\":1,\"ensures\":10,\"hits\":7,\"misses\":3,\"reclaims\":2,\"evictions\":1,\"boot_failures\":0}\n", j);
}

test "buildMetrics emits prometheus lines" {
    var out: [1024]u8 = undefined;
    const m = buildMetrics(.{ .vms_warm = 3, .vms_booting = 1, .ensures = 10, .hits = 7, .misses = 3, .reclaims = 2, .evictions = 1, .boot_failures = 0 }, &out);
    try testing.expect(std.mem.indexOf(u8, m, "nsup_vms_warm 3\n") != null);
    try testing.expect(std.mem.indexOf(u8, m, "nsup_ensures_total 10\n") != null);
    try testing.expect(std.mem.indexOf(u8, m, "nsup_boot_failures_total 0\n") != null);
}

test "parseIpv4 round-trips loopback and rejects junk" {
    try testing.expectEqual(@as(?u32, 0x7f000001), os.parseIpv4("127.0.0.1"));
    try testing.expectEqual(@as(?u32, 0), os.parseIpv4("0.0.0.0"));
    try testing.expectEqual(@as(?u32, null), os.parseIpv4("127.0.0"));
    try testing.expectEqual(@as(?u32, null), os.parseIpv4("127.0.0.256"));
    try testing.expectEqual(@as(?u32, null), os.parseIpv4("x.y.z.w"));
}
