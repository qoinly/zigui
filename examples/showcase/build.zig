const std = @import("std");

// Built on zigui as an external path dependency to exercise the public module
// surface end to end. macOS only; framework links ride in on the zigui module.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zigui = b.dependency("zigui", .{
        .target = target,
        .optimize = optimize,
    }).module("zigui");

    const exe = b.addExecutable(.{
        .name = "showcase",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zigui", .module = zigui }},
        }),
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run the showcase app");
    run_step.dependOn(&run.step);
}
