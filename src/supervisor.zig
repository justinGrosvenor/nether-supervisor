//! Wires the RealLauncher to the pool state machine and runs the north control
//! loop. For the validation gate the bring-up is SYNCHRONOUS (one VM at a time,
//! inline on the accept loop): on `ensure <tenant>` the pool spawns a cold VM,
//! we drive it to serving, then answer. The async bring-up thread + poll reactor
//! (so the north loop never blocks) is the next increment; the pool state
//! machine underneath is already the real one.

const std = @import("std");
const c = std.c;
const config = @import("config.zig");
const os = @import("os.zig");
const proto = @import("proto.zig");
const pool_mod = @import("pool.zig");
const launcher_mod = @import("launcher.zig");
const boot = @import("boot.zig");
const control_client = @import("control_client.zig");
const control_server = @import("control_server.zig");
const log = @import("log.zig");

/// Tracks a spawned VM process so the launcher can kill it and bring-up can find
/// its sockets. Indexed alongside pool slots by vm_id.
const VmProc = struct {
    active: bool = false,
    vm_id: u32 = 0,
    pid: c.pid_t = 0,
};

pub const Supervisor = struct {
    cfg: config.Config,
    pool: pool_mod.Pool = undefined,
    real: boot.RealLauncher,
    vms: [pool_mod.CAP]VmProc = [1]VmProc{.{}} ** pool_mod.CAP,
    next_waiter: u64 = 1,
    listen_fd: std.posix.fd_t = -1,
    /// Backs the absolute base-snapshot path once baked (nether jails the
    /// snapshot into the base VM cwd, so the real fork source is derived, not
    /// the config value). cfg/pool base_snap slices point in here after bake.
    base_snap_buf: [512]u8 = undefined,

    /// Reserved vm id for the transient base VM (the pool issues ids from 1).
    const BASE_ID: u32 = 0;

    pub fn init(cfg: config.Config) Supervisor {
        return .{
            .cfg = cfg,
            .real = .{
                .nether_bin = cfg.nether_bin,
                .kernels_dir = cfg.kernels_dir,
                .work_root = cfg.work_root,
                .app_port = cfg.app_port,
                .cpus = cfg.cpus,
                .ram_mb = cfg.ram_mb,
                .idle_timeout_s = cfg.idle_timeout_s,
            },
        };
    }

    /// Two-step init: the pool's launcher captures &self, so wire it once the
    /// Supervisor has a stable address.
    pub fn wire(self: *Supervisor) void {
        self.pool = pool_mod.Pool.init(.{
            .socket_dir = self.cfg.socket_dir,
            .base_snap = self.cfg.base_snap,
            .app_port = self.cfg.app_port,
            .cpus = self.cfg.cpus,
            .ram_mb = self.cfg.ram_mb,
            .idle_timeout_s = self.cfg.idle_timeout_s,
            .idle_ttl_ms = self.cfg.idle_ttl_ms,
            .max_vms = self.cfg.max_vms,
        }, self.launcher());
    }

    fn launcher(self: *Supervisor) launcher_mod.Launcher {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable = launcher_mod.Launcher.VTable{ .spawn = spawnImpl, .kill = killImpl };

    fn spawnImpl(ctx: *anyopaque, spec: launcher_mod.LaunchSpec) launcher_mod.LaunchError!void {
        const self: *Supervisor = @ptrCast(@alignCast(ctx));
        // Warm-fork when the pool handed us a base snapshot to restore from
        // (run() bakes it before accepting); otherwise cold-boot.
        const pid = if (spec.restore_from.len > 0)
            self.real.spawnFork(spec.vm_id, spec.control_socket, spec.data_socket, spec.restore_from) catch return error.SpawnFailed
        else
            self.real.spawnCold(spec.vm_id, spec.control_socket, spec.data_socket) catch return error.SpawnFailed;
        for (&self.vms) |*v| {
            if (!v.active) {
                v.* = .{ .active = true, .vm_id = spec.vm_id, .pid = pid };
                return;
            }
        }
        // No tracking slot: reap the process we just spawned and fail.
        os.killPid(pid, os.SIGTERM);
        return error.PoolFull;
    }

    fn killImpl(ctx: *anyopaque, vm_id: u32) void {
        const self: *Supervisor = @ptrCast(@alignCast(ctx));
        for (&self.vms) |*v| {
            if (v.active and v.vm_id == vm_id) {
                os.killPid(v.pid, os.SIGTERM);
                v.active = false;
                return;
            }
        }
    }

    fn nowMs() u64 {
        const ts = os.monotonicMs();
        return ts;
    }

    /// Handle one `ensure <tenant>` synchronously: pool.ensure, then (on a MISS)
    /// drive the just-spawned VM to serving and resolve. Writes the framed reply
    /// into `out`.
    fn handleEnsure(self: *Supervisor, tenant: []const u8, out: []u8) []const u8 {
        const waiter = self.next_waiter;
        self.next_waiter += 1;
        const now = nowMs();
        const outcome = self.pool.ensure(tenant, waiter, now, now + self.cfg.boot_budget_ms);
        switch (outcome) {
            .hit => |path| {
                log.info("ensure {s}: HIT {s}", .{ tenant, path });
                return proto.buildReply(out, path, 0) catch out[0..0];
            },
            .rejected => |reason| {
                log.warn("ensure {s}: rejected ({s})", .{ tenant, reason });
                return proto.buildReply(out, reason, 1) catch out[0..0];
            },
            .parked => {},
        }

        // MISS: a VM was spawned. Drive it to serving synchronously.
        const info = self.pool.bootingInfo(tenant) orelse {
            return proto.buildReply(out, "no booting vm", 1) catch out[0..0];
        };
        const is_fork = self.cfg.base_snap.len > 0;
        log.info("ensure {s}: {s} vm={x} (control={s})", .{ tenant, if (is_fork) "fork" else "cold boot", info.vm_id, info.control_socket });

        var answers: [pool_mod.MAX_WAITERS]pool_mod.Answer = undefined;
        boot.bringUp(info.control_socket, info.data_socket, is_fork, self.cfg.boot_budget_ms, nowMs) catch |e| {
            log.err("ensure {s}: bring-up failed: {s}", .{ tenant, @errorName(e) });
            _ = self.pool.onFailed(info.vm_id, "bring-up failed", &answers);
            return proto.buildReply(out, "cold start failed", 1) catch out[0..0];
        };

        const n = self.pool.onReady(info.vm_id, info.data_socket, nowMs(), &answers);
        // Find this waiter's answer (there is exactly one for a fresh boot).
        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (answers[i].waiter_id == waiter) {
                switch (answers[i].result) {
                    .ok => |path| {
                        log.info("ensure {s}: SERVING {s}", .{ tenant, path });
                        return proto.buildReply(out, path, 0) catch out[0..0];
                    },
                    .fail => |reason| return proto.buildReply(out, reason, 1) catch out[0..0],
                }
            }
        }
        return proto.buildReply(out, "internal", 1) catch out[0..0];
    }

    /// One north connection: read lines, dispatch, reply, until EOF.
    fn serveConn(self: *Supervisor, conn: std.posix.fd_t) void {
        var rbuf: [8192]u8 = undefined;
        var rlen: usize = 0;
        var out: [512]u8 = undefined;
        while (true) {
            const n = os.readSome(conn, rbuf[rlen..]) catch return;
            if (n == 0) return; // EOF
            rlen += n;
            // Process complete lines.
            while (std.mem.indexOfScalar(u8, rbuf[0..rlen], '\n')) |nl| {
                const line = std.mem.trim(u8, rbuf[0..nl], " \t\r");
                // Shift the remainder to the front.
                const rest = rbuf[nl + 1 .. rlen];
                std.mem.copyForwards(u8, rbuf[0..rest.len], rest);
                rlen = rest.len;

                if (line.len == 0) continue;
                if (std.mem.eql(u8, line, "__info__")) {
                    const r = proto.buildReply(&out, control_server.INFO_REPORT, 0) catch continue;
                    os.writeAll(conn, r) catch return;
                } else if (std.mem.startsWith(u8, line, "ensure")) {
                    var it = std.mem.tokenizeScalar(u8, line, ' ');
                    _ = it.next();
                    const tenant = it.next() orelse {
                        const r = proto.buildReply(&out, "ensure requires a tenant", 1) catch continue;
                        os.writeAll(conn, r) catch return;
                        continue;
                    };
                    const r = self.handleEnsure(tenant, &out);
                    os.writeAll(conn, r) catch return;
                } else {
                    const r = proto.buildReply(&out, "supervisor: unknown command", 127) catch continue;
                    os.writeAll(conn, r) catch return;
                }
            }
            if (rlen == rbuf.len) rlen = 0; // overlong line: drop (defensive)
        }
    }

    /// Bake the warm-fork base once at startup: cold-boot a base VM, drive it to
    /// serving, `__snapshot__` it to cfg.base_snap, then shut it down. Per-tenant
    /// ensures then fork from that snapshot (~76ms) instead of full cold boots.
    /// The base is NOT tracked in self.vms (it is transient and reaped here).
    fn bakeBase(self: *Supervisor) !void {
        var cbuf: [os.SUN_PATH_MAX + 32]u8 = undefined;
        var dbuf: [os.SUN_PATH_MAX + 32]u8 = undefined;
        const p = try @import("vm.zig").socketPaths(self.cfg.socket_dir, "base", &cbuf, &dbuf);

        log.info("baking warm-fork base (id={x:0>8})", .{BASE_ID});
        const pid = try self.real.spawnCold(BASE_ID, p.control, p.data);
        errdefer os.killPid(pid, os.SIGTERM);

        // Drive the base to a serving state (starts the guest server via SRV).
        try boot.bringUp(p.control, p.data, false, self.cfg.boot_budget_ms, nowMs);

        // Snapshot the running server + data plane, then shut the base down. The
        // snapshot blocks until the file is on disk, so a successful reply means
        // forks can restore from it. nether jails the snapshot path to the VM's
        // cwd, so pass a bare filename; the real fork source is <base_cwd>/base.snap.
        var client = control_client.Client.connect(p.control) catch return error.BaseSnapshotFailed;
        defer client.close();
        _ = client.handshake(.{ .hang_ms = 2000 }) catch {};
        const ok = client.snapshot("base.snap", .{ .hang_ms = 30000 }) catch return error.BaseSnapshotFailed;
        if (!ok) return error.BaseSnapshotFailed;
        client.shutdown(.{ .hang_ms = 3000 });
        _ = os.waitpidNoHang(pid); // best-effort reap; the base exits on shutdown

        // Point forks at the jailed snapshot's absolute path (config base_snap was
        // only the enable toggle). Both cfg copies drive fork-vs-cold decisions.
        const abs = std.fmt.bufPrint(&self.base_snap_buf, "{s}/{x:0>8}/base.snap", .{ self.cfg.work_root, BASE_ID }) catch return error.PathTooLong;
        self.cfg.base_snap = abs;
        self.pool.cfg.base_snap = abs;
        log.info("warm-fork base ready ({s})", .{abs});
    }

    /// Run the gate: bind the north control socket and serve connections. Blocks.
    pub fn run(self: *Supervisor) !void {
        // Warm-fork mode: bake the base before accepting so the first ensure can
        // already fork. If the bake fails, fall back to cold-boot (clear the base
        // in both config copies so ensure hands out restore_from="").
        if (self.cfg.base_snap.len > 0) {
            self.bakeBase() catch |e| {
                log.err("base bake failed ({s}); falling back to cold-boot", .{@errorName(e)});
                self.cfg.base_snap = "";
                self.pool.cfg.base_snap = "";
            };
        }

        self.listen_fd = try os.listenUnix(self.cfg.control_socket);
        log.info("north control socket listening at {s}", .{self.cfg.control_socket});
        while (true) {
            const conn = os.acceptConn(self.listen_fd) catch continue;
            self.serveConn(conn);
            os.closeFd(conn);
        }
    }
};
