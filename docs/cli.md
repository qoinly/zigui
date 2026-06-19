# The `zigui` CLI

A small command-line tool that scaffolds a new zigui project and checks the Android
toolchain. Build it from the repo:

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
  [x] android
```

Piped or scripted, drive it with flags instead:

```sh
zigui create myapp --target desktop,android --package com.example.myapp
```

| Flag | Meaning |
|---|---|
| `--name <name>` | project name (or the first positional argument) |
| `--package <id>` | package id (default `com.example.<name>`) |
| `--target <a,b>` | `desktop`, `android` (required when not a terminal) |
| `--out <dir>` | output directory (default `<name>`) |
| `--force` | overwrite files that already exist |

It writes `build.zig`, `build.zig.zon`, `src/main.zig`, and - for an android target -
`android/AndroidManifest.xml`. It is non-destructive: an existing file is skipped
(reported) unless `--force`, so running it again in a project only fills in what is
missing.

What each target produces:

| Target | `zig build` produces | run with |
|---|---|---|
| `desktop` | a native executable | `zig build run` |
| `android` | a signed APK (needs the SDK; see below) | `zig build run` (install + launch) |
| both | the executable and the APK | `zig build desktop` / `zig build run` |

The generated `build.zig.zon` depends on zigui; for an android build the toolchain
must be in place - run `zigui doctor` to check.

## `zigui doctor`

Checks the Android toolchain a scaffolded app needs to package an APK, and reports
each piece. It exits non-zero when a required tool is missing.

```
$ zigui doctor
zigui doctor - Android toolchain

  [ok] ANDROID_HOME = /home/you/android
  [ok] JAVA_HOME = /home/you/android/jdk
  [ok] javac  /home/you/android/jdk/bin/javac
  [ok] ndk  /home/you/android/ndk/29.0.14206865
  ...
all set - `zig build` in a scaffolded app will package an APK.
```

`[ok]` present, `[x]` a required tool missing, `[--]` an optional one missing (adb,
the emulator, the debug keystore). Required: `ANDROID_HOME`, `JAVA_HOME`, `javac`, the
NDK, `aapt2` / `zipalign` / `apksigner` / `d8`, and the platform `android.jar`. The
versions checked match the `androidApk` defaults (see [android.md](android.md)).

## Other commands

| Command | Meaning |
|---|---|
| `zigui help` | usage |
| `zigui version` | the version |
