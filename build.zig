const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The library module: protocol, data structures, keyspace and server.
    const zedis = b.addModule("zedis", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const server = b.addExecutable(.{
        .name = "zedis-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zedis", .module = zedis }},
        }),
    });
    b.installArtifact(server);

    const cli = b.addExecutable(.{
        .name = "zedis-cli",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zedis", .module = zedis }},
        }),
    });
    b.installArtifact(cli);

    const run_server = b.addRunArtifact(server);
    run_server.step.dependOn(b.getInstallStep());
    run_server.addPassthruArgs();
    b.step("run", "Run zedis-server").dependOn(&run_server.step);

    const compat = b.addExecutable(.{
        .name = "zedis-compat",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/compat/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zedis", .module = zedis }},
        }),
    });
    b.installArtifact(compat);
    const run_compat = b.addRunArtifact(compat);
    run_compat.addPassthruArgs();
    b.step("compat", "Run the compatibility suite against an embedded server").dependOn(&run_compat.step);

    const bench = b.addExecutable(.{
        .name = "zedis-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zedis", .module = zedis }},
        }),
    });
    b.installArtifact(bench);
    const run_bench = b.addRunArtifact(bench);
    run_bench.addPassthruArgs();
    b.step("bench", "Run zedis-bench (pass options after --)").dependOn(&run_bench.step);

    const unit_tests = b.addTest(.{ .root_module = zedis });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
