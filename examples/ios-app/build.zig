const std = @import("std");
const zigui = @import("zigui");

// The iOS example as a consumer build: it supplies only Zig (src/) plus an
// Info.plist (ios/) and calls zigui.iosApp, which cross-compiles for the iOS
// Simulator and assembles a .app. `zig build` writes the bundle to zig-out;
// `zig build run` installs and launches it on the booted simulator.
pub fn build(b: *std.Build) void {
    // The bundle is a release artifact; a Debug iOS build pulls std's MachO
    // stack-trace symbolizer, which needs a dyld symbol absent from the simulator
    // SDK. Default to ReleaseSmall so a plain `zig build` works; override with
    // -Doptimize if needed.
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "optimization mode (default ReleaseSmall)",
    ) orelse .ReleaseSmall;
    zigui.iosApp(b, .{
        .name = "ZiguiIosApp",
        .source = b.path("src/main.zig"),
        .info_plist = b.path("ios/Info.plist"),
        .bundle_id = "io.qoinly.zigui.iosapp",
        .optimize = optimize,
    });
}
