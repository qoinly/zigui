const std = @import("std");

// Standalone example: cross-compiles the native .so for both device ABIs and
// packages a signed, installable APK, the showcase pattern. `zig build` writes
// the APK to zig-out; `zig build run` installs and launches it on a connected
// device or emulator. The SDK/NDK/JDK paths come from the environment so
// nothing tool-specific is hardcoded; the manifest is a real file, never a
// string here.
//
// Required env: ANDROID_HOME (SDK root). Optional: ANDROID_NDK_HOME,
// JAVA_HOME (apksigner needs `java`), ANDROID_DEBUG_KEYSTORE.
pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    const sdk = env(b, "ANDROID_HOME") orelse {
        std.debug.print("android-app: set ANDROID_HOME to the Android SDK root\n", .{});
        return;
    };
    const ndk_ver = b.option([]const u8, "ndk", "NDK version dir") orelse "29.0.14206865";
    const bt_ver = b.option([]const u8, "build-tools", "build-tools version") orelse "36.0.0";
    const api = b.option(u32, "api", "compile/link platform API level") orelse 36;
    const min_api = b.option(u32, "min-api", "minimum API (crt level)") orelse 26;

    const ndk = env(b, "ANDROID_NDK_HOME") orelse b.fmt("{s}/ndk/{s}", .{ sdk, ndk_ver });
    const sysroot = b.fmt("{s}/toolchains/llvm/prebuilt/linux-x86_64/sysroot", .{ndk});
    const build_tools = b.fmt("{s}/build-tools/{s}", .{ sdk, bt_ver });
    const android_jar = b.fmt("{s}/platforms/android-{d}/android.jar", .{ sdk, api });
    const keystore = env(b, "ANDROID_DEBUG_KEYSTORE") orelse b.fmt("{s}/debug.keystore", .{sdk});
    const aapt2 = b.fmt("{s}/aapt2", .{build_tools});
    const zipalign = b.fmt("{s}/zipalign", .{build_tools});
    const apksigner = b.fmt("{s}/apksigner", .{build_tools});
    const d8 = b.fmt("{s}/d8", .{build_tools});
    const adb = b.fmt("{s}/platform-tools/adb", .{sdk});
    const java_home = env(b, "JAVA_HOME") orelse {
        std.debug.print("android-app: set JAVA_HOME (javac compiles the IME shim)\n", .{});
        return;
    };
    const javac = b.fmt("{s}/bin/javac", .{java_home});

    // One shared library per device ABI, bundled into the APK under lib/<abi>.
    const lib_x86 = android_lib(b, optimize, sysroot, "x86_64-linux-android", .x86_64, min_api);
    const lib_arm = android_lib(b, optimize, sysroot, "aarch64-linux-android", .aarch64, min_api);

    // The lib tree the APK expects (lib/<abi>/lib<name>.so), assembled so the
    // packaging step can zip it in with the right paths.
    const tree = b.addWriteFiles();
    _ = tree.addCopyFile(lib_x86.getEmittedBin(), "lib/x86_64/libzigui_android_app.so");
    _ = tree.addCopyFile(lib_arm.getEmittedBin(), "lib/arm64-v8a/libzigui_android_app.so");

    // Compile the Java IME shim and dex it (the only Java in the app). javac emits
    // .class into a scratch dir, d8 translates them to classes.dex in the output
    // dir; it is bundled at the APK root (the manifest sets hasCode=true).
    const dex_script =
        "set -e; OUT=\"$(dirname \"$5\")\"; CL=\"$OUT/cls\"; rm -rf \"$CL\"; mkdir -p \"$CL\"; " ++
        "\"$1\" -cp \"$2\" -d \"$CL\" \"$3\"; " ++
        "\"$4\" --lib \"$2\" --min-api 26 --output \"$OUT\" $(find \"$CL\" -name '*.class')";
    const dex = b.addSystemCommand(&.{ "sh", "-c", dex_script, "dex" });
    dex.addArg(javac); // $1
    dex.addArg(android_jar); // $2
    dex.addFileArg(b.path("java/com/qoinly/zigui/androidapp/ZiguiActivity.java")); // $3
    dex.addArg(d8); // $4
    const classes_dex = dex.addOutputFileArg("classes.dex"); // $5
    dex.setEnvironmentVariable("JAVA_HOME", java_home); // the d8 wrapper script needs java

    // aapt2 compiles the manifest to binary XML and produces the base APK
    // (manifest + resources.arsc, no libs yet).
    const link = b.addSystemCommand(&.{ aapt2, "link", "-I", android_jar, "--manifest" });
    link.addFileArg(b.path("AndroidManifest.xml"));
    link.addArg("-o");
    const base_apk = link.addOutputFileArg("base.apk");

    // Copy the base APK and add the .so libs STORED (uncompressed) so the
    // loader can mmap them (extractNativeLibs defaults false on modern target
    // SDKs). One shell step keeps the output a tracked LazyPath.
    const pack_script =
        "set -e; cp \"$1\" \"$2\"; zip -X -q -j \"$2\" \"$4\"; " ++
        "cd \"$3\"; zip -0 -X -q \"$2\" $(find lib -type f)";
    const pack = b.addSystemCommand(&.{ "sh", "-c", pack_script, "package_apk" });
    pack.addFileArg(base_apk); // $1
    const unsigned_apk = pack.addOutputFileArg("unsigned.apk"); // $2
    pack.addDirectoryArg(tree.getDirectory()); // $3
    pack.addFileArg(classes_dex); // $4 - classes.dex added at the APK root

    // Page-align the stored libs (zipalign -p), then sign with the debug key.
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
    const sign_path = b.fmt("{s}/bin:{s}", .{ java_home, env(b, "PATH") orelse "" });
    sign.setEnvironmentVariable("PATH", sign_path);

    const install_apk = b.addInstallBinFile(app_apk, "zigui-android-app.apk");
    b.getInstallStep().dependOn(&install_apk.step);

    // `zig build run`: install onto a connected device/emulator and launch.
    const adb_install = b.addSystemCommand(&.{ adb, "install", "-r" });
    adb_install.addFileArg(app_apk);
    const activity = "com.qoinly.zigui.androidapp/.ZiguiActivity";
    const adb_start = b.addSystemCommand(&.{ adb, "shell", "am", "start", "-n", activity });
    adb_start.step.dependOn(&adb_install.step);
    const run_step = b.step("run", "Install and launch the APK on a device/emulator");
    run_step.dependOn(&adb_start.step);
}

fn android_lib(
    b: *std.Build,
    optimize: std.builtin.OptimizeMode,
    sysroot: []const u8,
    triple: []const u8,
    arch: std.Target.Cpu.Arch,
    min_api: u32,
) *std.Build.Step.Compile {
    const lib_dir = b.fmt("{s}/usr/lib/{s}/{d}", .{ sysroot, triple, min_api });
    // Zig does not ship bionic, so point it at the NDK sysroot via a libc file.
    const libc = b.addWriteFiles().add(b.fmt("libc-{s}.txt", .{triple}), b.fmt(
        \\include_dir={s}/usr/include
        \\sys_include_dir={s}/usr/include
        \\crt_dir={s}
        \\msvc_lib_dir=
        \\kernel32_lib_dir=
        \\gcc_dir=
        \\
    , .{ sysroot, sysroot, lib_dir }));

    const query = std.Target.Query{ .cpu_arch = arch, .os_tag = .linux, .abi = .android };
    const target = b.resolveTargetQuery(query);
    const zigui_dep = b.dependency("zigui", .{ .target = target, .optimize = optimize });
    const zigui = zigui_dep.module("zigui");
    const lib = b.addLibrary(.{
        .name = "zigui_android_app",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
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

fn env(b: *std.Build, name: []const u8) ?[]const u8 {
    return b.graph.environ_map.get(name);
}
