//! Test aggregator: pull in every module so `zig build test` runs the whole
//! tree's tests. Add new modules here as they land.

comptime {
    _ = @import("config.zig");
    _ = @import("log.zig");
}
