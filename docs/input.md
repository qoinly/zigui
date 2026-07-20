# Input

Most input drives the widgets for you - clicks, typing, scroll, drag. This page
covers the frame-level input you read directly: raw capture under a *grab*,
app-wide keyboard shortcuts, OS file drops, a hover query, draggable nodes, and
the text-field completion seams.

## Grab

While a window is *grabbed*, zigui hides the cursor and reports raw input -
relative motion, physical key scancodes, buttons, wheel - instead of sending it to
the UI. A remote-control loop forwards this over a wire; a game uses it for
mouselook. You get the raw events; what you send and how is up to you. No special
permission is needed. See `examples/input_demo.zig`.

> This raw-capture path is for desktop pointer + keyboard. On Android and iOS, touch
> drives the widgets directly (taps, drags, scroll) and the soft keyboard feeds text
> through the platform editor - there is no `grab`. See [docs/android.md](android.md),
> [docs/ios.md](ios.md).

```zig
zigui.grab(true);            // hide the cursor and capture raw input
defer zigui.grab(false);
```

| Fn | What it does |
|---|---|
| `grab(enable)` | start or stop capture |
| `grabbed()` | whether capture is on |
| `input_events()` | the raw events since the last frame (`[]const InputEvent`) |

Escape ends the grab (the key is swallowed, not reported), and so does losing
focus, so the cursor never gets stuck off-screen.

## Reading events

Drain `input_events()` each frame while grabbed:

```zig
for (zigui.input_events()) |ev| switch (ev) {
    .motion => |m| send_motion(m.dx, m.dy),
    .key => |k| send_key(k.scancode, k.down, k.repeat, k.mods),
    .button => |b| send_button(b.button, b.down),
    .wheel => |w| send_wheel(w.dx, w.dy),
};
```

| `InputEvent` arm | Fields |
|---|---|
| `motion` | `dx`, `dy` - a delta, not a position |
| `key` | `scancode: u16`, `down: bool`, `repeat: bool`, `mods: Mods` |
| `button` | `button: Button`, `down: bool`, `mods: Mods` |
| `wheel` | `dx`, `dy` |

`Button` is `left` \| `right` \| `middle` \| `other`. Scancodes are physical, so
they don't depend on the keyboard layout - the far end maps them to its own.

`Mods` is a packed `u16` that keeps left and right modifiers apart, since a remote
needs to know which Shift or Control went down:

```
left_shift right_shift  left_control right_control
left_option right_option  left_command right_command  caps_lock
```

## Keyboard shortcuts

Outside a grab, read app-level key presses with the cursor free:

```zig
for (zigui.key_presses()) |k| {
    if (k.mods.cmd and k.code == .char and k.ch == 's') save(app);
    if (k.code == .escape) close_panel(app);
}
```

`key_presses()` returns this frame's `[]const KeyEvent`. It is the shortcut path -
a focused text field still gets its own typing. (`input_events()` only fills under
`grab()`.)

| `KeyEvent` field | Type | Meaning |
|---|---|---|
| `code` | `KeyCode` | `.char`, or a named key |
| `ch` | `u21` | the codepoint, when `code == .char` |
| `mods` | `KeyMods` | `cmd`, `shift`, `alt`, `ctrl` (semantic, not left/right) |

`KeyCode` is `char`, `left`, `right`, `up`, `down`, `backspace`, `delete_fwd`,
`enter`, `tab`, `escape`, `home`, `end`, `page_up`, `page_down` - logical keys,
unlike the physical `scancode` on the grab path.

## File drop

Files dragged from the OS file manager onto the window land here (macOS, Windows,
and X11 XDND):

```zig
if (zigui.dropped_files()) |drop| {
    for (drop.paths) |path| open(app, path);
}
```

`FileDrop` is `{ paths: []const []const u8, x: f32, y: f32 }` - decoded absolute
paths (valid this frame only) and the window-space drop point.

## Hover query

`rect_hovered(rect)` asks whether the pointer is over a rect this frame - a
build-time query for gating a hover popover or HUD without a callback. Pass a
node's `rect_out` from the last frame; it respects overlay hover-blocking.

```zig
if (zigui.rect_hovered(app.row_rect)) show_preview(app);
```

## Dragging nodes

Any box is draggable: set `on_drag` / `on_drag_end` on its config (see
[Layout](layout.md)). The handler gets a window-space `(x, y)`; a drag supersedes
`on_click`, so treat a no-movement release in `on_drag_end` as a plain click. For
a ready-made divider between panes, reach for `zigui.resize_handle` (see
[kit/containers](kit/containers.md)).

## Text-field completion

A focused single-line field (`text_input`) can drive an inline completion popup -
a `{{var}}` menu, an autocomplete. The field owns typing; these seams let app UI
read around the caret and inject an accepted completion. Overlay backends (Linux)
report the caret; native-painted fields (macOS / Windows) fill what their native
editor supports.

| Fn | What it does |
|---|---|
| `text_field_caret()` | focused field's caret byte offset (`0` off Linux) |
| `text_field_value(buf)` | copy the focused field's live value into `buf` (empty when none) |
| `text_field_special()` | the special key (`?FieldKey`) the field saw but did not act on |
| `set_field_intercept(active)` | while active, the field forwards Up/Down/Tab as `text_field_special` so a popup drives its selection |
| `text_field_replace(a, b, bytes)` | replace bytes `[a, b)` of the field (accept a completion); the caret lands after |

`FieldKey` is `enum { enter, shift_enter, escape, up, down, tab }`. Open the popup
when the text before the caret matches a trigger, call `set_field_intercept(true)`,
route `text_field_special()` to its selection, commit with `text_field_replace`,
and turn intercept off when it closes. The multiline `textarea` has its own
`Completion` / `Snippet` hooks - see [kit/inputs](kit/inputs.md).
