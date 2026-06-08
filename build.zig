// zigui - library only. Exposes a single "zigui" module + tests. Consumers get
// the platform frameworks via the module link list, so they do not have to
// repeat the linkage themselves. Examples (e.g. examples/showcase) are their
// own standalone builds.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("zigui", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Platform link list; consumers inherit these through the module.
    switch (target.result.os.tag) {
        .macos => {
            mod.linkFramework("Cocoa", .{});
            mod.linkFramework("AppKit", .{});
            mod.linkFramework("Foundation", .{});
            mod.linkFramework("Metal", .{});
            mod.linkFramework("MetalPerformanceShaders", .{});
            mod.linkFramework("QuartzCore", .{});
            mod.linkFramework("CoreVideo", .{});
            mod.linkFramework("CoreText", .{});
            mod.linkFramework("CoreGraphics", .{});
            mod.link_libc = true;
        },
        .windows => {
            // d3dcompiler_47.dll is loaded at runtime, so it is not linked here.
            mod.linkSystemLibrary("user32", .{});
            mod.linkSystemLibrary("gdi32", .{});
            mod.linkSystemLibrary("d3d11", .{});
            mod.linkSystemLibrary("dxgi", .{});
            mod.linkSystemLibrary("dwrite", .{});
            mod.linkSystemLibrary("dwmapi", .{});
            mod.linkSystemLibrary("ole32", .{});
        },
        else => @panic("zigui: unsupported target OS"),
    }

    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run zigui tests");
    test_step.dependOn(&run_mod_tests.step);

    // Example: hello - wired into the root build (not standalone like the
    // showcase). It is the minimal smoke test for the public API: compiled on
    // every `zig build`; `zig build hello` runs it.
    const hello_mod = b.createModule(.{
        .root_source_file = b.path("examples/hello.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zigui", .module = mod }},
    });
    const hello_exe = b.addExecutable(.{ .name = "hello", .root_module = hello_mod });
    b.installArtifact(hello_exe);
    const hello_run = b.addRunArtifact(hello_exe);
    const hello_step = b.step("hello", "Build + run the hello example");
    hello_step.dependOn(&hello_run.step);

    // Example: frame-demo - smoke test for the external-frame primitive.
    const frame_demo_mod = b.createModule(.{
        .root_source_file = b.path("examples/frame_demo.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zigui", .module = mod }},
    });
    const frame_demo_exe = b.addExecutable(.{
        .name = "frame-demo",
        .root_module = frame_demo_mod,
    });
    b.installArtifact(frame_demo_exe);
    const frame_demo_run = b.addRunArtifact(frame_demo_exe);
    const frame_demo_step = b.step("frame-demo", "Build + run the external-frame demo");
    frame_demo_step.dependOn(&frame_demo_run.step);

    // Offline codegen: regenerate src/icon_lucide_data.zig from the Lucide SVG
    // set. The SVG dir lives outside the repo, so it must be passed:
    //   zig build icongen -Dlucide-dir=/path/to/lucide/icons
    const icongen_mod = b.createModule(.{
        .root_source_file = b.path("tools/icongen.zig"),
        .target = b.graph.host, // a host tool: it runs at build time, never ships
        .optimize = .Debug,
    });
    const icongen_exe = b.addExecutable(.{ .name = "icongen", .root_module = icongen_mod });
    const icongen_step = b.step("icongen", "Regenerate src/icon_lucide_data.zig from Lucide SVGs (-Dlucide-dir=<path>)");
    if (b.option([]const u8, "lucide-dir", "Lucide SVG icons dir for `zig build icongen`")) |lucide_dir| {
        const run = b.addRunArtifact(icongen_exe);
        run.setCwd(b.path(".")); // it writes the out path relative to the repo root
        run.has_side_effects = true; // rewrites a source file: never skip on cache hit
        run.addArgs(&.{ lucide_dir, "src/icon_lucide_data.zig" });
        icongen_step.dependOn(&run.step);
    } else {
        icongen_step.dependOn(&b.addFail("icongen needs -Dlucide-dir=<path to the Lucide icons dir>").step);
    }
}
