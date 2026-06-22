# The `zigui` CLI

A small command-line tool that scaffolds a new zigui project and checks the Android
and iOS toolchains. Build it from the repo:

```sh
zig build cli      # writes zig-out/bin/zigui
```

Put `zig-out/bin/zigui` on your `PATH`, or call it directly.

## `zigui create [name]`

Scaffolds a new project. On a terminal it is interactive - it asks for the project
name, the package id, and which targets to build (pick one or more with space):

```
$ zigui create
Project name (my-zigui-app) > myapp
Package id (com.example.myapp) >
Targets (space toggles, enter confirms)
> [x] desktop
  [ ] android
  [ ] ios
```

Piped or scripted, drive it with flags instead:

```sh
zigui create myapp --target desktop,ios --package com.example.myapp
```

| Flag | Meaning |
|---|---|
| `--name <name>` | project name (or the first positional argument) |
| `--package <id>` | package id (default `com.example.<name>`) |
| `--target <a,b>` | `desktop`, `android`, `ios` (required when not a terminal) |
| `--out <dir>` | output directory (default `<name>`) |
| `--force` | overwrite files that already exist |

It writes `build.zig`, `build.zig.zon`, `src/main.zig`, and, per target, the platform
files: `android/AndroidManifest.xml` for android, `ios/Info.plist` for ios. The
generated `build.zig` is a single `zigui.app` call declaring the chosen targets - see
[android.md](android.md) and [ios.md](ios.md) for the per-platform build. It prints
each path created and the next commands to run, and is non-destructive: an existing
file is skipped (reported) unless `--force`, so re-running only fills in what is
missing.

What each target produces:

| Target | `zig build <target>` produces | run with |
|---|---|---|
| `desktop` | a native executable | `zig build run -- desktop` |
| `android` | a signed APK (needs the SDK) | `zig build run -- android [serial]` |
| `ios` | a `.app` for the Simulator (needs Xcode) | `zig build run -- ios [udid]` |

One `run` step dispatches on the first `--` argument; an optional second argument picks
the device (an adb serial, or a simulator UDID from `xcrun simctl list`). With no
argument it runs the first declared target. Run `zigui doctor` to check the toolchains.

## `zigui doctor`

Checks the toolchains a scaffolded app needs - the Android SDK/NDK/JDK to package an
APK, and Xcode's command-line tools to build for the iOS Simulator - and reports each
piece. It exits non-zero when a *configured* toolchain is missing a required tool.

```
$ zigui doctor
zigui doctor

Android (APK build):
  [ok] ANDROID_HOME = /home/you/android
  [ok] JAVA_HOME = /home/you/android/jdk
  [ok] javac  /home/you/android/jdk/bin/javac
  ...

iOS (Simulator build):
  [ok] xcrun  /usr/bin/xcrun
  boot a simulator (`xcrun simctl boot <udid>`) before `zig build run -- ios`.

ready - a scaffolded app can build for its configured target(s).
```

`[ok]` present, `[x]` a required tool missing, `[--]` optional or not configured. The
Android section requires `ANDROID_HOME`, `JAVA_HOME`, `javac`, the NDK, `aapt2` /
`zipalign` / `apksigner` / `d8`, and the platform `android.jar` (the versions checked
match the `androidApk` defaults; see [android.md](android.md)). The iOS section needs
macOS + `xcrun`. A toolchain that is simply not configured is reported `[--]`, not
counted as broken.

## Other commands

| Command | Meaning |
|---|---|
| `zigui help` | usage |
| `zigui version` | the version |
