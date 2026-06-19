const std = @import("std");
const zigui = @import("zigui");

// The Android example as a zero-Java consumer: it supplies only Zig (src/) plus a
// manifest (android/) and calls zigui.androidApk, which ships the Java shell
// (io.qoinly.zigui.*), cross-compiles the .so for both device ABIs, and packages a
// signed, installable APK. `zig build` writes the APK to zig-out; `zig build run`
// installs and launches it.
//
// Required env: ANDROID_HOME (SDK root), JAVA_HOME (javac/apksigner need java).
// Optional: ANDROID_NDK_HOME, ANDROID_DEBUG_KEYSTORE.
pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    zigui.androidApk(b, .{
        .name = "zigui_android_app",
        .source = b.path("src/main.zig"),
        .manifest = b.path("android/AndroidManifest.xml"),
        .package_name = "io.qoinly.zigui.androidapp",
        .optimize = optimize,
        .out_name = "zigui-android-app.apk",
        .include_accessibility = true,
        .include_notification_listener = true,
        .include_broadcast_receiver = true,
        .include_biometric = true,
    });
}
