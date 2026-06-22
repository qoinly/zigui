// `zigui doctor` - checks the toolchains a scaffolded app needs: the Android SDK/NDK/JDK to
// package an APK, and Xcode's command-line tools to build for the iOS Simulator. Reports each
// piece [ok] / [x] (required) / [--] (optional or not configured), and exits non-zero when a
// configured toolchain is missing a required tool.

const std = @import("std");
const builtin = @import("builtin");
const cli = @import("main.zig");

// Mirror androidApk's defaults (build.zig) - the exact versions the APK build pins to.
const ndk_version = "29.0.14206865";
const build_tools = "36.0.0";
const api = 36;

pub fn run(ctx: cli.Ctx, args: *std.process.Args.Iterator) !void {
    _ = args;
    try ctx.out.print("zigui doctor\n", .{});
    var broken: u32 = 0;
    broken += try android_section(ctx);
    broken += try ios_section(ctx);

    try ctx.out.print("\n", .{});
    if (broken == 0) {
        try ctx.out.print(
            "ready - a scaffolded app can build for its configured target(s).\n",
            .{},
        );
        return;
    }
    try ctx.out.print(
        "{d} required tool(s) missing in a configured toolchain (see [x]).\n",
        .{broken},
    );
    return cli.Error.Reported;
}

// The Android APK toolchain. Returns the count of missing required tools; an unconfigured
// toolchain (no ANDROID_HOME/JAVA_HOME) is reported but not counted as broken.
fn android_section(ctx: cli.Ctx) !u32 {
    try ctx.out.print("\nAndroid (APK build):\n", .{});
    const sdk = ctx.env.get("ANDROID_HOME");
    const jdk = ctx.env.get("JAVA_HOME");
    if (sdk == null or jdk == null) {
        try ctx.out.print(
            "  [--] not configured - set ANDROID_HOME + JAVA_HOME to build APKs\n",
            .{},
        );
        return 0;
    }
    try report_env(ctx, "ANDROID_HOME", sdk);
    try report_env(ctx, "JAVA_HOME", jdk);
    const home = sdk.?;
    const java = jdk.?;
    const ndk = ctx.env.get("ANDROID_NDK_HOME") orelse
        try join(ctx, home, try std.fmt.allocPrint(ctx.gpa, "ndk/{s}", .{ndk_version}));
    const bt = try std.fmt.allocPrint(ctx.gpa, "{s}/build-tools/{s}", .{ home, build_tools });
    const keystore = ctx.env.get("ANDROID_DEBUG_KEYSTORE") orelse
        try join(ctx, home, "debug.keystore");

    var missing: u32 = 0;
    try require(ctx, &missing, "javac", try join(ctx, java, "bin/javac"));
    try require(ctx, &missing, "ndk", ndk);
    try require(ctx, &missing, "aapt2", try join(ctx, bt, "aapt2"));
    try require(ctx, &missing, "zipalign", try join(ctx, bt, "zipalign"));
    try require(ctx, &missing, "apksigner", try join(ctx, bt, "apksigner"));
    try require(ctx, &missing, "d8", try join(ctx, bt, "d8"));
    const jar = try std.fmt.allocPrint(ctx.gpa, "{s}/platforms/android-{d}/android.jar", .{
        home,
        api,
    });
    try require(ctx, &missing, "platform jar", jar);
    // Optional - handy but the APK build itself does not need them.
    try optional(ctx, "adb", try join(ctx, home, "platform-tools/adb"));
    try optional(ctx, "emulator", try join(ctx, home, "emulator/emulator"));
    try optional(ctx, "debug keystore", keystore);
    return missing;
}

// The iOS Simulator toolchain. iOS builds need macOS + Xcode's command-line tools (xcrun);
// the per-run simulator is booted separately. Returns the count of missing required tools.
fn ios_section(ctx: cli.Ctx) !u32 {
    try ctx.out.print("\niOS (Simulator build):\n", .{});
    if (builtin.os.tag != .macos) {
        try ctx.out.print("  [--] not available - iOS builds need macOS\n", .{});
        return 0;
    }
    var missing: u32 = 0;
    try require(ctx, &missing, "xcrun", "/usr/bin/xcrun");
    try ctx.out.print(
        "  boot a simulator (`xcrun simctl boot <udid>`) before `zig build run -- ios`.\n",
        .{},
    );
    return missing;
}

fn report_env(ctx: cli.Ctx, name: []const u8, val: ?[]const u8) !void {
    std.debug.assert(name.len > 0);
    if (val) |v| {
        try ctx.out.print("  [ok] {s} = {s}\n", .{ name, v });
    } else {
        try ctx.out.print("  [x]  {s} (not set)\n", .{name});
    }
}

fn require(ctx: cli.Ctx, missing: *u32, label: []const u8, path: []const u8) !void {
    std.debug.assert(label.len > 0);
    std.debug.assert(path.len > 0);
    const ok = exists(ctx, path);
    if (!ok) missing.* += 1;
    try ctx.out.print("  {s} {s}  {s}\n", .{ if (ok) "[ok]" else "[x] ", label, path });
}

fn optional(ctx: cli.Ctx, label: []const u8, path: []const u8) !void {
    std.debug.assert(label.len > 0);
    std.debug.assert(path.len > 0);
    const mark = if (exists(ctx, path)) "[ok]" else "[--]";
    try ctx.out.print("  {s} {s}  {s}\n", .{ mark, label, path });
}

fn exists(ctx: cli.Ctx, path: []const u8) bool {
    std.debug.assert(path.len > 0);
    std.Io.Dir.cwd().access(ctx.io, path, .{}) catch return false;
    return true;
}

fn join(ctx: cli.Ctx, dir: []const u8, sub: []const u8) ![]const u8 {
    std.debug.assert(dir.len > 0);
    return std.fmt.allocPrint(ctx.gpa, "{s}/{s}", .{ dir, sub });
}
