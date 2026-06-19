# Android

zigui runs on Android through the same node-tree API as desktop. The backend
draws with Vulkan on a `NativeActivity` surface, takes touch and soft-keyboard
input, and reaches the platform (notifications, clipboard, battery, and the rest)
through a native-API surface.

The app writes **no Java**. zigui ships its own activity and services under the
`io.qoinly.zigui` package and the JNI exports they call; you supply Zig, a
manifest, and one call to the `zigui.androidApk` build helper.

Targets `minSdk 26` (the Vulkan + `AHardwareBuffer` floor) through `targetSdk 36`,
on both `arm64-v8a` and `x86_64` device ABIs.

## Toolchain

The build shells out to the Android SDK, NDK, and a JDK, located through the
environment:

| Variable | Required | Meaning |
|---|---|---|
| `ANDROID_HOME` | yes | the Android SDK root (`build-tools/`, `platforms/`, `platform-tools/`) |
| `JAVA_HOME` | yes | a JDK; `javac` and `apksigner` need `java` |
| `ANDROID_NDK_HOME` | no | the NDK; defaults to `$ANDROID_HOME/ndk/<ndk_version>` |
| `ANDROID_DEBUG_KEYSTORE` | no | the signing keystore; defaults to `$ANDROID_HOME/debug.keystore` |

The default `build-tools` is `36.0.0` and the default NDK is `29.0.14206865`;
override them through `androidApk` options if your SDK has different versions
installed. The APK is signed with the Android debug key.

## Building an APK

A consumer build.zig supplies only Zig and a manifest:

```zig
const std = @import("std");
const zigui = @import("zigui");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    zigui.androidApk(b, .{
        .name = "my_app",                    // the lib name; matches android.app.lib_name
        .source = b.path("src/main.zig"),    // your Zig root, imports "zigui"
        .manifest = b.path("android/AndroidManifest.xml"),
        .package_name = "com.example.myapp", // applicationId, for `zig build run`
        .optimize = optimize,
        .out_name = "my-app.apk",
    });
}
```

`examples/android-app` keeps its portable Zig in `src/` and the manifest in
`android/`, one folder per platform.

```sh
zig build        # writes the signed APK to zig-out/bin
zig build run    # installs and launches it on a connected device / emulator (adb)
```

`androidApk` cross-compiles one `.so` per ABI, dexes zigui's Java shell, links the
manifest with `aapt2`, packs the libs stored + page-aligned (so the loader mmaps
them), aligns, and signs.

### Options

| Option | Default | Meaning |
|---|---|---|
| `name` | required | output library + APK base name; the manifest's `android.app.lib_name` |
| `source` | required | the app's root Zig source (imports the `zigui` module) |
| `manifest` | required | the app's `AndroidManifest.xml` |
| `package_name` | required | the app's `applicationId`, used by `zig build run` |
| `optimize` | required | the optimize mode |
| `activity` | `io.qoinly.zigui.ZiguiActivity` | the launch activity (the shipped shell) |
| `out_name` | `app.apk` | the installed APK file name under `zig-out/bin` |
| `ndk_version` | `29.0.14206865` | NDK version under `$ANDROID_HOME/ndk` |
| `build_tools` | `36.0.0` | build-tools version |
| `api` | `36` | the compile/target API |
| `min_api` | `26` | the minimum API |
| `include_accessibility` | `false` | the accessibility service (Java + native) + its config resource |
| `include_notification_listener` | `false` | the notification-listener service (Java + native) |
| `include_broadcast_receiver` | `false` | the static broadcast receiver (headless broadcasts) |
| `include_biometric` | `false` | the biometric result-callback bridge (native) |

These four are the capability opt-in. Each off (the default) means the app compiles
**neither** the Java **nor** the native code for that capability - a minimal app
carries zero accessibility / notification-listener / broadcast / biometric code. The
matching `napi.*` calls degrade to a safe no-op when the capability is not opted in.

### Manifest

The manifest names the shipped activity and points its `android.app.lib_name`
meta-data at your `name`:

```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="com.example.myapp">

    <uses-sdk android:minSdkVersion="26" android:targetSdkVersion="36" />

    <application android:label="My App">
        <activity
            android:name="io.qoinly.zigui.ZiguiActivity"
            android:exported="true"
            android:configChanges="orientation|keyboardHidden|screenSize">
            <meta-data android:name="android.app.lib_name" android:value="my_app" />
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity>
    </application>
</manifest>
```

Declare a `<uses-permission>` for each native API you call (`VIBRATE`,
`POST_NOTIFICATIONS`, `USE_BIOMETRIC`, the SMS permissions, and so on).

## App shape

The view API is identical to desktop; the lifecycle differences are in
[app-window.md](app-window.md#on-android). The main one: `run` does not block on
Android (the framework owns the loop and the surface arrives later), so the app
state can not be a `main` stack local - give it a lifetime that outlives `main`:

```zig
const zigui = @import("zigui");

const App = struct { clicks: u32 = 0 };
var state: App = .{};               // module scope - outlives main

pub fn main() !void {
    var app = try zigui.App.init(.{ .title = "My App", .size = .{ 400, 800 } });
    try app.run(&state, .{ .body = render });
}

fn render(f: *zigui.Frame, app: *App) *zigui.Node {
    _ = f;
    return zigui.col(.{ .pad = .lg, .gap = .md }, &.{
        zigui.text("Hello, Android.", .{ .size = 28 }),
        zigui.button("Tap me", .{ .on_click = zigui.on(App, on_tap) }),
    });
}

fn on_tap(app: *App) void {
    app.clicks += 1;
}
```

`f.body` is already inset past the status and navigation bars. There is one
fullscreen surface: no extra windows and no custom window chrome.

`examples/android-app` is a full working app driving the kit and the native APIs.

## Native APIs

Platform integration lives under `zigui.napi.*`, one struct per domain. Every call
degrades to a safe no-op (or a default) when the permission is missing or the JNI
lookup fails, so a call is never a crash:

| Domain | Reaches |
|---|---|
| `napi.notifications` | post a notification, show a toast |
| `napi.clipboard` | read / write the clipboard |
| `napi.haptics` | vibrate |
| `napi.device` | battery level, charging, connectivity |
| `napi.display` | keep-awake, status-bar icons, immersive mode, orientation, brightness |
| `napi.links` | open a URL, share text |
| `napi.permissions` | query and request runtime permissions |
| `napi.picker` | the system document picker |
| `napi.biometric` | the biometric prompt |
| `napi.accessibility` | gesture injection, screen read, a11y-event subscription |
| `napi.notification_listener` | observe posted notifications |
| `napi.broadcast` | subscribe to system broadcasts; `take()` yields `Broadcast{action, extras}` |
| `napi.sms` | read the inbox, send a message |

The async results (a picked file, a biometric outcome, a forwarded notification)
are read once per frame through a `take_*` poll, so a view stays a pure function of
state. `napi.broadcast.take()` returns a `Broadcast{ action, extras: []const
KeyValue }`: a broadcast can carry many extras (battery state has ~15), SMS is
decoded to `address`/`body` pairs, and the data URI rides as `data`.

## Background work

Run a heavy job off the UI thread so it never holds a frame. The result rides the
same poll the napi sinks use - a worker writes it into a caller-owned `Task`, and a
view reads it once with `poll`:

```zig
var job: zigui.Task(u64) = .{}; // caller-owned, lives in app state

fn start(app: *App) void {
    if (job.busy()) return;
    // work: fn(*App, *const zigui.background.Cancel) ?u64 (null = cancelled)
    zigui.background.submit(&job, app, work);
}

fn render(f: *zigui.Frame, app: *App) *zigui.Node {
    if (job.poll()) |result| { _ = result; } // once, the frame the job finished
    // ...
}
```

A job runs on its own thread (concurrency is capped; past the cap it runs inline),
and a finished job nudges the loop to render so the poll fires. `request_cancel`
sets a cooperative flag the job checks. The contract: a job is pure Zig / syscalls /
sockets - it must NOT call `napi.*`. Off the UI thread napi refuses the call (a
one-time logcat warning and a no-op), so a stray call degrades safely instead of
touching a wrong-thread JNIEnv. The desktop idle-loop wake is a follow-up; the Android
vsync loop needs none.

## Background events (headless)

Android delivers some events even when the app is not foreground - a posted
notification, or a broadcast the app declares in its manifest (the system
cold-starts the process to deliver). Define `on_background_event` in your root and
zigui calls it with the decoded event, on the delivering thread, with no render loop:

```zig
pub fn on_background_event(ev: zigui.BackgroundEvent) void {
    switch (ev) {
        .notification => |n| log(n.package, n.title, n.text),
        .broadcast => |b| {
            // b.action, plus b.extras (e.g. address= / body= for SMS)
            for (b.extras) |kv| store(kv.key, kv.value);
        },
    }
}
```

The entry is comptime-discovered (the same bridge as `main`), so it resolves whether
or not `main` ran - the cold-start case where no runtime registration could have
happened. The handler is pure Zig over a decoded, borrowed payload (copy what you
keep); like a background job it must not call `napi.*`.

Notifications arrive once the listener is enabled. A broadcast runs headless only
through a manifest-declared receiver (the runtime `napi.broadcast.subscribe` path
delivers only while the process is alive):

```zig
zigui.androidApk(b, .{ .include_broadcast_receiver = true /* ... */ });
```

```xml
<receiver android:name="io.qoinly.zigui.ZiguiBroadcastReceiver" android:exported="true">
    <intent-filter>
        <action android:name="android.provider.Telephony.SMS_RECEIVED" />
    </intent-filter>
    <meta-data android:name="android.app.lib_name" android:value="my_app" />
</receiver>
```

Since API 26 only an allowlist of broadcasts may start a manifest receiver
(`SMS_RECEIVED`, `BOOT_COMPLETED`, ...). A cold start reaches a naturally-killed /
cached process, but NOT one the user force-stopped - Android's stopped-state rule
withholds broadcasts from it until the user relaunches.

## Optional services

The accessibility service and the notification listener are system-bound services
that call back into native code. They are off by default - off means neither the
Java nor the native code is compiled in, so a minimal app ships none of it. Turn one
on at the build (the `include_*` option above) and declare it in the manifest; until
then the matching `napi.*` calls are no-ops.

```zig
zigui.androidApk(b, .{
    // ...
    .include_accessibility = true,
    .include_notification_listener = true,
});
```

```xml
<service
    android:name="io.qoinly.zigui.ZiguiAccessibilityService"
    android:exported="true"
    android:permission="android.permission.BIND_ACCESSIBILITY_SERVICE">
    <intent-filter>
        <action android:name="android.accessibilityservice.AccessibilityService" />
    </intent-filter>
    <meta-data android:name="android.accessibilityservice"
        android:resource="@xml/zigui_accessibility_config" />
    <meta-data android:name="android.app.lib_name" android:value="my_app" />
</service>

<service
    android:name="io.qoinly.zigui.ZiguiNotificationListenerService"
    android:exported="true"
    android:permission="android.permission.BIND_NOTIFICATION_LISTENER_SERVICE">
    <intent-filter>
        <action android:name="android.service.notification.NotificationListenerService" />
    </intent-filter>
    <meta-data android:name="android.app.lib_name" android:value="my_app" />
</service>
```

Each service self-loads the app `.so` through its own `android.app.lib_name`
meta-data, so the native callbacks resolve. The user still grants the service in
system settings at runtime; `napi.accessibility.request_enable` and
`napi.notification_listener.request_enable` open the right settings screen.

## Limitations

- Text is Latin / BMP without shaping: no ligatures or kerning, no CJK, no emoji
  or colour glyphs, no bidi / RTL. The glyphs come from the platform `Paint` per
  codepoint.
- One fullscreen surface: no extra windows, no custom chrome, no `grab` raw-input
  capture.
- Touch tracks a single pointer (no multi-finger gestures).
