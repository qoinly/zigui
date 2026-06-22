const std = @import("std");
const zigui = @import("zigui");

// The iOS example as a consumer build: it supplies only Zig (src/) plus an Info.plist (ios/)
// and calls zigui.app. `zig build ios` cross-compiles for the iOS Simulator and assembles the
// .app; `zig build run -- ios [udid]` installs and launches it (default: the booted sim).
pub fn build(b: *std.Build) void {
    zigui.app(b, .{
        .source = b.path("src/main.zig"),
        .ios = .{
            .name = "ZiguiIosApp",
            .info_plist = b.path("ios/Info.plist"),
            .bundle_id = "io.qoinly.zigui.iosapp",
        },
    });
}
