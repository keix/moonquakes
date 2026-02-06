const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "moonquakes",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const clean_step = b.step("clean", "Clean build artifacts");
    const rm_zig_out = b.addRemoveDirTree(b.path("zig-out"));
    const rm_zig_cache = b.addRemoveDirTree(b.path(".zig-cache"));
    clean_step.dependOn(&rm_zig_out.step);
    clean_step.dependOn(&rm_zig_cache.step);

    const test_step = b.step("test", "Run unit tests");

    // Unit tests for moonquakes
    const moonquakes_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_moonquakes_tests = b.addRunArtifact(moonquakes_tests);
    test_step.dependOn(&run_moonquakes_tests.step);

    // Integration test executables
    const integration_step = b.step("integration", "Run integration tests");
    const test_names = [_][]const u8{
        "basic",
        "arithmetic",
    };

    for (test_names) |test_name| {
        const test_exe = b.addExecutable(.{
            .name = test_name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("tests/{s}.zig", .{test_name})),
                .target = target,
                .optimize = optimize,
            }),
        });

        const run_test = b.addRunArtifact(test_exe);

        // Individual test steps
        const individual_test_step = b.step(b.fmt("test-{s}", .{test_name}), b.fmt("Run {s} tests", .{test_name}));
        individual_test_step.dependOn(&run_test.step);

        // Add to integration step
        integration_step.dependOn(&run_test.step);
    }
}
