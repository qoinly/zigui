# zigui

zigui draws native UI on the GPU. You build a tree of nodes and return it from a
view function; zigui lays it out and draws it. The tree is rebuilt every frame, so
the UI is always a function of your state.

macOS, Windows, Linux, and Android. Zig 0.16.0.

## A window

```zig
const zigui = @import("zigui");

const App = struct {
    clicks: u32 = 0,
};

pub fn main() !void {
    var state: App = .{};
    var app = try zigui.App.init(.{ .title = "Hello", .size = .{ 800, 600 } });
    defer app.deinit();
    try app.run(&state, .{ .body = render });
}

fn render(f: *zigui.Frame, app: *App) *zigui.Node {
    _ = f;
    return zigui.col(.{ .pad = .lg, .gap = .md }, &.{
        zigui.text("Hello, zigui.", .{ .size = 28 }),
        zigui.text("clicks: -", .{ .muted = true }),
        zigui.button("Click me", .{ .on_click = zigui.on(App, on_click) }),
    });
}

fn on_click(app: *App) void {
    app.clicks += 1;
}
```

- `App.init(.{ .title, .size, .min_size })` opens the window. `size` is
  `[2]f32` and required; `min_size` is optional.
- `app.run(state, views)` loops until the window closes. `views` is a struct;
  `body` is required, `titlebar` / `overlay` / `hud` are optional.
- `state` is `void` or a pointer to your own struct. Mutate it in callbacks,
  read it in the views.
- A view is `fn (*zigui.Frame, State) *zigui.Node` and returns the whole tree
  for that frame.

Callbacks are not bare functions. Wrap a `fn (*State) void` with `zigui.on`,
which generates the one cast back from the erased pointer:

```zig
.on_click = zigui.on(App, on_click)
```

Variants exist for callbacks that carry an argument: `zigui.on_id` (an id),
`zigui.on_index` (an index), `zigui.on_disclose`, `zigui.on_drag`, `zigui.on_at`.

## Building UI

- Structure: `col`, `row`, `grid`, `grid_cols`, `text`, `spacer`, `scroll`.
- Spacing on a container uses tokens, not raw numbers: `.pad = .lg`, `.gap = .md`.
  Escape to an exact value with `.{ .px = 24 }`. The scale is `.none .xs .sm
  .md .lg .xl .xxl`.
- Components: `button`, `input`, `select`, and the rest of the kit.
- Everything returns `*Node` and nests. A sidebar or toolbar is just nodes -
  rebuild the tree to change it.

## Docs

- [App & window](app-window.md) - windows, views, callbacks, multi-window
- [Layout](layout.md)
- [Theming](theming.md)
- [Kit](kit/overview.md)
- [Rendering](rendering.md)
- [External frames](frames.md) - draw a decoded video / remote screen
- [Input capture](input.md) - grab raw mouse + keyboard
- [System integration](system.md) - clipboard, fullscreen, displays
- [Android](android.md) - the Vulkan backend, the APK build, the native-API surface
- [CLI](cli.md) - scaffold a project, check the Android toolchain
