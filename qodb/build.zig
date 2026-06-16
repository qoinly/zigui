// qodb - standalone library at the zigui repo root (its own module, independent of
// zigui core). An app or zigui depends on it as a Zig module.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const qodb = b.addModule("qodb", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const qodb_tests = b.addTest(.{ .root_module = qodb });
    const run_qodb_tests = b.addRunArtifact(qodb_tests);

    const test_step = b.step("test", "Run qodb tests");
    test_step.dependOn(&run_qodb_tests.step);

    const bench_mod = b.createModule(.{
        .root_source_file = b.path("bench/bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    bench_mod.addImport("qodb", qodb);
    const bench_exe = b.addExecutable(.{ .name = "bench", .root_module = bench_mod });
    const run_bench = b.addRunArtifact(bench_exe);
    if (b.args) |args| run_bench.addArgs(args);
    const bench_step = b.step("bench", "Run benchmarks (use -Doptimize=ReleaseFast)");
    bench_step.dependOn(&run_bench.step);
}
