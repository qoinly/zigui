# Input capture

While a window is *grabbed*, zigui hides the cursor and reports raw input -
relative motion, physical key scancodes, buttons, wheel - instead of sending it to
the UI. A remote-control loop forwards this over a wire; a game uses it for
mouselook.

You get the raw events; what you send and how is up to you. No special permission
is needed. See `examples/input_demo.zig`.

## Grab

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
