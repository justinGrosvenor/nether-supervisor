//! The supervisor's own configuration: a `key = value` file (same format nether
//! uses for `nether.conf`). Loaded
//! once at startup and owned for the process lifetime (an arena backs the duped
//! strings). See the plan for the full key list.

const std = @import("std");

/// Longest UNIX-domain socket path we will ever bind/connect. macOS
/// `sockaddr_un.sun_path` is 104 bytes including the NUL; Linux is 108. Use the
/// smaller so a config that works on macOS works everywhere.
pub const SUN_PATH_MAX: usize = 104;

/// The longest per-VM socket basename the supervisor generates under
/// `socket_dir` / `work_root`, e.g. "<vm-id>.control.sock" with a short hex id.
/// Kept as a constant so the startup guard can reason about the worst case
/// without knowing a specific VM id yet.
pub const MAX_VM_SOCK_BASENAME: usize = "abcdef01.control.sock".len; // 8-hex id + suffix

pub const Config = struct {
    arena: std.heap.ArenaAllocator,

    // Paths (duped into the arena when overridden).
    control_socket: []const u8 = "/tmp/nsup/control.sock",
    socket_dir: []const u8 = "/tmp/nsup",
    work_root: []const u8 = "/tmp/nsup/vms",
    kernels_dir: []const u8 = "",
    base_snap: []const u8 = "", // empty => cold-boot (no fork)
    nether_bin: []const u8 = "",
    launcher_mode: []const u8 = "real", // "real" | "fake" (fake deferred)
    status_addr: []const u8 = "", // empty => status surface off
    status_service_key: []const u8 = "",
    /// The guest image launches its HTTP service during init. When false, the
    /// supervisor launches its built-in demo server after the agent is ready.
    guest_service_prestarted: bool = false,

    // Scalars.
    app_port: u16 = 8080,
    cpus: u16 = 1,
    // >= 384 is the floor: nether places the ~64 MiB runtime initramfs at the
    // ~192 MiB offset, so 256 leaves no room to mount the rootfs and the guest
    // panics ("VFS: Unable to mount root fs"). 512 for headroom (per NETHER).
    ram_mb: u32 = 512,
    max_vms: u32 = 16,
    idle_ttl_ms: u64 = 60_000,
    idle_timeout_s: u32 = 90,
    boot_budget_ms: u64 = 30_000,

    pub fn deinit(self: *Config) void {
        self.arena.deinit();
    }

    fn dupe(self: *Config, val: []const u8) ![]const u8 {
        return self.arena.allocator().dupe(u8, val);
    }

    /// Apply a single `key`/`val` pair (from the file or an env override).
    /// Unknown keys are ignored with a note-return so the caller can warn.
    /// Returns error on a malformed integer.
    pub fn applyPair(self: *Config, key: []const u8, val: []const u8) !bool {
        if (std.mem.eql(u8, key, "control_socket")) {
            self.control_socket = try self.dupe(val);
        } else if (std.mem.eql(u8, key, "socket_dir")) {
            self.socket_dir = try self.dupe(val);
        } else if (std.mem.eql(u8, key, "work_root")) {
            self.work_root = try self.dupe(val);
        } else if (std.mem.eql(u8, key, "kernels_dir")) {
            self.kernels_dir = try self.dupe(val);
        } else if (std.mem.eql(u8, key, "base_snap")) {
            self.base_snap = try self.dupe(val);
        } else if (std.mem.eql(u8, key, "nether_bin")) {
            self.nether_bin = try self.dupe(val);
        } else if (std.mem.eql(u8, key, "launcher_mode")) {
            self.launcher_mode = try self.dupe(val);
        } else if (std.mem.eql(u8, key, "status_addr")) {
            self.status_addr = try self.dupe(val);
        } else if (std.mem.eql(u8, key, "status_service_key")) {
            self.status_service_key = try self.dupe(val);
        } else if (std.mem.eql(u8, key, "guest_service_prestarted")) {
            self.guest_service_prestarted = if (std.mem.eql(u8, val, "true"))
                true
            else if (std.mem.eql(u8, val, "false"))
                false
            else
                return error.InvalidBoolean;
        } else if (std.mem.eql(u8, key, "app_port")) {
            self.app_port = try std.fmt.parseInt(u16, val, 10);
        } else if (std.mem.eql(u8, key, "cpus")) {
            self.cpus = try std.fmt.parseInt(u16, val, 10);
        } else if (std.mem.eql(u8, key, "ram_mb")) {
            self.ram_mb = try std.fmt.parseInt(u32, val, 10);
        } else if (std.mem.eql(u8, key, "max_vms")) {
            self.max_vms = try std.fmt.parseInt(u32, val, 10);
        } else if (std.mem.eql(u8, key, "idle_ttl_ms")) {
            self.idle_ttl_ms = try std.fmt.parseInt(u64, val, 10);
        } else if (std.mem.eql(u8, key, "idle_timeout_s")) {
            self.idle_timeout_s = try std.fmt.parseInt(u32, val, 10);
        } else if (std.mem.eql(u8, key, "boot_budget_ms")) {
            self.boot_budget_ms = try std.fmt.parseInt(u64, val, 10);
        } else {
            return false; // unknown key
        }
        return true;
    }

    /// Parse a `key = value` config file body. `#` starts a comment; blank
    /// lines are skipped; whitespace around key and value is trimmed. Returns
    /// the count of unknown keys (caller may warn); errors on a malformed int.
    pub fn parseText(self: *Config, text: []const u8) !usize {
        var unknown: usize = 0;
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |raw_line| {
            // Strip an inline comment, then trim.
            const no_comment = if (std.mem.indexOfScalar(u8, raw_line, '#')) |h| raw_line[0..h] else raw_line;
            const line = std.mem.trim(u8, no_comment, " \t\r");
            if (line.len == 0) continue;
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const key = std.mem.trim(u8, line[0..eq], " \t");
            const val = std.mem.trim(u8, line[eq + 1 ..], " \t");
            if (!try self.applyPair(key, val)) unknown += 1;
        }
        return unknown;
    }

    /// Validate that every UNIX socket path the supervisor may bind/connect
    /// fits `sun_path`. Fail fast at startup rather than at a later `bind()`.
    pub fn validateSunPath(self: *const Config) SunPathError!void {
        // control_socket is used as-is.
        if (self.control_socket.len + 1 > SUN_PATH_MAX) return error.ControlSocketTooLong;
        // Per-VM sockets are "<socket_dir>/<basename>". +1 for the '/'.
        const worst = self.socket_dir.len + 1 + MAX_VM_SOCK_BASENAME + 1; // +1 NUL
        if (worst > SUN_PATH_MAX) return error.SocketDirTooLong;
        const worst_work = self.work_root.len + 1 + MAX_VM_SOCK_BASENAME + 1;
        if (worst_work > SUN_PATH_MAX) return error.WorkRootTooLong;
    }
};

pub const SunPathError = error{
    ControlSocketTooLong,
    SocketDirTooLong,
    WorkRootTooLong,
};

/// Default config file basename, read from the process cwd (nether-style).
pub const DEFAULT_PATH = "nether-supervisor.conf";

pub fn init(gpa: std.mem.Allocator) Config {
    return .{ .arena = std.heap.ArenaAllocator.init(gpa) };
}

// ── Tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

test "parseText applies keys, trims, and skips comments/blanks" {
    var cfg = init(testing.allocator);
    defer cfg.deinit();
    const text =
        \\# a comment
        \\control_socket = /run/nsup/ctl.sock
        \\
        \\socket_dir=/run/nsup   # inline comment
        \\max_vms = 8
        \\app_port = 9090
        \\guest_service_prestarted = true
        \\bogus_key = whatever
    ;
    const unknown = try cfg.parseText(text);
    try testing.expectEqual(@as(usize, 1), unknown); // bogus_key
    try testing.expectEqualStrings("/run/nsup/ctl.sock", cfg.control_socket);
    try testing.expectEqualStrings("/run/nsup", cfg.socket_dir);
    try testing.expectEqual(@as(u32, 8), cfg.max_vms);
    try testing.expectEqual(@as(u16, 9090), cfg.app_port);
    try testing.expect(cfg.guest_service_prestarted);
    // Untouched keys keep defaults.
    try testing.expectEqual(@as(u16, 1), cfg.cpus);
}

test "parseText errors on a malformed integer" {
    var cfg = init(testing.allocator);
    defer cfg.deinit();
    try testing.expectError(error.InvalidCharacter, cfg.parseText("cpus = not-a-number\n"));
}

test "parseText errors on a malformed boolean" {
    var cfg = init(testing.allocator);
    defer cfg.deinit();
    try testing.expectError(error.InvalidBoolean, cfg.parseText("guest_service_prestarted = yes\n"));
}

test "validateSunPath accepts short paths and rejects over-long ones" {
    var cfg = init(testing.allocator);
    defer cfg.deinit();
    // Defaults are short and fine.
    try cfg.validateSunPath();

    // An over-long socket_dir must be rejected up front.
    const long = "/" ++ ("x" ** (SUN_PATH_MAX));
    _ = try cfg.parseText("socket_dir = " ++ long ++ "\n");
    try testing.expectError(error.SocketDirTooLong, cfg.validateSunPath());
}
