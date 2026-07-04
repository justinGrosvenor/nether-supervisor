const std = @import("std");

pub fn build(b: *std.Build) void {
    // The supervisor is a native daemon: it spawns nether processes, drives
    // Unix control sockets, and runs a small reactor. It targets the host
    // (macOS for the real HVF path; Linux for the CI-able unit tests). Default
    // to native so `zig build` / `zig build test` run on the host.
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "nether-supervisor",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the nether-supervisor daemon");
    run_step.dependOn(&run_cmd.step);

    // Tests aggregate every module through src/tests.zig so `zig build test`
    // covers the whole tree.
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
