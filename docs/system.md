# System integration

Clipboard, fullscreen, and display enumeration. Call these from a view fn - they
act on the window drawing the current frame.

> Desktop backends. Android exposes its system integration through a separate
> native-API surface, `zigui.napi.*` (clipboard, notifications, haptics, battery,
> connectivity, brightness, orientation, links, file picker, biometric, and more),
> documented in [docs/android.md](android.md). `set_fullscreen` maps to Android
> immersive mode (hiding the system bars).

## Clipboard

Read and write plain text, and poll for outside changes.

```zig
fn render(f: *zigui.Frame, app: *App) *zigui.Node {
    if (zigui.clipboard_changed()) {
        app.text_len = zigui.clipboard_text(&app.buf).len;
    }
    ...
}

fn copy(app: *App) void {
    zigui.set_clipboard_text("hello");
}
```

| Fn | What it does |
|---|---|
| `clipboard_text(buf)` | read the clipboard into `buf`, returns the slice |
| `set_clipboard_text(s)` | write `s` to the clipboard |
| `clipboard_changed()` | true once when something *outside* this app changed it |

There is one clipboard for the whole app, shared by every window.
`clipboard_changed` fires once per change and your own writes don't count, so poll
it once a frame from one window. See `examples/clipboard_demo.zig`.

## Fullscreen

```zig
zigui.set_fullscreen(true);   // native fullscreen (its own Space on macOS)
const on = zigui.fullscreen();
```

| Fn | What it does |
|---|---|
| `set_fullscreen(enable)` | toggle native fullscreen on the current window |
| `fullscreen()` | whether the current window is fullscreen |

The custom title band hides while fullscreen and comes back on exit.

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
