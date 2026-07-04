//! RealLauncher: fork/exec a real `nether` process in a per-VM working directory
//! and drive it to a serving state. This is the production south side (the
//! MockLauncher is its unit-test stand-in). The bring-up sequence is the recipe
//! proven by nether's scripts/fork_serve.py:
//!   boot -> __info__ (proto_version=1) -> `echo ready` until the agent answers
//!   -> drive SRV (start the in-guest HTTP server on app_port) -> probe the
//!   data_socket over HTTP until it serves.
//! A fork (restore) inherits the running server, so SRV is skipped for forks.

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

    pub const Error = error{ MkdirFailed, WriteFailed, ForkFailed, PathTooLong };

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

    /// Shared spawn: build the per-VM cwd + nether.conf and fork/exec nether.
    /// `restore_from` empty => cold boot; non-empty => fork from that snapshot.
    fn spawn(self: *const RealLauncher, id: u32, control_socket: []const u8, data_socket: []const u8, restore_from: []const u8) Error!std.c.pid_t {
        const is_fork = restore_from.len > 0;
        var cwd_buf: [512]u8 = undefined;
        const cwd = std.fmt.bufPrintZ(&cwd_buf, "{s}/{x:0>8}", .{ self.work_root, id }) catch return error.PathTooLong;

        // work_root + the per-VM cwd.
        var root_z_buf: [512]u8 = undefined;
        const root_z = std.fmt.bufPrintZ(&root_z_buf, "{s}", .{self.work_root}) catch return error.PathTooLong;
        os.mkdirZ(root_z);
        os.mkdirZ(cwd);

        // Symlink kernels/ into the cwd (nether reads kernels/ from cwd on a cold
        // boot). A fork restores from the snapshot and never reads kernels, so
        // skip the symlink there.
        if (!is_fork) {
            var link_buf: [600]u8 = undefined;
            const link_z = std.fmt.bufPrintZ(&link_buf, "{s}/kernels", .{cwd}) catch return error.PathTooLong;
            var target_buf: [512]u8 = undefined;
            const target_z = std.fmt.bufPrintZ(&target_buf, "{s}", .{self.kernels_dir}) catch return error.PathTooLong;
            os.symlinkForceZ(target_z, link_z);
        }

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

pub const BringUpError = error{ Connect, Handshake, AgentTimeout, ServerStart, NotServing };

/// Drive a booted VM to a serving state. `is_fork` skips the SRV server-start
/// (a fork inherits the running server). Blocks up to `budget_ms`. On success
/// the data_socket serves HTTP.
pub fn bringUp(control_socket: []const u8, data_socket: []const u8, is_fork: bool, budget_ms: u64, now_fn: *const fn () u64) BringUpError!void {
    const deadline = now_fn() + budget_ms;

    // 1. Connect the control socket (it may not exist yet; retry).
    var client: control_client.Client = while (now_fn() < deadline) {
        if (control_client.Client.connect(control_socket)) |c| break c else |_| {
            sleepMs(20);
        }
    } else return error.Connect;
    defer client.close();

    // 2. Handshake: __info__ + proto_version=1.
    _ = client.handshake(.{ .hang_ms = 2000 }) catch return error.Handshake;

    if (!is_fork) {
        // 3. Wait for the guest agent (echo round-trips), then start the server.
        while (now_fn() < deadline) {
            const r = client.drive("echo ready", .{ .settle_ms = 200, .hang_ms = 1500 }) catch {
                sleepMs(50);
                continue;
            };
            if (r.framed and std.mem.indexOf(u8, r.body, "ready") != null) break;
            sleepMs(50);
        } else return error.AgentTimeout;

        // 4. Start the in-guest HTTP server on app_port.
        const s = client.drive(SRV, .{ .hang_ms = 3000 }) catch return error.ServerStart;
        if (!s.framed) return error.ServerStart;
    }

    // 5. Probe the data_socket over HTTP until it serves (connect is not enough).
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
