// zigui - library only. Consumers inherit the platform link list, so they do not
// have to repeat it. Examples (e.g. examples/showcase) are standalone builds.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zigui = b.addModule("zigui", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    link_platform(zigui, target);

    const zigui_tests = b.addTest(.{ .root_module = zigui });
    const run_zigui_tests = b.addRunArtifact(zigui_tests);

    const test_step = b.step("test", "Run zigui tests");
    test_step.dependOn(&run_zigui_tests.step);

    add_examples(b, zigui, target, optimize);
    add_icongen(b);
    add_shadergen(b);
}

// Recompiles the Linux GLSL to the committed SPIR-V (the icongen pattern: a
// manual step needing glslang on PATH; consumer builds embed the .spv files).
fn add_shadergen(b: *std.Build) void {
    const step = b.step("shadergen", "Recompile src/platform/linux/shaders/*.spv from GLSL");
    const dir = "src/platform/linux/shaders/";
    const stages = [_][]const u8{
        "quad.vert",       "quad.frag",
        "text.vert",       "text.frag",
        "frame.vert",      "frame_rgba.frag",
        "frame_nv12.frag",
    };
    for (stages) |stage| {
        const run = b.addSystemCommand(&.{ "glslang", "-V" });
        run.addFileArg(b.path(b.fmt("{s}{s}", .{ dir, stage })));
        run.addArg("-o");
        run.addArg(b.fmt("{s}{s}.spv", .{ dir, stage }));
        run.setCwd(b.path("."));
        run.has_side_effects = true; // rewrites committed source artifacts
        step.dependOn(&run.step);
    }
}

fn link_platform(zigui: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    switch (target.result.os.tag) {
        .macos => link_macos(zigui),
        .windows => link_windows(zigui),
        .linux => link_linux(zigui),
        else => @panic("zigui: unsupported target OS"),
    }
}

fn link_linux(zigui: *std.Build.Module) void {
    // libwayland-client.so.0 is dlopen'd at runtime (the d3dcompiler_47
    // precedent), so only libc - which carries dlopen - is linked here.
    zigui.link_libc = true;
}

fn link_macos(zigui: *std.Build.Module) void {
    zigui.linkFramework("Cocoa", .{});
    zigui.linkFramework("AppKit", .{});
    zigui.linkFramework("Foundation", .{});
    zigui.linkFramework("Metal", .{});
    zigui.linkFramework("MetalPerformanceShaders", .{});
    zigui.linkFramework("QuartzCore", .{});
    zigui.linkFramework("CoreVideo", .{});
    zigui.linkFramework("CoreText", .{});
    zigui.linkFramework("CoreGraphics", .{});
    zigui.link_libc = true;
}

fn link_windows(zigui: *std.Build.Module) void {
    // d3dcompiler_47.dll is loaded at runtime, so it is not linked here.
    zigui.linkSystemLibrary("user32", .{});
    zigui.linkSystemLibrary("gdi32", .{});
    zigui.linkSystemLibrary("d3d11", .{});
    zigui.linkSystemLibrary("dxgi", .{});
    zigui.linkSystemLibrary("dwrite", .{});
    zigui.linkSystemLibrary("dwmapi", .{});
    zigui.linkSystemLibrary("shcore", .{});
    zigui.linkSystemLibrary("ole32", .{});
}

fn add_examples(
    b: *std.Build,
    zigui: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    add_example(b, zigui, target, optimize, .{
        .name = "hello",
        .source = "examples/hello.zig",
        .description = "Build + run the hello example",
    });
    add_example(b, zigui, target, optimize, .{
        .name = "frame-demo",
        .source = "examples/frame_demo.zig",
        .description = "Build + run the external-frame demo",
    });
    add_example(b, zigui, target, optimize, .{
        .name = "input-demo",
        .source = "examples/input_demo.zig",
        .description = "Build + run the input-capture demo",
    });
    add_example(b, zigui, target, optimize, .{
        .name = "clipboard-demo",
        .source = "examples/clipboard_demo.zig",
        .description = "Build + run the clipboard demo",
    });
    add_example(b, zigui, target, optimize, .{
        .name = "display-demo",
        .source = "examples/display_demo.zig",
        .description = "Build + run the display/fullscreen demo",
    });
    add_example(b, zigui, target, optimize, .{
        .name = "multiwindow-demo",
        .source = "examples/multiwindow_demo.zig",
        .description = "Build + run the multi-window demo",
    });
}

const Example = struct {
    name: []const u8,
    source: []const u8,
    description: []const u8,
};

fn add_example(
    b: *std.Build,
    zigui: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    example: Example,
) void {
    const example_root = b.createModule(.{
        .root_source_file = b.path(example.source),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zigui", .module = zigui }},
    });
    const example_exe = b.addExecutable(.{
        .name = example.name,
        .root_module = example_root,
    });
    b.installArtifact(example_exe);
    const example_run = b.addRunArtifact(example_exe);
    const example_step = b.step(example.name, example.description);
    example_step.dependOn(&example_run.step);
}

fn add_icongen(b: *std.Build) void {
    const icongen_root = b.createModule(.{
        .root_source_file = b.path("tools/icongen.zig"),
        .target = b.graph.host, // a host tool: it runs at build time, never ships
        .optimize = .Debug,
    });
    const icongen_exe = b.addExecutable(.{ .name = "icongen", .root_module = icongen_root });
    const icongen_step = b.step(
        "icongen",
        "Regenerate src/icon_lucide_data.zig from Lucide SVGs",
    );
    const lucide_dir_option = b.option(
        []const u8,
        "lucide-dir",
        "Lucide SVG icons dir for `zig build icongen`",
    );
    if (lucide_dir_option) |lucide_dir| {
        const run = b.addRunArtifact(icongen_exe);
        run.setCwd(b.path(".")); // it writes the out path relative to the repo root
        run.has_side_effects = true; // rewrites a source file: never skip on cache hit
        run.addArgs(&.{ lucide_dir, "src/icon_lucide_data.zig" });
        icongen_step.dependOn(&run.step);
    } else {
        const fail = b.addFail("icongen needs -Dlucide-dir=<path to Lucide icons>");
        icongen_step.dependOn(&fail.step);
    }
}
