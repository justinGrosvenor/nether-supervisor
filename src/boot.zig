//! RealLauncher: fork/exec a real `nether` process in a per-VM working directory
//! and drive it to a serving state. This is the production south side (the
//! MockLauncher is its unit-test stand-in). The bring-up sequence is the recipe
//! proven by nether's scripts/fork_serve.py:
//!   boot -> __info__ (proto_version=1) -> `echo ready` until the agent answers
//!   -> optionally drive SRV (start the built-in in-guest HTTP server on
//!   app_port) -> probe the data_socket over HTTP until it serves.
//! A fork inherits a data plane already proven before snapshot. Its successful
//! control handshake is the restore barrier; consuming an HTTP request as a
//! second readiness probe would mutate a one-shot guest before the real request.

const std = @import("std");
const os = @import("os.zig");
const control_client = @import("control_client.zig");
const reader = @import("control_reader.zig");
const readiness = @import("readiness.zig");
const vm = @import("vm.zig");
const log = @import("log.zig");

/// The exact control line that starts the in-guest HTTP server on 127.0.0.1:8080
/// (matches fork_serve.py's SRV): a threaded python responder returning
/// `IID=<id> REQ=<n>`, backgrounded. The `\r\n`/`\n` are LITERAL escape sequences
/// on the wire (the guest's python interprets them); the quotes are for the guest
/// shell. Bound to app_port 8080 (parameterizing it is a later refinement).
pub const SRV =
    "python3 -c \"" ++
    "import socket as k,threading as t,random,itertools as z;" ++
    "ID=str(random.randint(10**8,10**9));open('/tmp/iid','w').write(ID);" ++
    "L=k.socket(k.AF_INET,k.SOCK_STREAM);L.setsockopt(k.SOL_SOCKET,k.SO_REUSEADDR,1);" ++
    "L.bind(('127.0.0.1',8080));L.listen(32);cnt=z.count(1);" ++
    "mk=lambda n:('IID=%s REQ=%d\\n'%(ID,n)).encode();" ++
    "snd=lambda s,b:s.sendall(b'HTTP/1.1 200 OK\\r\\nContent-Length: '+str(len(b)).encode()+b'\\r\\nConnection: close\\r\\n\\r\\n'+b);" ++
    "h=lambda s:(s.recv(4096),snd(s,mk(next(cnt))),s.close());" ++
    "open('/tmp/up','w').write('UP');" ++
    "[t.Thread(target=h,args=(L.accept()[0],),daemon=True).start() for _ in iter(int,1)]" ++
    "\" >/tmp/srv.log 2>&1 &";

pub const RealLauncher = struct {
    nether_bin: []const u8,
    kernels_dir: []const u8,
    work_root: []const u8,
    app_port: u16,
    cpus: u16,
    ram_mb: u32,
    idle_timeout_s: u32,
    idle_ttl_ms: u64 = 60_000,

    pub const Error = error{ MkdirFailed, WriteFailed, ForkFailed, PathTooLong, MissingArtifact, InvalidArtifact, SymlinkFailed };

    /// Spawn a cold-boot nether process. Returns the child pid. The VM's control
    /// and data sockets (absolute, under the caller's socket_dir) are written
    /// into the generated nether.conf; kernels are symlinked into the cwd.
    pub fn spawnCold(self: *const RealLauncher, id: u32, control_socket: []const u8, data_socket: []const u8) Error!std.c.pid_t {
        return self.spawn(id, control_socket, data_socket, "");
    }

    /// Spawn a fork (restore) from `base_snap`. The restore inherits the base's
    /// RAM (running server + data plane) over CoW, so cpus/ram_mb/kernels are
    /// unused; only restore=1 + restore_from and the fresh sockets matter. This
    /// is the warm path (~76ms to first byte vs a multi-second cold boot).
    pub fn spawnFork(self: *const RealLauncher, id: u32, control_socket: []const u8, data_socket: []const u8, base_snap: []const u8) Error!std.c.pid_t {
        return self.spawn(id, control_socket, data_socket, base_snap);
    }

    fn prepareArtifacts(self: *const RealLauncher, cwd: []const u8, target_os: std.Target.Os.Tag) Error!void {
        var source_z_buf: [512]u8 = undefined;
        const source_z = std.fmt.bufPrintZ(&source_z_buf, "{s}", .{self.kernels_dir}) catch return error.PathTooLong;
        // Symlink targets must survive the child's chdir, including when the
        // operator supplied a relative kernels_dir.
        var resolved: [std.fs.max_path_bytes]u8 = undefined;
        const source = std.mem.span(std.c.realpath(source_z, &resolved) orelse {
            log.err("guest artifacts directory unavailable: {s}", .{self.kernels_dir});
            return error.MissingArtifact;
        });
        const required: []const []const u8 = if (target_os == .linux)
            &.{ "vmlinux", "initramfs" }
        else
            &.{ "Image", "initramfs.cpio.gz" };
        for (required) |name| {
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const path = std.fmt.bufPrintZ(&path_buf, "{s}/{s}", .{ source, name }) catch return error.PathTooLong;
            try requireArtifact(path);
        }
        const links = [_]struct { name: []const u8, suffix: []const u8 }{
            .{ .name = "kernels", .suffix = "" },
            .{ .name = "vmlinux", .suffix = "/vmlinux" },
            .{ .name = "initramfs", .suffix = "/initramfs" },
        };
        for (links) |link| {
            var link_buf: [600]u8 = undefined;
            var target_buf: [std.fs.max_path_bytes]u8 = undefined;
            const link_z = std.fmt.bufPrintZ(&link_buf, "{s}/{s}", .{ cwd, link.name }) catch return error.PathTooLong;
            const target_z = std.fmt.bufPrintZ(&target_buf, "{s}{s}", .{ source, link.suffix }) catch return error.PathTooLong;
            os.symlinkForceZ(target_z, link_z) catch return error.SymlinkFailed;
        }
    }

    /// Shared spawn: build the per-VM cwd + nether.conf and fork/exec nether.
    /// `restore_from` empty => cold boot; non-empty => fork from that snapshot.
    fn spawn(self: *const RealLauncher, id: u32, control_socket: []const u8, data_socket: []const u8, restore_from: []const u8) Error!std.c.pid_t {
        const is_fork = restore_from.len > 0;

        // Clear stale sockets a prior crashed run may have left at these paths
        // (vm ids reset per process, so a restart reuses them) - nether would
        // otherwise fail to bind.
        os.unlinkPath(control_socket);
        os.unlinkPath(data_socket);

        var cwd_buf: [512]u8 = undefined;
        const cwd = std.fmt.bufPrintZ(&cwd_buf, "{s}/{x:0>8}", .{ self.work_root, id }) catch return error.PathTooLong;

        // work_root + the per-VM cwd.
        var root_z_buf: [512]u8 = undefined;
        const root_z = std.fmt.bufPrintZ(&root_z_buf, "{s}", .{self.work_root}) catch return error.PathTooLong;
        os.mkdirZ(root_z);
        os.mkdirZ(cwd);

        // A restore reads the snapshot; a cold boot must have readable guest
        // artifacts before fork, so missing vmlinux cannot select a smoke guest.
        if (!is_fork) try self.prepareArtifacts(cwd, @import("builtin").os.tag);

        // Write the nether.conf into the cwd (fork adds restore=1 + restore_from).
        var conf_buf: [1024]u8 = undefined;
        const conf_text = vm.bootConfText(&conf_buf, .{
            .id = "",
            .control_socket = control_socket,
            .data_socket = data_socket,
            .restore_from = restore_from,
            .app_port = self.app_port,
            .cpus = self.cpus,
            .ram_mb = self.ram_mb,
            .idle_timeout_s = self.idle_timeout_s,
            .idle_timeout_ms = vm.effectiveIdleMs(self.idle_ttl_ms, self.idle_timeout_s),
        }) catch return error.WriteFailed;
        var conf_path_buf: [600]u8 = undefined;
        const conf_path = std.fmt.bufPrint(&conf_path_buf, "{s}/nether.conf", .{cwd}) catch return error.PathTooLong;
        os.writeFile(conf_path, conf_text) catch return error.WriteFailed;

        // Prepare NUL-terminated exec args before forking (no allocation in the child).
        var bin_buf: [512]u8 = undefined;
        const bin_z = std.fmt.bufPrintZ(&bin_buf, "{s}", .{self.nether_bin}) catch return error.PathTooLong;
        var logpath_buf: [600]u8 = undefined;
        const log_z = std.fmt.bufPrintZ(&logpath_buf, "{s}/nether.log", .{cwd}) catch return error.PathTooLong;

        const pid = std.c.fork();
        if (pid < 0) return error.ForkFailed;
        if (pid == 0) {
            // Child. chdir into the VM cwd, redirect stdio, exec nether.
            _ = std.c.chdir(cwd);
            if (os.openReadZ("/dev/null")) |nfd| _ = std.c.dup2(nfd, 0) else |_| {}
            if (os.openWriteZ(log_z)) |lfd| {
                _ = std.c.dup2(lfd, 1);
                _ = std.c.dup2(lfd, 2);
            } else |_| {}
            var argv = [_:null]?[*:0]const u8{bin_z};
            _ = std.c.execve(bin_z, &argv, std.c.environ);
            std.c._exit(127); // exec failed
        }
        return pid;
    }
};

fn requireArtifact(path: [:0]const u8) RealLauncher.Error!void {
    // NONBLOCK avoids hanging on a mistakenly configured FIFO; fstat excludes
    // directories/devices as well as empty files before the VM is spawned.
    const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{ .NONBLOCK = true }, 0) catch {
        log.err("guest artifact unreadable: {s}", .{path});
        return error.MissingArtifact;
    };
    defer os.closeFd(fd);
    const valid = if (@import("builtin").os.tag == .linux) blk: {
        const linux = std.os.linux;
        var st: linux.Statx = undefined;
        if (linux.errno(linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .TYPE = true, .SIZE = true }, &st)) != .SUCCESS) break :blk false;
        break :blk st.mask.TYPE and st.mask.SIZE and (st.mode & std.posix.S.IFMT) == std.posix.S.IFREG and st.size > 0;
    } else blk: {
        var st: std.c.Stat = undefined;
        if (std.c.fstat(fd, &st) != 0) break :blk false;
        break :blk (st.mode & std.posix.S.IFMT) == std.posix.S.IFREG and st.size > 0;
    };
    if (!valid) {
        log.err("guest artifact must be a nonempty regular file: {s}", .{path});
        return error.InvalidArtifact;
    }
}

pub const BringUpError = error{ Connect, Handshake, AgentTimeout, ServerStart, NotServing };

test "cold artifact setup validates the backend and installs readable links" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const io = std.testing.io;
    try temp.dir.createDir(io, "guest", .default_dir);
    try temp.dir.createDir(io, "vm", .default_dir);
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try temp.dir.realPath(io, &root_buf)];
    var guest_buf: [std.fs.max_path_bytes]u8 = undefined;
    var vm_buf: [std.fs.max_path_bytes]u8 = undefined;
    const guest = try std.fmt.bufPrint(&guest_buf, "{s}/guest", .{root});
    const cwd = try std.fmt.bufPrint(&vm_buf, "{s}/vm", .{root});
    const launcher = RealLauncher{ .nether_bin = "/unused", .kernels_dir = guest, .work_root = cwd, .app_port = 8080, .cpus = 1, .ram_mb = 512, .idle_timeout_s = 90 };
    try std.testing.expectError(error.MissingArtifact, launcher.prepareArtifacts(cwd, .linux));
    try temp.dir.writeFile(io, .{ .sub_path = "guest/vmlinux", .data = "kernel fixture" });
    try temp.dir.writeFile(io, .{ .sub_path = "guest/initramfs", .data = "" });
    try std.testing.expectError(error.InvalidArtifact, launcher.prepareArtifacts(cwd, .linux));
    try temp.dir.writeFile(io, .{ .sub_path = "guest/initramfs", .data = "initramfs fixture" });
    try launcher.prepareArtifacts(cwd, .linux);
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "{s}/initramfs", .{cwd});
    try requireArtifact(path); // follows the link exactly as the child does
    try std.testing.expectError(error.MissingArtifact, launcher.prepareArtifacts(cwd, .macos));
    try temp.dir.writeFile(io, .{ .sub_path = "guest/Image", .data = "arm kernel fixture" });
    try temp.dir.writeFile(io, .{ .sub_path = "guest/initramfs.cpio.gz", .data = "arm initramfs fixture" });
    try launcher.prepareArtifacts(cwd, .macos);
    const arm_path = try std.fmt.bufPrintZ(&path_buf, "{s}/kernels/Image", .{cwd});
    try requireArtifact(arm_path);
    // A directory occupying the link name must surface a setup failure.
    try temp.dir.deleteFile(io, "vm/vmlinux");
    try temp.dir.createDir(io, "vm/vmlinux", .default_dir);
    try std.testing.expectError(error.SymlinkFailed, launcher.prepareArtifacts(cwd, .linux));
}

pub const ServiceActions = struct {
    wait_for_agent: bool,
    start_builtin: bool,
    probe_data: bool,
};

/// Make the warm-fork contract explicit and unit-testable. Cold bases must prove
/// the full data path before snapshot. Restored forks only handshake: probing
/// their data path would consume the first request of a one-shot workload.
pub fn serviceActions(is_fork: bool, guest_service_prestarted: bool) ServiceActions {
    if (is_fork) return .{ .wait_for_agent = false, .start_builtin = false, .probe_data = false };
    return .{
        .wait_for_agent = true,
        .start_builtin = !guest_service_prestarted,
        .probe_data = true,
    };
}

/// Drive a booted VM to a serving state. A cold base waits for the agent,
/// optionally starts the built-in service, and proves HTTP before snapshot. A
/// restored fork returns after its control handshake. Blocks up to `budget_ms`.
pub fn bringUp(control_socket: []const u8, data_socket: []const u8, is_fork: bool, guest_service_prestarted: bool, budget_ms: u64, now_fn: *const fn () u64) BringUpError!void {
    const deadline = now_fn() + budget_ms;
    const actions = serviceActions(is_fork, guest_service_prestarted);

    // 1. Connect the control socket (it may not exist yet; retry).
    var client: control_client.Client = while (now_fn() < deadline) {
        if (control_client.Client.connect(control_socket)) |c| break c else |_| {
            sleepMs(20);
        }
    } else return error.Connect;
    defer client.close();

    // 2. Handshake: __info__ + proto_version=1.
    _ = client.handshake(.{ .hang_ms = 2000 }) catch return error.Handshake;

    if (actions.wait_for_agent) {
        // 3. Wait for the guest agent (echo round-trips).
        while (now_fn() < deadline) {
            const r = client.drive("echo ready", .{ .settle_ms = 200, .hang_ms = 1500 }) catch {
                sleepMs(50);
                continue;
            };
            if (r.framed and std.mem.indexOf(u8, r.body, "ready") != null) break;
            sleepMs(50);
        } else return error.AgentTimeout;
    }

    if (actions.start_builtin) {
        // 4. Start the built-in in-guest HTTP server on app_port.
        const s = client.drive(SRV, .{ .hang_ms = 3000 }) catch return error.ServerStart;
        if (!s.framed) return error.ServerStart;
    }

    if (!actions.probe_data) return;

    // 5. Cold base only: prove the complete data path before snapshot.
    while (now_fn() < deadline) {
        readiness.probeOnce(data_socket) catch {
            sleepMs(30);
            continue;
        };
        return; // serving
    }
    return error.NotServing;
}

fn sleepMs(ms: u64) void {
    var req = std.posix.timespec{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * std.time.ns_per_ms) };
    _ = std.c.nanosleep(&req, null);
}

test {
    // Compile-time reference so the module type-checks in `zig build test`; the
    // live boot is exercised by the gate script (needs real nether + HVF).
    std.testing.refAllDecls(@This());
}

test "service actions preserve the first restored-fork request" {
    const testing = std.testing;

    const builtin_cold = serviceActions(false, false);
    try testing.expect(builtin_cold.wait_for_agent);
    try testing.expect(builtin_cold.start_builtin);
    try testing.expect(builtin_cold.probe_data);

    const prestarted_cold = serviceActions(false, true);
    try testing.expect(prestarted_cold.wait_for_agent);
    try testing.expect(!prestarted_cold.start_builtin);
    try testing.expect(prestarted_cold.probe_data);

    const restored = serviceActions(true, true);
    try testing.expect(!restored.wait_for_agent);
    try testing.expect(!restored.start_builtin);
    try testing.expect(!restored.probe_data);
}
