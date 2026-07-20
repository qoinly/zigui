# System integration

Clipboard, fullscreen, and display enumeration act on the window drawing the
current frame - call them from a view fn. Everything else the OS exposes -
notifications, haptics, battery, links, the file picker, biometrics, and more -
lives under the native-API namespace `zigui.napi.*`, covered in [Native APIs](#native-apis-napi)
below.

## Clipboard

Write plain text from any platform:

```zig
fn copy(app: *App) void {
    zigui.set_clipboard("hello");   // a Copy button
}
```

`zigui.set_clipboard(s)` is the top-level write. To *read* the clipboard or poll
for outside changes, use the `napi.clipboard` domain (all platforms, desktop
included):

| Call | What it does |
|---|---|
| `napi.clipboard.write(text)` | write `text` (same as `zigui.set_clipboard`) |
| `napi.clipboard.read(buf)` | read the clipboard into `buf`, returns the slice |
| `napi.clipboard.changed()` | true once when something *outside* this app changed it |

There is one clipboard for the whole app. `changed()` fires once per change and
your own writes don't count, so poll it once a frame. See
`examples/clipboard_demo.zig`.

## Fullscreen

```zig
zigui.set_fullscreen(true);   // native fullscreen (its own Space on macOS)
const on = zigui.fullscreen();
```

| Fn | What it does |
|---|---|
| `set_fullscreen(enable)` | toggle native fullscreen on the current window |
| `fullscreen()` | whether the current window is fullscreen |

The custom title band hides while fullscreen and comes back on exit. On mobile,
edge-to-edge / immersive mode is `napi.display.immersive` instead (below). To
minimize or hide the window, see [Window controls](app-window.md#window-controls).

## Displays

List the monitors to size a stream or place a window per screen.

```zig
var i: u32 = 0;
while (i < zigui.display_count()) : (i += 1) {
    const b = zigui.display_bounds(i);  // BoundsF, in points
    ...
}
```

| Fn | What it does |
|---|---|
| `display_count()` | how many displays there are |
| `display_bounds(i)` | display `i`'s frame in points (`BoundsF`); empty if out of range |

See `examples/display_demo.zig`.

## Native APIs (napi)

`zigui.napi.*` wraps the platform's own APIs. It is a **namespace**, not a set of
flat wrappers, so each call is analyzed lazily: an API a target lacks is a compile
error only where a caller actually uses it. That means you can call
`napi.haptics.vibrate` freely in shared code - it only needs to exist on the
targets you build for.

Availability below: **desktop** = macOS / Windows / Linux, **A** = Android,
**i** = iOS. Platform *setup* (Android manifest entries, iOS `Info.plist` keys,
runtime permissions) is covered in [docs/android.md](android.md) and
[docs/ios.md](ios.md); this is the API catalog.

### Feedback & links (A, i)

| Call | What it does |
|---|---|
| `napi.haptics.vibrate(ms)` | vibrate for `ms` milliseconds |
| `napi.links.open_url(url)` | open a URL in the browser / handler app |
| `napi.links.share_text(text)` | raise the system share sheet |
| `napi.notifications.post(title, body)` | post a system notification |
| `napi.notifications.toast(text)` | a transient overlay message (no permission) |

### Permissions (A, i)

| Call | What it does |
|---|---|
| `napi.permissions.granted(name)` | whether `name` is granted |
| `napi.permissions.status(name)` | `Status` = `granted`, `not_requested`, `declined`, `declined_permanent` |
| `napi.permissions.request(name)` | raise the OS permission prompt |
| `napi.permissions.declared(out, scratch)` | the permissions the app declares |

Names are `"camera"`, `"microphone"`, `"photos"`, `"notifications"`,
`"location"`, etc.

### File picker (A, i)

| Call | What it does |
|---|---|
| `napi.picker.open_file()` | raise the system document picker |
| `napi.picker.pending()` | whether a pick is in flight |
| `napi.picker.take_file()` | `?PickedFile { name, path }` once the user picks; the picker imports a readable local copy |

Desktop file dialogs are separate - see `zigui.Window.open_file` / `save_file`,
or read OS drag-and-drop with `zigui.dropped_files()` ([Input](input.md#file-drop)).

### Display & device (A, i)

`napi.display.keep_awake` also works on desktop; the rest of `display` is mobile.

| Call | What it does |
|---|---|
| `napi.display.keep_awake(on)` | hold the screen awake (all platforms) |
| `napi.display.immersive(on)` | edge-to-edge; hide the system bars |
| `napi.display.status_bar_icons(which)` | `light` / `dark` status-bar icon tint |
| `napi.display.orientation(which)` | lock orientation: `auto`, `portrait`, `landscape`, `sensor` |
| `napi.display.brightness(level)` | screen brightness `0..1`; negative resets to system |
| `napi.device.battery_level()` | battery percent `0..100` |
| `napi.device.charging()` | whether it is charging |
| `napi.device.online()` | any network reachable |
| `napi.device.network()` | `Network` = `none`, `wifi`, `cellular`, `other` |
| `napi.device.app_version(buf)` | the app's version string into `buf` |

### Biometric & SMS (A, i)

| Call | What it does |
|---|---|
| `napi.biometric.available()` | whether Face ID / fingerprint is set up |
| `napi.biometric.authenticate(title, subtitle)` | raise the biometric prompt (async) |
| `napi.biometric.result()` | `?Outcome` = `success` / `failed`, read once |
| `napi.sms.send(address, body)` | send an SMS (needs the SMS permission) |
| `napi.sms.read(buf)` | read the inbox into `buf` (needs the read-SMS permission) |

### Android-only services

Background integrations that only Android exposes:

| Domain | What it does |
|---|---|
| `napi.accessibility` | an accessibility service: read the screen, inject taps/swipes, global actions (back/home/recents), subscribe to events |
| `napi.notification_listener` | read other apps' posted notifications (`package\ttitle\ttext`) |
| `napi.broadcast` | subscribe to system broadcasts and read their extras |

These need the user to enable the service in system settings; see
[docs/android.md](android.md).

## Background work

Run a heavy job off the UI thread and read its result back in a view with a poll -
cross-platform (`std.Thread`).

```zig
const App = struct { job: zigui.Task(Report) = .{} };

fn start(app: *App) void {
    zigui.background.submit(&app.job, ctx, work);   // work: fn(ctx, *const Cancel) ?Report
}

fn render(f: *zigui.Frame, app: *App) *zigui.Node {
    if (app.job.poll()) |report| app.report = report;   // once, when it finishes
    if (app.job.busy()) zigui.animate();
    ...
}
```

`zigui.Task(T)` is a caller-owned handle: `busy()`, `poll()` (returns the result
once), `request_cancel()`. The worker must **not** call `napi.*` (it is off the UI
thread). On Android a finished job nudges the vsync loop so the poll runs.

## Background events (headless)

Android can deliver a notification or broadcast to the app with no foreground - no
window, maybe no running process. Handle it by defining a root-level function:

```zig
pub fn on_background_event(ev: zigui.BackgroundEvent) void {
    switch (ev) {
        .notification => |n| { ... },   // { package, title, text }
        .broadcast => |b| { ... },      // an action + its extras
    }
}
```

`BackgroundEvent` is dispatched over JNI on a service/receiver thread. Do
storage/network work; do not touch the UI (there may be no surface). See
[docs/android.md](android.md#background-events-headless).
