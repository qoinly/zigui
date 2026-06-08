# Inputs

Form controls: `input` / `text_input` / `text_editable`, `textarea`, `checkbox`,
`radio`, `toggle`, `slider`, `select`. They return `*zigui.Node`, so they nest in
`col` / `row` / `grid` like any node. No allocator, theme, or paint to pass - the
frame supplies them.

Most are stateful: the cursor, focus, drag geometry, and open/closed state live in
a struct you own. Keep it in your app struct, pass a pointer, and read the value
back. The pointer is the identity - reorder widgets freely.

Callbacks are wrapped, never bare. `.on_change = zigui.on(App, f)` for a plain
click, `.on_id(App, f)` for an id, `.on_at(App, f)` for a slider's index+value,
`.on_delta(App, f)` for a scroll step. The handler takes your state by pointer:

```zig
fn toggle_terms(app: *App) void { app.cb_terms = !app.cb_terms; }
```

## Text input

Single-line field. You own a `zigui.TextField`; `text_input` draws the box and
drives the shared native editor while focused. Read the typed value with
`field.slice()`, seed it with `field.set(text)`.

```zig
const App = struct {
    name: zigui.TextField = .{},
    focused: bool = false,
};

fn focus(app: *App) void { app.focused = true; }

fn view(f: *zigui.Frame, app: *App) *zigui.Node {
    return zigui.text_input(&app.name, .{
        .placeholder = "Project name",
        .focused = app.focused,
        .id = 1,
        .on_focus = zigui.on(App, focus),
    });
}
```

`text_input(field: *TextField, o: TextInputOpts) *Node`

| Option | Type | Default | Meaning |
|---|---|---|---|
| `placeholder` | `[]const u8` | `""` | muted text shown while empty |
| `size` | `kit.Size` | `.default` | `sm`, `default`, `lg`, `icon`, `icon_sm` |
| `focused` | `bool` | `false` | drives the box ring + activates the native editor |
| `id` | `u32` | `1` | distinct per field so the singleton editor re-seeds when focus moves |
| `on_focus` | `?FocusFn` | `null` | fires on click; set your focus flag here |

The field is one editor across the app, so each `text_input` needs its own `id`.
A click that misses every field should blur - wire it on the enclosing container:

```zig
fn blur(app: *App) void { app.focused = false; }

zigui.col(.{ .grow = 1, .on_click = zigui.on(App, blur) }, &.{ ... })
```

`TextField`:

| Field | Type | Default |
|---|---|---|
| `buf` | `[256]u8` | `undefined` |
| `len` | `usize` | `0` |

Methods: `slice() []const u8` (the typed value), `set(text: []const u8) void`.

### Editable text

Click-to-edit label: idle is plain text, focused becomes an input box driving the
same native editor. Same `TextField`, same `id` rules.

`text_editable(field: *TextField, o: EditableOpts) *Node`

| Option | Type | Default | Meaning |
|---|---|---|---|
| `placeholder` | `[]const u8` | `""` | shown while empty |
| `focused` | `bool` | `false` | swaps the label for the input box |
| `id` | `u32` | `1` | per-field editor id |
| `on_focus` | `?FocusFn` | `null` | fires on click |

```zig
zigui.text_editable(&app.title, .{
    .placeholder = "Click to edit",
    .focused = app.focus == 4,
    .id = 4,
    .on_focus = zigui.on(App, focus_edit),
})
```

### Read-only / disabled input

`input` is the stateless variant: you pass the string directly, no `TextField`.
Use it for a fixed value or a disabled/invalid display.

`input(value, placeholder, size: kit.Size, w: InputWire) *Node`

| Field | Type | Default | Meaning |
|---|---|---|---|
| `on_focus` | `?FocusFn` | `null` | click report |
| `focused` | `bool` | `false` | ring + editor |
| `disabled` | `bool` | `false` | dims, suppresses the focus hitbox |
| `invalid` | `bool` | `false` | destructive border |

```zig
zigui.input("Cannot edit this", "", .default, .{ .disabled = true })
zigui.input("not-an-email", "", .default, .{ .invalid = true })
```

## Textarea

Multi-line editor that shapes its own glyphs (no native NSTextView). You own a
`zigui.kit.textarea.TextAreaState`, which holds the caret, selection, undo history,
and a `TextBuffer` pointing at your backing array. The struct can't point its
`TextBuffer` at its own bytes through a by-value init, so seed it on first render.

```zig
const ta = zigui.kit.textarea;

const App = struct {
    body: ta.TextAreaState = undefined,
    body_buf: [4096]u8 = undefined,
    seeded: bool = false,
};

fn seed(app: *App) void {
    if (app.seeded) return;
    const init = "Edit me.";
    @memcpy(app.body_buf[0..init.len], init);
    app.body = .{ .buf = .{ .bytes = &app.body_buf, .len = init.len } };
    app.seeded = true;
}

fn focus(app: *App) void { app.body.focused = true; }

fn view(f: *zigui.Frame, app: *App) *zigui.Node {
    seed(app);
    return zigui.textarea(&app.body, .{ .on_focus = zigui.on(App, focus) });
}
```

`textarea(state: *TextAreaState, o: TextAreaOpts) *Node`

| Option | Type | Default | Meaning |
|---|---|---|---|
| `spans` | `[]const TextSpan` | `&.{}` | coloured runs (a syntax highlighter); empty = plain |
| `height` | `f32` | `132` | box height; the editor scrolls internally |
| `read_only` | `bool` | `false` | view-only; keys don't mutate |
| `wrap` | `bool` | `true` | soft-wrap long lines to the view width |
| `on_focus` | `?FocusFn` | `null` | fires on click |

State you read/write directly on the struct:

| Field | Type | Meaning |
|---|---|---|
| `buf` | `TextBuffer` | the editable bytes; `buf.slice()` is the text |
| `focused` | `bool` | set it to focus; clear it (and your other areas) to blur |

`TextBuffer`: `bytes: []u8` (your backing store), `len: usize`, `edit_seq: u64`
(bumps on every edit - gate a re-tokenise on it). Methods: `slice()`,
`insert_bytes(at, text)`, `delete_range(start, end)`.

`TextSpan` for highlighting (caller sorts by `start`, non-overlapping):

| Field | Type | Default |
|---|---|---|
| `start` | `u32` | required |
| `end` | `u32` | required |
| `color` | `Rgba` | required |
| `weight` | `FontWeight` | `.normal` |

```zig
field(zigui.textarea(&app.json, .{
    .spans = app.spans[0..app.span_n],
    .on_focus = zigui.on(App, focus_json),
}))
```

## Checkbox, radio, toggle

Three stateless leaves over the same `Wire`. You hold a `bool`, pass it in, and
flip it in `on_change`. The next frame's tree reflects the new value.

```zig
zigui.checkbox(app.cb_terms, "Accept terms and conditions", .{
    .on_change = zigui.on(App, toggle_terms),
})
zigui.radio(app.pick == 0, "Default", .{ .on_change = zigui.on(App, pick0) })
zigui.toggle(app.wifi, "Wi-Fi", .{ .on_change = zigui.on(App, toggle_wifi) })
```

Signatures:

- `checkbox(checked: bool, label: []const u8, w: Wire) *Node`
- `radio(selected: bool, label: []const u8, w: Wire) *Node`
- `toggle(on: bool, label: []const u8, w: Wire) *Node` (the switch primitive)

`Wire`:

| Field | Type | Default | Meaning |
|---|---|---|---|
| `on_change` | `?ClickFn` | `null` | fires on toggle; flip your bool here |

Radio is a group by convention - one `bool` per option, derived from one selected
index. There's no group widget; you write `selected = app.pick == i`.

## Slider

Drag or click to pick values in `[0, 1]`. You own two things: a value slice (the
positions) and a `SliderState` (a per-frame geometry snapshot the drag reads -
one per slider so two never clobber each other). The kit maps the hit to the
nearest thumb and reports `(index, value)`; you store `values[index] = value`.

The value count decides the shape: one value fills `0..v`, two is a range
(`min..max`), three or more is multi-thumb.

```zig
const App = struct {
    single: [1]f32 = .{0.5},
    range: [2]f32 = .{ 0.2, 0.7 },
    st_single: zigui.kit.slider.SliderState = .{},
    st_range: zigui.kit.slider.SliderState = .{},
};

fn set_single(app: *App, i: usize, v: f32) void { app.single[i] = v; }

fn view(f: *zigui.Frame, app: *App) *zigui.Node {
    return zigui.slider(&app.single, &app.st_single, .{
        .on_change = zigui.on_at(App, set_single),
    });
}
```

`slider(values: []const f32, state: *SliderState, o: SliderOpts) *Node`

| Option | Type | Default | Meaning |
|---|---|---|---|
| `step` | `f32` | `0` | `0` = continuous; `> 0` snaps to the nearest multiple |
| `disabled` | `bool` | `false` | dims and removes the drag hitbox |
| `height` | `f32` | `22` | row height; the thumb band centers in it |
| `on_change` | `?ChangeAtFn` | `null` | wrap with `zigui.on_at(State, f)` - `fn(*State, usize, f32)` |

A 0-width leaf: it fills its parent's cross axis, so put it in a `col` or a
width-sized box. Stepped + range are just option/value changes:

```zig
zigui.slider(&app.range, &app.st_range, .{ .on_change = zigui.on_at(App, set_range) })
zigui.slider(&app.stepped, &app.st_step, .{ .step = 0.1, .on_change = zigui.on_at(App, set_step) })
```

## Select

Two parts: a trigger box (`select`) in the body, and the open dropdown panel
(`select_overlay`) in the overlay region. The trigger writes its laid-out rect to
`rect_out`; the overlay reads that rect to anchor the panel. You own the open
state, the picked value, the scroll offset, and a `SelectState`.

The trigger:

```zig
const sel = zigui.kit.select;

zigui.select(label_for(app.value), .{
    .open = app.open,
    .on_click = zigui.on(App, toggle_open),
    .rect_out = &app.rect,
})
```

`select(label: []const u8, o: SelectOpts) *Node`

| Option | Type | Default | Meaning |
|---|---|---|---|
| `open` | `bool` | `false` | ring border while the panel is up |
| `placeholder` | `bool` | `false` | render the label muted (no value picked) |
| `disabled` | `bool` | `false` | dims, suppresses the click hitbox |
| `invalid` | `bool` | `false` | destructive border |
| `on_click` | `?ClickFn` | `null` | toggle your open flag |
| `rect_out` | `?*[4]f32` | `null` | laid-out rect, written at draw; pass the overlay this same pointer |

The overlay, returned from your `overlay` view (return `null` when nothing is
open so the body stays live):

```zig
pub fn overlay(f: *zigui.Frame, app: *App) ?*zigui.Node {
    if (!app.open) return null;
    return zigui.select_overlay(.{
        .groups = &GROUPS,
        .selected_id = app.value,
        .state = &app.state,
        .trigger = &app.rect,
        .scroll = &app.scroll,
        .on_select = zigui.on_id(App, on_pick),
        .on_scroll = zigui.on_delta(App, on_step),
        .on_dismiss = zigui.on(App, on_close),
    });
}
```

`select_overlay(o: SelectOverlayOpts) *Node`

| Option | Type | Default | Meaning |
|---|---|---|---|
| `groups` | `[]const SelectGroup` | required | the option list (grouped or flat) |
| `selected_id` | `[]const u8` | `""` | id of the picked item (checkmark) |
| `state` | `*SelectState` | required | caller-owned per-select state |
| `trigger` | `*const [4]f32` | required | the trigger's `rect_out`, read at draw |
| `position` | `SelectPosition` | `.item_aligned` | `item_aligned` keeps the chosen row over the trigger; `popper` drops below |
| `scroll` | `*f32` | required | caller-owned offset; the wheel re-clamps each frame |
| `max_height` | `f32` | `280` | panel cap before it scrolls |
| `search` | `bool` | `false` | combobox: show a search field |
| `search_field` | `?*TextField` | `null` | the field backing the search, non-null only when `search` |
| `on_select` | `?SelectIdFn` | `null` | wrap with `zigui.on_id(State, f)` - `fn(*State, []const u8)` |
| `on_scroll` | `?ScrollDeltaFn` | `null` | wrap with `zigui.on_delta(State, f)` - chevron-band scroll step |
| `on_dismiss` | `?ClickFn` | `null` | outside-click close |

Items and groups:

```zig
const FRUITS = [_]sel.SelectItem{
    .{ .id = "apple", .label = "Apple" },
    .{ .id = "kale", .label = "Kale", .disabled = true },
};
const GROUPS = [_]sel.SelectGroup{ .{ .label = "Fruits", .items = &FRUITS } };
```

| Type | Fields |
|---|---|
| `SelectItem` | `id: []const u8`, `label: []const u8`, `disabled: bool = false` |
| `SelectGroup` | `label: []const u8 = ""` (empty = no header), `items: []const SelectItem` |
| `SelectState` | own one per select: `var state: sel.SelectState = .{}` |

The picked id arrives in `on_select`; store it and close:

```zig
fn on_pick(app: *App, id: []const u8) void {
    app.value = id;
    app.open = false;
}
```

## See also

- [Actions](actions.md) - `button`, `toggle_button`
- [Kit overview](overview.md) - the stateful pattern, callback wrapping
- [Containers](containers.md) - `tabs`, `sidebar`, `dialog`, and other overlays
