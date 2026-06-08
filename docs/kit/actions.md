# Actions

Buttons that trigger something: `button` for a one-shot action, `toggle_button`
for a two-state on/off button. Both return `*zigui.Node` and nest in `col` /
`row` / `grid` like any node. Both are stateless - pass options, get a node.

## button

```zig
zigui.button("Save", .{ .on_click = zigui.on(App, save) })
```

```zig
fn button(label: []const u8, o: ButtonOpts) *Node
```

`label` is the button text. For an icon-only button pass `""` and set
`.size = .icon` (the label is ignored there).

### ButtonOpts

| Option | Type | Default | Meaning |
|---|---|---|---|
| `variant` | `Variant` | `.default` | Visual style. See variants below. |
| `size` | `Size` | `.default` | Height + padding. See sizes below. |
| `disabled` | `bool` | `false` | Dims the button and drops its click hitbox. |
| `icon` | `?Icon` | `null` | Leading glyph. Sole content under `.size = .icon`. |
| `loading` | `bool` | `false` | Swaps a spinner in for the glyph and goes inert (no click). |
| `spin_phase` | `f32` | `0` | Caller-owned spinner rotation in cycles. The widget reads it, never advances it - see Loading. |
| `on_click` | `?ClickFn` | `null` | Fires on release. Wrap with `zigui.on`. |
| `rect_out` | `?*[4]f32` | `null` | Laid-out `{x, y, w, h}` written at draw, to anchor an overlay to the button. |

### Variant

`Variant = enum { default, secondary, destructive, outline, ghost, link }`

```zig
zigui.button("Default", .{}),
zigui.button("Secondary", .{ .variant = .secondary }),
zigui.button("Destructive", .{ .variant = .destructive }),
zigui.button("Outline", .{ .variant = .outline }),
zigui.button("Ghost", .{ .variant = .ghost }),
zigui.button("Link", .{ .variant = .link }),
```

### Size

`Size = enum { sm, default, lg, icon, icon_sm }`

```zig
zigui.button("Small", .{ .size = .sm }),
zigui.button("Default", .{ .size = .default }),
zigui.button("Large", .{ .size = .lg }),
zigui.button("", .{ .size = .icon, .icon = .plus }),
```

`.icon` and `.icon_sm` measure square and draw only the glyph - text is ignored.

### Icon

A leading glyph sits before the label. With `.size = .icon` the glyph is the
whole button.

```zig
zigui.button("Download", .{ .icon = .arrow_down_to_line }),
zigui.button("Add item", .{ .variant = .outline, .icon = .plus }),
zigui.button("", .{ .size = .icon, .icon = .plus }),
```

### Loading

`loading` shows a spinner and makes the button inert. The spinner does not turn
on its own - you own its phase and advance it each frame, then call
`zigui.animate()` so the loop keeps ticking:

```zig
const phase: f32 = @floatCast(@mod(f.time * 1.2, 1.0));
zigui.animate(); // keep the spinner advancing

zigui.button("Saving", .{ .loading = true, .spin_phase = phase }),
zigui.button("Please wait", .{
    .variant = .outline,
    .loading = true,
    .spin_phase = phase,
}),
zigui.button("", .{
    .variant = .secondary,
    .size = .icon,
    .loading = true,
    .spin_phase = phase,
}),
```

### Disabled

```zig
zigui.button("Disabled", .{ .disabled = true }),
zigui.button("Outline", .{ .variant = .outline, .disabled = true }),
```

## Callbacks

`on_click` takes a `ClickFn`. Don't pass a bare function - wrap it with
`zigui.on(State, f)`, where `State` is the type you handed to `run` and `f` is
`fn (*State) void`:

```zig
fn inc(app: *App) void {
    app.forms.counter += 1;
}

zigui.button("", .{
    .size = .icon,
    .icon = .plus,
    .on_click = zigui.on(App, inc),
}),
```

`zigui.on` generates the one `*anyopaque` cast for you; the callback receives
your live state pointer. Mutate it there and the next frame's tree reflects it.

## toggle_button

A two-state on/off button. You own the `on` flag and flip it in the callback.

```zig
zigui.toggle_button("Bold", .{
    .on = app.forms.tg_bold,
    .on_toggle = zigui.on(App, t_bold),
})
```

```zig
fn toggle_button(label: []const u8, o: ToggleButtonOpts) *Node
```

### ToggleButtonOpts

| Option | Type | Default | Meaning |
|---|---|---|---|
| `on` | `bool` | `false` | Pressed state. Caller-owned - flip it in `on_toggle`. |
| `variant` | `ToggleVariant` | `.default` | `default` or `outline` (a border ring). |
| `size` | `Size` | `.default` | Height + padding. `.icon` for icon-only. |
| `icon` | `?Icon` | `null` | Leading glyph; icon-only when the label is `""`. |
| `on_toggle` | `?ClickFn` | `null` | Fires on press. Wrap with `zigui.on`. |

`ToggleVariant = enum { default, outline }`

### Wiring

The callback flips your own flag; the next frame reads it back through `on`:

```zig
fn t_bold(app: *App) void {
    app.forms.tg_bold = !app.forms.tg_bold;
}

zigui.toggle_button("Bold", .{
    .on = app.forms.tg_bold,
    .on_toggle = zigui.on(App, t_bold),
}),
```

### Icon toggles

Pass `""` with `.size = .icon` and an `icon` for an icon-only toggle:

```zig
zigui.toggle_button("", .{
    .on = app.forms.tg_b,
    .size = .icon,
    .icon = .bold,
    .on_toggle = zigui.on(App, t_b),
}),
zigui.toggle_button("", .{
    .on = app.forms.tg_i,
    .size = .icon,
    .icon = .italic,
    .on_toggle = zigui.on(App, t_i),
}),
```
