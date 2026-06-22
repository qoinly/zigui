# iOS

zigui runs on iOS through the same node-tree API as desktop. The backend draws with
Metal (the same renderer as macOS), takes touch input, and reaches the platform
(notifications, clipboard, Face ID, and the rest) through a native-API surface.

It writes **no Swift and no `.m`** - the backend builds its UIKit objects (the app
delegate, the scene delegate, the view controller, the Metal view) at runtime through
the shared Objective-C runtime, the same bridge the macOS backend uses. You supply
Zig, an `Info.plist`, and one call to `zigui.app` (or the low-level `zigui.iosApp`).

The build targets the iOS **Simulator** and needs macOS + Xcode's command-line tools
(`xcrun`). A real-device build (code signing + `devicectl`) is a separate path, not
wired yet. `MinimumOSVersion` is `15.0`.

## Building

A consumer build.zig declares its targets with one `zigui.app` call:

```zig
const std = @import("std");
const zigui = @import("zigui");

pub fn build(b: *std.Build) void {
    zigui.app(b, .{
        .source = b.path("src/main.zig"),     // your Zig root, imports "zigui"
        .ios = .{
            .name = "MyApp",                   // matches Info.plist CFBundleExecutable
            .info_plist = b.path("ios/Info.plist"),
            .bundle_id = "com.example.myapp",  // for `zig build run`'s simctl launch
        },
        // .desktop = .{ .name = "MyApp" },    // mix in other targets if you want
    });
}
```

`examples/ios-app` keeps its portable Zig in `src/` and the `Info.plist` in `ios/`,
one folder per platform.

```sh
zig build ios                  # cross-compiles + assembles MyApp.app under zig-out
zig build run -- ios           # installs + launches on the booted simulator
zig build run -- ios <udid>    # ... on a specific simulator (xcrun simctl list)
```

`iosApp` cross-compiles the app for the simulator (arm64 on Apple silicon), assembles
a `.app` from the executable plus the `Info.plist`, and on `run` installs and launches
it with `simctl`. A Debug build is forced to at least `ReleaseSmall` (a Debug iOS build
pulls a MachO-symbolizer symbol the simulator SDK lacks).

`zigui.iosApp` is the low-level helper (one target, finer control); `zigui.app` is the
high-level entry the CLI scaffolds.

## Info.plist

A minimal plist names the executable and the bundle, declares the orientations, and -
importantly - opts into scenes:

```xml
<key>UIApplicationSceneManifest</key>
<dict>
    <key>UIApplicationSupportsMultipleScenes</key>
    <false/>
</dict>
```

The backend is scene-managed: the window is owned by a runtime `UIWindowScene`
delegate, so a rotation resizes the window and the safe-area insets follow. Without the
scene manifest the window never appears. `zigui create --target ios` writes a correct
`Info.plist`. Add a usage-description key (`NSCameraUsageDescription`,
`NSFaceIDUsageDescription`, `NSLocationWhenInUseUsageDescription`, ...) for each
permission you request.

## App shape

The view API is identical to desktop; the lifecycle differences are in
[app-window.md](app-window.md#on-ios). `UIApplicationMain` owns the loop and never
returns from `app.run`, so the app state can not be a `main` stack local - give it a
lifetime that outlives `main`:

```zig
const zigui = @import("zigui");

const App = struct { clicks: u32 = 0 };
var state: App = .{};               // module scope - outlives main

pub fn main() !void {
    var app = try zigui.App.init(.{ .title = "My App", .size = .{ 400, 800 } });
    try app.run(&state, .{ .body = render });
}

fn render(f: *zigui.Frame, app: *App) *zigui.Node {
    _ = app;
    return zigui.col(.{ .pad = .lg, .gap = .md }, &.{
        zigui.text("Hello, iOS.", .{ .size = 28 }),
        zigui.button("Tap me", .{ .on_click = zigui.on(App, on_tap) }),
    });
}

fn on_tap(app: *App) void {
    app.clicks += 1;
}
```

`f.body` is already inset past the status bar, the notch / Dynamic Island, and the home
indicator - and the insets follow the orientation (in landscape they move to the side).
A view that wants its content to clear the notch lays out within `f.body`; the top inset
alone is not enough in landscape. There is one fullscreen surface: no extra windows, no
custom chrome.

`examples/ios-app` is a full working app driving the kit and the native APIs.

## Native APIs

Platform integration lives under `zigui.napi.*`, one struct per domain. Every call
degrades to a safe no-op when the permission is missing or the API is unavailable, so a
call is never a crash:

| Domain | Reaches |
|---|---|
| `napi.notifications` | post a local notification, show a toast |
| `napi.clipboard` | read / write the clipboard |
| `napi.haptics` | vibrate |
| `napi.device` | battery level, charging, connectivity, app version |
| `napi.display` | keep-awake, status-bar style, immersive mode, orientation lock, brightness |
| `napi.links` | open a URL, share text |
| `napi.permissions` | query and request camera / mic / photos / notifications / location |
| `napi.picker` | the system document picker |
| `napi.biometric` | the Face ID / Touch ID prompt |
| `napi.sms` | open the system composer (the inbox is private, so no read) |

`display.orientation(.landscape \| .portrait \| .auto)` locks the interface; because the
window is scene-managed it rotates and reflows the surface immediately. The caller owns
the policy (per page or whole app) - zigui provides the mechanism.

The async results (a picked file, a biometric outcome) are read once per frame through a
`take_*` poll, so a view stays a pure function of state.

## Limitations

- Simulator only - no real-device build (code signing + `devicectl`) yet.
- `sms.read` is impossible (the iOS inbox is private); `accessibility`,
  `notification_listener`, `broadcast`, and headless background events have no iOS
  equivalent and report unsupported.
- One fullscreen surface: no extra windows, no custom chrome, no `grab` raw-input
  capture.
- Text is Latin / BMP without shaping (shared with the other backends).
