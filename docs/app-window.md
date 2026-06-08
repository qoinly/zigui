# App & window

`zigui.App.init` opens a window and returns an `app` that owns the render loop.

## App.init

```zig
var app = try zigui.App.init(.{
    .title = "My App",
    .size = .{ 1100, 720 },
    .min_size = .{ 560, 400 },
});
defer app.deinit();
```

| Option | Type | Default | Meaning |
|---|---|---|---|
| `title` | `[]const u8` | `""` | window title |
| `size` | `[2]f32` | required | initial logical size; asserts both `> 0` |
| `min_size` | `?[2]f32` | `null` | resize floor; null falls back to `720 x 480` |

zigui draws the window chrome (the title band, traffic-light gutter, the rest);
you style the content in your tree.

## run

`run` takes your state and a `Views` struct, not a bare render fn. Each frame it
clears the engine, resets the arena, then builds the regions and draws them.

```zig
try app.run(&state, .{
    .body = render,
});
```

```zig
fn render(f: *zigui.Frame, state: *State) *zigui.Node { ... }
```

Blocks until the window closes. The view fn returns the UI tree for this frame;
the same `state` pointer you passed to `run` comes back on every call and is
what callbacks receive.

### Views

`Views` has one required region and three optional ones. Each is a view fn that
builds a node tree for its region.

| Field | Type | Default | Meaning |
|---|---|---|---|
| `body` | `fn (*Frame, State) *Node` | required | main content, below the title band |
| `titlebar` | `?fn (*Frame, State) *Node` | `null` | fills the title band (past the traffic lights) |
| `overlay` | `?fn (*Frame, State) ?*Node` | `null` | modal/anchored layer; non-null blocks the body |
| `hud` | `?fn (*Frame, State) ?*Node` | `null` | non-modal top layer; never blocks body hover |

`overlay` and `hud` return an optional node: return `null` for "nothing this
frame". A non-null `overlay` makes the body inert (no hover, covered) while it is
up - that is what dialogs, sheets, and dropdowns use. `hud` renders last over
everything (toasts, hover tooltips) and leaves body hover alone.

```zig
try app.run(&state, .{
    .body = App.view,
    .titlebar = titlebar.view,
    .overlay = overlay.view,
    .hud = hud.view,
});
```

### Frame

Passed to every view fn. Read it for layout; do not retain it - the arena resets
next frame.

| Field | Type | Meaning |
|---|---|---|
| `size` | `SizeF` | full window size |
| `body` | `BoundsF` | content rect below the title band |
| `titlebar` | `BoundsF` | title band content rect (past the traffic lights) |
| `theme` | `*const Theme` | active theme; read colours from `f.theme` |
| `arena` | `Allocator` | per-frame arena (the facade builders use it for you) |
| `time` | `f64` | monotonic seconds, for time-based animation with `zigui.animate` |

### No state

Pass `{}` and take `_: void`. `state` must be `void` or a pointer.

```zig
try app.run({}, .{ .body = hello });

fn hello(f: *zigui.Frame, _: void) *zigui.Node {
    return zigui.col(.{ .pad = .xl, .gap = .md }, &.{
        zigui.text("Hello, zigui.", .{ .size = 28 }),
    });
}
```

## Callbacks

Interactive options do not take a bare fn. Wrap a typed `fn(*State, ...)` with a
helper - the helper generates the one cast and hands the kit the state pointer
you passed to `run`.

```zig
fn save(app: *App) void { app.saved = true; }

zigui.button("Save", .{ .on_click = zigui.on(App, save) })
```

| Helper | Typed fn it takes | Used by |
|---|---|---|
| `on` | `fn (*State) void` | clicks, toggles |
| `on_id` | `fn (*State, []const u8) void` | sidebar / menu select |
| `on_index` | `fn (*State, usize) void` | tabbar select / close / pin |
| `on_at` | `fn (*State, usize, f32) void` | slider thumb (index + value) |
| `on_disclose` | `fn (*State, []const u8, bool) void` | sidebar group open/close |
| `on_drag` | `fn (*State, f32, f32) void` | resize / drag (x, y) |
| `on_delta` | `fn (*State, f32) void` | select dropdown scroll step |
| `on_move2` | `fn (*State, usize, usize) void` | tabbar drag-reorder (from, to) |

```zig
zigui.menu_overlay(.{
    .items = &items,
    .state = &app.menu.state,
    .trigger = &app.menu.rect,
    .on_select = zigui.on_id(App, on_pick),
    .on_dismiss = zigui.on(App, on_close),
})
```

## Spacing

Container `pad` / `gap` are `Spacing` tokens, not bare numbers. Use a scale name
or escape to an exact value with `.px`.

```zig
zigui.col(.{ .pad = .lg, .gap = .md }, kids)
zigui.row(.{ .pad = .{ .px = 24 } }, kids)
```

| Token | px |
|---|---|
| `.none` | 0 |
| `.xs` | 4 |
| `.sm` | 8 |
| `.md` | 12 |
| `.lg` | 16 |
| `.xl` | 24 |
| `.xxl` | 32 |
| `.px = N` | exact |

## deinit

```zig
defer app.deinit();
```

Stops the display link, closes the window, and frees what `App.init` allocated.
