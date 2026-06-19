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

    link_platform(b, zigui, target);

    // Android capability opt-in: each flag gates whether its JNI bridge (and so the
    // napi code that bridge pulls in) compiles into the .so. Off by default; androidApk
    // turns on what the app declares, so a minimal app carries none of them.
    const android_caps = b.addOptions();
    android_cap(b, android_caps, "accessibility", "android_accessibility");
    android_cap(b, android_caps, "notification_listener", "android_notification_listener");
    android_cap(b, android_caps, "broadcast", "android_broadcast");
    android_cap(b, android_caps, "biometric", "android_biometric");
    zigui.addOptions("android_caps", android_caps);

    const zigui_tests = b.addTest(.{ .root_module = zigui });
    const run_zigui_tests = b.addRunArtifact(zigui_tests);

    const test_step = b.step("test", "Run zigui tests");
    test_step.dependOn(&run_zigui_tests.step);

    add_examples(b, zigui, target, optimize);
    add_icongen(b);
    add_shadergen(b);
    add_cli(b);
}

// The zigui CLI (`zig-out/bin/zigui`): scaffolds apps and checks the toolchain.
// `zig build cli` installs it; `zig build cli-run -- <args>` runs it in place.
fn add_cli(b: *std.Build) void {
    const cli_root = b.createModule(.{
        .root_source_file = b.path("tools/cli/main.zig"),
        .target = b.graph.host, // a host tool: it runs on the developer's machine
        .optimize = .ReleaseSafe,
    });
    const cli_exe = b.addExecutable(.{ .name = "zigui", .root_module = cli_root });
    const cli_step = b.step("cli", "Build the zigui CLI -> zig-out/bin/zigui");
    cli_step.dependOn(&b.addInstallArtifact(cli_exe, .{}).step);

    const run = b.addRunArtifact(cli_exe);
    if (b.args) |args| run.addArgs(args);
    const run_step = b.step("cli-run", "Run the zigui CLI: zig build cli-run -- <args>");
    run_step.dependOn(&run.step);
}

// Recompiles the Linux GLSL to the committed SPIR-V (the icongen pattern: a
// manual step needing glslang on PATH; consumer builds embed the .spv files).
fn add_shadergen(b: *std.Build) void {
    const step = b.step("shadergen", "Recompile src/platform/linux/shaders/*.spv from GLSL");
    const dir = "src/platform/linux/shaders/";
    const stages = [_][]const u8{
        "quad.vert",         "quad.frag",
        "text.vert",         "text.frag",
        "frame.vert",        "frame_rgba.frag",
        "frame_nv12.frag",   "frame_ycbcr.frag",
        "color_sprite.vert", "color_sprite.frag",
        "polyline.vert",     "polyline.frag",
        "line.vert",         "line.frag",
        "ring.vert",         "ring.frag",
        "blit.vert",         "blit.frag",
        "blur_h.frag",       "blur_v.frag",
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

fn link_platform(b: *std.Build, zigui: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    switch (target.result.os.tag) {
        .macos => link_macos(zigui),
        .ios => link_ios(b, zigui),
        .windows => link_windows(zigui),
        .linux => link_linux(zigui),
        else => @panic("zigui: unsupported target OS"),
    }
}

fn link_ios(b: *std.Build, zigui: *std.Build.Module) void {
    zigui.linkFramework("UIKit", .{});
    zigui.linkFramework("Foundation", .{});
    zigui.linkFramework("Metal", .{});
    zigui.linkFramework("QuartzCore", .{});
    zigui.linkFramework("CoreText", .{});
    zigui.linkFramework("CoreGraphics", .{});
    zigui.link_libc = true;
    ios_sim_paths(b, zigui);
}

// Cross-compiling to iOS, Zig does not auto-detect the SDK the way it does for the
// native target, so point framework/lib/include search at the simulator SDK.
fn ios_sim_paths(b: *std.Build, mod: *std.Build.Module) void {
    const sdk = ios_sim_sdk(b);
    mod.addSystemFrameworkPath(.{ .cwd_relative = b.fmt("{s}/System/Library/Frameworks", .{sdk}) });
    mod.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/usr/lib", .{sdk}) });
    mod.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/usr/include", .{sdk}) });
}

fn ios_sim_sdk(b: *std.Build) []const u8 {
    const out = b.run(&.{ "xcrun", "--sdk", "iphonesimulator", "--show-sdk-path" });
    return std.mem.trimEnd(u8, out, " \r\n");
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
    zigui.linkFramework("IOKit", .{}); // IOPMAssertion (keep-awake)
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
    add_example(b, zigui, target, optimize, .{
        .name = "nav-demo",
        .source = "examples/nav_demo.zig",
        .description = "Build + run the navigator (route stack + app-bar) demo",
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

// ---- Android packaging helper (consumer build-time API) ----
// A consumer's build.zig reaches this via `@import("zigui")` and calls androidApk
// once: it cross-compiles the native .so for both device ABIs, dexes zigui's shipped
// Java shell (the activity, plus the accessibility service when asked), and packages
// a signed, installable APK - so the app writes zero Java. SDK/NDK/JDK paths come
// from the environment; the app supplies a manifest that points its launch activity
// at io.qoinly.zigui.ZiguiActivity and sets android.app.lib_name to `name`.
pub const AndroidApkOptions = struct {
    // The output library + APK base name; the manifest's android.app.lib_name.
    name: []const u8,
    // The app's root Zig source (imports the "zigui" module).
    source: std.Build.LazyPath,
    // The app's AndroidManifest.xml.
    manifest: std.Build.LazyPath,
    // The app's package / applicationId, for `zig build run`'s am start.
    package_name: []const u8,
    optimize: std.builtin.OptimizeMode,
    // The launch activity component (fully qualified); defaults to the shipped shell.
    activity: []const u8 = "io.qoinly.zigui.ZiguiActivity",
    // The installed APK file name under zig-out/bin.
    out_name: []const u8 = "app.apk",
    // SDK knobs (match the example defaults).
    ndk_version: []const u8 = "29.0.14206865",
    build_tools: []const u8 = "36.0.0",
    api: u32 = 36,
    min_api: u32 = 26,
    // Dex zigui's accessibility service + compile its default config resource.
    include_accessibility: bool = false,
    // Dex zigui's notification-listener service.
    include_notification_listener: bool = false,
    // Dex zigui's static broadcast receiver (for headless / cold-start broadcasts the
    // app declares in its manifest, e.g. SMS_RECEIVED).
    include_broadcast_receiver: bool = false,
    // Compile the biometric bridge (native callback). The authenticate call lives on
    // the activity; this gates only the native result-callback code.
    include_biometric: bool = false,
};

pub fn androidApk(b: *std.Build, opts: AndroidApkOptions) void {
    const sdk = android_env(b, "ANDROID_HOME") orelse {
        std.debug.print("zigui.androidApk: set ANDROID_HOME to the Android SDK root\n", .{});
        return;
    };
    const java_home = android_env(b, "JAVA_HOME") orelse {
        std.debug.print("zigui.androidApk: set JAVA_HOME (javac/apksigner need java)\n", .{});
        return;
    };
    const ndk = android_env(b, "ANDROID_NDK_HOME") orelse
        b.fmt("{s}/ndk/{s}", .{ sdk, opts.ndk_version });
    const sysroot = b.fmt("{s}/toolchains/llvm/prebuilt/linux-x86_64/sysroot", .{ndk});
    const build_tools = b.fmt("{s}/build-tools/{s}", .{ sdk, opts.build_tools });
    const android_jar = b.fmt("{s}/platforms/android-{d}/android.jar", .{ sdk, opts.api });
    const keystore = android_env(b, "ANDROID_DEBUG_KEYSTORE") orelse
        b.fmt("{s}/debug.keystore", .{sdk});
    const aapt2 = b.fmt("{s}/aapt2", .{build_tools});
    const zipalign = b.fmt("{s}/zipalign", .{build_tools});
    const apksigner = b.fmt("{s}/apksigner", .{build_tools});
    const d8 = b.fmt("{s}/d8", .{build_tools});
    const adb = b.fmt("{s}/platform-tools/adb", .{sdk});
    const javac = b.fmt("{s}/bin/javac", .{java_home});

    // One .so per device ABI, assembled into the lib/<abi>/lib<name>.so tree.
    const lib_x86 = android_lib(b, opts, sysroot, "x86_64-linux-android", .x86_64);
    const lib_arm = android_lib(b, opts, sysroot, "aarch64-linux-android", .aarch64);
    const tree = b.addWriteFiles();
    _ = tree.addCopyFile(lib_x86.getEmittedBin(), b.fmt("lib/x86_64/lib{s}.so", .{opts.name}));
    _ = tree.addCopyFile(lib_arm.getEmittedBin(), b.fmt("lib/arm64-v8a/lib{s}.so", .{opts.name}));

    // zigui's shipped Java, staged so javac compiles whatever is present: the activity
    // always; an optional service only when the app opts in. The activity no longer
    // references the services, so a minimal app dexes neither.
    const zigui_files = b.dependency("zigui", .{
        .target = b.graph.host,
        .optimize = opts.optimize,
    });
    const java_dir = "src/platform/android/java/io/qoinly/zigui";
    const java_tree = b.addWriteFiles();
    _ = java_tree.addCopyFile(
        zigui_files.path(b.fmt("{s}/ZiguiActivity.java", .{java_dir})),
        "io/qoinly/zigui/ZiguiActivity.java",
    );
    // The broadcast payload decode, shared by the activity's runtime receiver and the
    // static ZiguiBroadcastReceiver; the activity always references it.
    _ = java_tree.addCopyFile(
        zigui_files.path(b.fmt("{s}/ZiguiBroadcast.java", .{java_dir})),
        "io/qoinly/zigui/ZiguiBroadcast.java",
    );
    if (opts.include_accessibility) {
        _ = java_tree.addCopyFile(
            zigui_files.path(b.fmt("{s}/ZiguiAccessibilityService.java", .{java_dir})),
            "io/qoinly/zigui/ZiguiAccessibilityService.java",
        );
    }
    if (opts.include_notification_listener) {
        _ = java_tree.addCopyFile(
            zigui_files.path(b.fmt("{s}/ZiguiNotificationListenerService.java", .{java_dir})),
            "io/qoinly/zigui/ZiguiNotificationListenerService.java",
        );
    }
    if (opts.include_broadcast_receiver) {
        _ = java_tree.addCopyFile(
            zigui_files.path(b.fmt("{s}/ZiguiBroadcastReceiver.java", .{java_dir})),
            "io/qoinly/zigui/ZiguiBroadcastReceiver.java",
        );
    }

    // javac every staged source -> d8 -> classes.dex at the APK root.
    const dex_script =
        "set -e; OUT=\"$(dirname \"$4\")\"; CL=\"$OUT/cls\"; rm -rf \"$CL\"; mkdir -p \"$CL\"; " ++
        "\"$1\" -cp \"$2\" -d \"$CL\" $(find \"$5\" -name '*.java'); " ++
        "\"$3\" --lib \"$2\" --min-api 26 --output \"$OUT\" $(find \"$CL\" -name '*.class')";
    const dex = b.addSystemCommand(&.{ "sh", "-c", dex_script, "dex" });
    dex.addArg(javac); // $1
    dex.addArg(android_jar); // $2
    dex.addArg(d8); // $3
    const classes_dex = dex.addOutputFileArg("classes.dex"); // $4
    dex.addDirectoryArg(java_tree.getDirectory()); // $5
    dex.setEnvironmentVariable("JAVA_HOME", java_home);

    // aapt2 links the manifest (+ the accessibility config resource when on) into the
    // base APK (binary XML + resources.arsc, no libs yet).
    const link = b.addSystemCommand(&.{ aapt2, "link", "-I", android_jar, "--manifest" });
    link.addFileArg(opts.manifest);
    link.addArg("-o");
    const base_apk = link.addOutputFileArg("base.apk");
    if (opts.include_accessibility) {
        const compile_res = b.addSystemCommand(&.{ aapt2, "compile", "--dir" });
        compile_res.addDirectoryArg(zigui_files.path("src/platform/android/res"));
        compile_res.addArg("-o");
        const res_zip = compile_res.addOutputFileArg("res.zip");
        link.addFileArg(res_zip);
    }

    // Copy the base APK, then add classes.dex + the .so libs STORED (uncompressed) so
    // the loader can mmap them (extractNativeLibs defaults false on modern targets).
    const pack_script =
        "set -e; cp \"$1\" \"$2\"; zip -X -q -j \"$2\" \"$4\"; " ++
        "cd \"$3\"; zip -0 -X -q \"$2\" $(find lib -type f)";
    const pack = b.addSystemCommand(&.{ "sh", "-c", pack_script, "package_apk" });
    pack.addFileArg(base_apk); // $1
    const unsigned_apk = pack.addOutputFileArg("unsigned.apk"); // $2
    pack.addDirectoryArg(tree.getDirectory()); // $3
    pack.addFileArg(classes_dex); // $4

    // Page-align the stored libs, then sign with the debug key.
    const align_cmd = b.addSystemCommand(&.{ zipalign, "-p", "-f", "4" });
    align_cmd.addFileArg(unsigned_apk);
    const aligned_apk = align_cmd.addOutputFileArg("aligned.apk");

    const sign = b.addSystemCommand(&.{
        apksigner,        "sign",
        "--ks-pass",      "pass:android",
        "--ks-key-alias", "androiddebugkey",
        "--key-pass",     "pass:android",
        "--ks",           keystore,
        "--out",
    });
    const app_apk = sign.addOutputFileArg("app.apk");
    sign.addFileArg(aligned_apk);
    // apksigner needs `java` on PATH, not just JAVA_HOME.
    const sign_path = b.fmt("{s}/bin:{s}", .{ java_home, android_env(b, "PATH") orelse "" });
    sign.setEnvironmentVariable("PATH", sign_path);

    const install_apk = b.addInstallBinFile(app_apk, opts.out_name);
    b.getInstallStep().dependOn(&install_apk.step);

    // `zig build run`: install onto a connected device/emulator and launch.
    const adb_install = b.addSystemCommand(&.{ adb, "install", "-r" });
    adb_install.addFileArg(app_apk);
    const component = b.fmt("{s}/{s}", .{ opts.package_name, opts.activity });
    const adb_start = b.addSystemCommand(&.{ adb, "shell", "am", "start", "-n", component });
    adb_start.step.dependOn(&adb_install.step);
    const run_step = b.step("run", "Install and launch the APK on a device/emulator");
    run_step.dependOn(&adb_start.step);
}

// One dynamic .so for `triple`/`arch`, linking the app source against zigui through
// the NDK sysroot (a libc file points Zig at bionic).
fn android_lib(
    b: *std.Build,
    opts: AndroidApkOptions,
    sysroot: []const u8,
    triple: []const u8,
    arch: std.Target.Cpu.Arch,
) *std.Build.Step.Compile {
    const lib_dir = b.fmt("{s}/usr/lib/{s}/{d}", .{ sysroot, triple, opts.min_api });
    const libc = b.addWriteFiles().add(b.fmt("libc-{s}.txt", .{triple}), b.fmt(
        \\include_dir={s}/usr/include
        \\sys_include_dir={s}/usr/include
        \\crt_dir={s}
        \\msvc_lib_dir=
        \\kernel32_lib_dir=
        \\gcc_dir=
        \\
    , .{ sysroot, sysroot, lib_dir }));

    const target = b.resolveTargetQuery(.{ .cpu_arch = arch, .os_tag = .linux, .abi = .android });
    const zigui_dep = b.dependency("zigui", .{
        .target = target,
        .optimize = opts.optimize,
        .android_accessibility = opts.include_accessibility,
        .android_notification_listener = opts.include_notification_listener,
        .android_broadcast = opts.include_broadcast_receiver,
        .android_biometric = opts.include_biometric,
    });
    const zigui = zigui_dep.module("zigui");
    const lib = b.addLibrary(.{
        .name = opts.name,
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = opts.source,
            .target = target,
            .optimize = opts.optimize,
            .imports = &.{.{ .name = "zigui", .module = zigui }},
        }),
    });
    lib.setLibCFile(libc);
    lib.root_module.addLibraryPath(.{ .cwd_relative = lib_dir });
    lib.root_module.linkSystemLibrary("android", .{});
    lib.root_module.linkSystemLibrary("log", .{});
    lib.root_module.linkSystemLibrary("jnigraphics", .{});
    lib.root_module.link_libc = true;
    return lib;
}

fn android_env(b: *std.Build, name: []const u8) ?[]const u8 {
    return b.graph.environ_map.get(name);
}

// Declares one android-capability dependency option and records it in the options
// module the library imports as `android_caps`. Off unless a consumer opts in.
fn android_cap(b: *std.Build, o: *std.Build.Step.Options, name: []const u8, flag: []const u8) void {
    const on = b.option(bool, flag, "android capability bridge (opt-in)") orelse false;
    o.addOption(bool, name, on);
}

// ---- iOS bundle helper (consumer build-time API) ----
// A consumer's build.zig reaches this via `@import("zigui")` and calls iosApp
// once: it cross-compiles the app for the iOS Simulator, assembles a .app from
// the executable plus the app's Info.plist, and (on `zig build run`) installs and
// launches it on the booted simulator. The simulator needs no code signing; a
// real device build + signing is a separate path. Mirrors androidApk.
pub const IOSAppOptions = struct {
    // The bundle + executable base name; must match Info.plist CFBundleExecutable.
    name: []const u8,
    // The app's root Zig source (imports the "zigui" module).
    source: std.Build.LazyPath,
    // The app's Info.plist.
    info_plist: std.Build.LazyPath,
    // The bundle identifier, for `zig build run`'s simctl launch.
    bundle_id: []const u8,
    optimize: std.builtin.OptimizeMode,
};

pub fn iosApp(b: *std.Build, opts: IOSAppOptions) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = b.graph.host.result.cpu.arch,
        .os_tag = .ios,
        .abi = .simulator,
    });
    const zigui_dep = b.dependency("zigui", .{ .target = target, .optimize = opts.optimize });
    const exe = b.addExecutable(.{
        .name = opts.name,
        .root_module = b.createModule(.{
            .root_source_file = opts.source,
            .target = target,
            .optimize = opts.optimize,
            .imports = &.{.{ .name = "zigui", .module = zigui_dep.module("zigui") }},
        }),
    });
    ios_sim_paths(b, exe.root_module);

    // Assemble <name>.app: the executable plus the Info.plist at the bundle root.
    const app_dir = b.fmt("{s}.app", .{opts.name});
    const bundle = b.addWriteFiles();
    _ = bundle.addCopyFile(exe.getEmittedBin(), b.fmt("{s}/{s}", .{ app_dir, opts.name }));
    _ = bundle.addCopyFile(opts.info_plist, b.fmt("{s}/Info.plist", .{app_dir}));
    const app_path = bundle.getDirectory().path(b, app_dir);

    const install = b.addInstallDirectory(.{
        .source_dir = app_path,
        .install_dir = .bin,
        .install_subdir = app_dir,
    });
    b.getInstallStep().dependOn(&install.step);

    // `zig build run`: install onto the booted simulator and launch.
    const sim_install = b.addSystemCommand(&.{ "xcrun", "simctl", "install", "booted" });
    sim_install.addDirectoryArg(app_path);
    const sim_launch = b.addSystemCommand(&.{
        "xcrun", "simctl", "launch", "booted", opts.bundle_id,
    });
    sim_launch.step.dependOn(&sim_install.step);
    const run_step = b.step("run", "Install and launch the app on the booted iOS Simulator");
    run_step.dependOn(&sim_launch.step);
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
