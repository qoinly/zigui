// `zigui doctor` - checks the Android toolchain a scaffolded app needs to package an
// APK. Reports each piece [ok] / [x] (required) / [--] (optional, missing), and exits
// non-zero when a required tool is absent.

const std = @import("std");
const cli = @import("main.zig");

// Mirror androidApk's defaults (build.zig) - the exact versions the APK build pins to.
const ndk_version = "29.0.14206865";
const build_tools = "36.0.0";
const api = 36;

pub fn run(ctx: cli.Ctx, args: *std.process.Args.Iterator) !void {
    _ = args;
    try ctx.out.print("zigui doctor - Android toolchain\n\n", .{});

    const sdk = ctx.env.get("ANDROID_HOME");
    const jdk = ctx.env.get("JAVA_HOME");
    try report_env(ctx, "ANDROID_HOME", sdk);
    try report_env(ctx, "JAVA_HOME", jdk);
    if (sdk == null or jdk == null) {
        try ctx.out.print(
            "\nset ANDROID_HOME (SDK root) and JAVA_HOME (a JDK), then re-run.\n",
            .{},
        );
        return cli.Error.Reported;
    }
    const home = sdk.?;
    const java = jdk.?;
    const ndk = ctx.env.get("ANDROID_NDK_HOME") orelse
        try join(ctx, home, try std.fmt.allocPrint(ctx.gpa, "ndk/{s}", .{ndk_version}));
    const bt = try std.fmt.allocPrint(ctx.gpa, "{s}/build-tools/{s}", .{
        home,
        build_tools,
    });
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

    try ctx.out.print("\n", .{});
    if (missing == 0) {
        try ctx.out.print("all set - `zig build` in a scaffolded app will package an APK.\n", .{});
        return;
    }
    try ctx.out.print("{d} required tool(s) missing (see [x] above).\n", .{missing});
    return cli.Error.Reported;
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
