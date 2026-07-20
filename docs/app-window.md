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
| `min_size` | `?[2]f32` | `null` | resize floor; null falls back to `320 x 240` |
| `theme` | `?Theme` | `null` | starting theme; null uses `default_dark` |
| `feel` | `Feel` | `.liquid_glass` | window chrome feel (see below) |
| `titlebar_height` | `?f32` | `null` | custom title-band height; null uses the platform default |

zigui draws the window chrome (the title band, traffic-light gutter, the rest);
you style the content in your tree. `feel` is `.liquid_glass` (a translucent,
blurred bar - the default), `.flat` (an opaque bar), or `.transparent` (no chrome
fill; content runs to the edges). Pass `theme` for the starting palette and
`titlebar_height` to size the band; swap the theme later with `zigui.set_theme`.

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
what callbacks receive. (On Android and iOS `run` does not block - the framework owns
the loop - so the state must outlive `main`; see [On Android](#on-android).)

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
| `hovered_id` | `[]const u8` | the topmost `hover_id` box under the pointer, for reveal-on-hover (see [Layout](layout.md)) |

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

## Window controls

Act on the window drawing the current frame:

| Fn | What it does |
|---|---|
| `minimize()` | iconify the window, as its caption button does |
| `hide()` | hide the app (macOS); elsewhere minimizes |
| `window_occluded()` | whether the window is fully hidden (covered, minimized, or on another Space) |
| `set_theme(t)` | swap the window's theme - content and chrome - at runtime; see [Theming](theming.md) |

Fullscreen and display enumeration live in [System](system.md).
`window_occluded()` pairs with `zigui.request_redraw_after`: a periodic view parks
itself while hidden and re-arms on the reveal.

## Multiple windows

Desktop only - Android and iOS are single-surface, so `open_window` and the
per-window helpers below do not apply there (see [On Android](#on-android), [On
iOS](#on-ios)).

`run` opens the first window and blocks. To open more, call `open_window` while
`run` is going (i.e. from a click). Each extra window has its own state and views;
the title, id, and size go in the options.

```zig
fn open_panel(app: *App) void {
    app.open_window(.{ .title = "Panel" }, &app.panel, .{ .body = panel_view }) catch {};
}
```

```zig
pub fn open_window(opts: WindowOptions, state, comptime views) !void
```

| `WindowOptions` | Type | Default | Meaning |
|---|---|---|---|
| `title` | `[]const u8` | `""` | empty falls back to an engine default (`Window N`) |
| `id` | `u32` | `0` | window identity; 0 lets the engine assign a fresh one |
| `size` | `?[2]f32` | `null` | null inherits the main window's size |
| `min_size` | `?[2]f32` | `null` | null inherits the main window's floor |
| `theme` | `?Theme` | `null` | starting theme; null uses `default_dark` |
| `feel` | `Feel` | `.liquid_glass` | window chrome feel (`.flat` / `.liquid_glass` / `.transparent`) |
| `titlebar_height` | `?f32` | `null` | custom title-band height |

Each window runs its own render loop and routes its own input, so callbacks reach
the right state. The shared text editor follows the key window, so typing never
crosses windows. Closing an extra window tears it down; closing the main window
quits the app.

`on_window_closed` registers a handler called when an extra window closes, so the
app can drop that window's state:

```zig
app.on_window_closed(on_closed);   // fn (?*anyopaque, id: u32) void
```

### Which window is rendering

A view shared across windows reads which one it is drawing:

| Fn | Meaning |
|---|---|
| `window_id()` | the rendering window's id (the first window is `1`) |
| `window_title()` | its title |
| `window_is_key()` | whether it holds keyboard focus |

See `examples/multiwindow_demo.zig`.

## On Android

The same `App.init` / `run` / view shape runs on Android, with a few differences
the platform forces. [docs/android.md](android.md) has the full backend guide; the
loop-side facts:

- `run` does not block. A NativeActivity hands its loop to the framework, and the
  drawing surface arrives asynchronously after `run` returns. So the app state can
  not be a `main` stack local - give it a lifetime that outlives `main` (a global,
  or heap), and do not `defer app.deinit()` to tear it down at the end of `main`.
- One surface. There is no `open_window`, no extra windows, and no `window_id` /
  `window_is_key` routing - the activity is the whole UI.
- No window chrome. There is no title band or traffic-light gutter to fill; the
  `titlebar` view is unused. `body`, `overlay`, and `hud` work as on desktop, and
  `f.body` already accounts for the system bar insets.

## On iOS

iOS behaves like [On Android](#on-android) - `run` does not return (`UIApplicationMain`
owns the loop), one fullscreen surface, no window chrome - so the same module-scope-state
rule applies. The window is scene-managed, so a rotation reflows the surface and `f.body`'s
safe-area insets follow (in landscape they move to the side). See [docs/ios.md](ios.md).

## deinit

```zig
defer app.deinit();
```

Stops the display link, closes the window, and frees what `App.init` allocated.
On Android and iOS this is a no-op parity shim (the framework owns teardown).
