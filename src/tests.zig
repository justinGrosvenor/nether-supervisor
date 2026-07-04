//! Test aggregator: pull in every module so `zig build test` runs the whole
//! tree's tests. Add new modules here as they land.

comptime {
    _ = @import("config.zig");
    _ = @import("lock.zig");
    _ = @import("log.zig");
    _ = @import("os.zig");
    _ = @import("proto.zig");
    _ = @import("control_reader.zig");
    _ = @import("control_client.zig");
    _ = @import("control_server.zig");
    _ = @import("vm.zig");
    _ = @import("launcher.zig");
    _ = @import("pool.zig");
    _ = @import("readiness.zig");
    _ = @import("boot.zig");
    _ = @import("status.zig");
    _ = @import("supervisor.zig");
}
