# Kit

Components return `*zigui.Node`, so they nest in `col` / `row` / `grid` like any
other node. They come in two shapes: stateless and stateful.

## Stateless components

Most components hold no state - pass options, get a node:

```zig
zigui.button("Save", .{ .variant = .default, .on_click = zigui.on(App, save) })
zigui.badge("New", .secondary)
zigui.checkbox(app.agreed, "Agree", .{ .on_change = zigui.on(App, toggle_agree) })
```

No allocator, no theme, no context to pass - the frame supplies them.

## Callbacks

Interactive options take a callback that receives your app state - the same value
you passed to `run`. You write a plain `fn(*State) void` and wrap it at the call
site with `zigui.on`:

```zig
fn save(app: *App) void { app.saved = true; }

zigui.button("Save", .{ .on_click = zigui.on(App, save) })
```

`zigui.on(State, f)` wraps `fn(*State) void`. No `*anyopaque`, no manual cast -
the one cast is generated for you. Mutate your state in the callback; the next
frame's tree reflects it. `on_click` and `on_change` are the common ones.

Some callbacks carry an extra argument. Wrap those with the matching helper:

| Helper | Wraps | Used by |
| --- | --- | --- |
| `zigui.on(State, f)` | `fn(*State) void` | `on_click`, `on_change`, `on_toggle`, `on_focus`, `on_dismiss` |
| `zigui.on_id(State, f)` | `fn(*State, []const u8) void` | select / sidebar item picked (by id) |
| `zigui.on_index(State, f)` | `fn(*State, usize) void` | tabbar select / close / pin |
| `zigui.on_at(State, f)` | `fn(*State, usize, f32) void` | slider thumb moved (index + value) |
| `zigui.on_delta(State, f)` | `fn(*State, f32) void` | select dropdown scroll step |
| `zigui.on_disclose(State, f)` | `fn(*State, []const u8, bool) void` | sidebar group open / close |
| `zigui.on_drag(State, f)` | `fn(*State, f32, f32) void` | resize handle drag |
| `zigui.on_move2(State, f)` | `fn(*State, usize, usize) void` | tabbar drag-reorder (from / to) |

To forward a wrapped handler through a helper of your own, take it as
`zigui.ClickFn` (the erased type `zigui.on` returns).

## Stateful components

A few components carry transient state across frames - a text field's bytes and
focus, a dropdown's open rows, a scroll offset. You own that state: keep it in
your struct and pass a pointer.

```zig
const App = struct {
    name: zigui.TextField = .{},
    in_focus: bool = false,
    // ...
};

fn render(f: *zigui.Frame, app: *App) *zigui.Node {
    return zigui.text_input(&app.name, .{
        .focused = app.in_focus,
        .on_focus = zigui.on(App, focus_name),
    });
}
```

The state lives in your struct - no framework registry, no ids to track. Reorder
widgets freely; the pointer is the identity. Read the value back from the state:
a `TextField` slices its bytes.

```zig
const typed = app.name.slice(); // []const u8
```

The real state types:

| Component | State type (you own) | Read back |
| --- | --- | --- |
| `text_input`, `text_editable` | `zigui.TextField` | `.slice()` -> `[]const u8` |
| `textarea` | `zigui.kit.textarea.TextAreaState` | `.buf.slice()`; `.focused` is a field |
| `select` (open panel) | `zigui.kit.select.SelectState` | you own the picked id; `on_select` reports it |
| `scroll` | `zigui.ScrollState` | `.y` is the offset (px) |

`TextField` is `buf: [256]u8`, `len: usize`; `set(text)` writes it, `slice()`
reads it. `ScrollState` is `y: f32 = 0`.

Stateful kit: `text_input`, `text_editable`, `textarea`, `select`, and `scroll`.
Everything else is stateless. (`input` is the plain stateless field - you pass
`value` and `placeholder` directly, no state struct.)

## Groups

- [Actions](actions.md) - button, toggle_button
- [Inputs](inputs.md) - input, text_input, text_editable, textarea, checkbox, radio, toggle, toggle_group, slider, select, tabs
- [Display](display.md) - text, badge, avatar, icon, separator, skeleton, kbd
- [Feedback](feedback.md) - progress, spinner, alert, toasts, tooltip_overlay
- [Containers / overlays](containers.md) - dialog, sidebar, tabbar, bottom_bar, menu_overlay, select_overlay, popover_overlay, sheet
- [Charts](charts.md) - line_chart, bar_chart, donut
