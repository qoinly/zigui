# Rendering

zigui has no retained widget tree. Every frame you build a fresh `*Node` tree
from your state; zigui lays it out, draws it on the GPU, and throws the tree
away. The UI is always a pure function of your state - mutate state in a
callback, the next frame's tree reflects it.

## The frame model

```zig
fn body(f: *zigui.Frame, app: *App) *zigui.Node {
    return zigui.col(.{ .pad = .xl, .gap = .lg }, &.{
        zigui.text("Count", .{ .size = 24, .weight = .semi_bold }),
        zigui.button("Add", .{ .on_click = zigui.on(App, inc) }),
    });
}

fn inc(app: *App) void { app.count += 1; }
```

- `body(frame, state) -> *Node` returns the whole body for that frame.
- Builders (`col`, `text`, `button`, ...) take no allocator, theme, or context.
  The frame supplies all three; you pass options and children.
- The tree is built into a per-frame arena that resets after the draw. Never
  retain a `*Node` or a `*Frame` past the call - both die with the frame.

There is no diff and no reconciliation. Rebuilding is the update. Identity for
stateful widgets is the state pointer you keep in your own struct (see
[Kit](kit/overview.md)), not a tree position - reorder freely.

## The Frame

Each view fn receives a `*Frame`. Read it for layout; do not store it.

| Field | Type | Meaning |
| --- | --- | --- |
| `size` | `SizeF` | full window size |
| `body` | `BoundsF` | content rect below the title band |
| `titlebar` | `BoundsF` | title band content rect (past the traffic lights) |
| `theme` | `*const Theme` | active theme |
| `arena` | `std.mem.Allocator` | the per-frame arena |
| `time` | `f64` | monotonic seconds, for time-based animation |

## The pass pipeline

For each region `render_at` runs three passes over the tree:

1. **Shape / measure** - text reports intrinsic size through the layout engine's
   measure hook; a kit leaf pins its measured extent (a measured 0 on an axis
   means "fill this axis" and stays auto for stretch).
2. **Layout** - the flex engine computes bounds for the whole tree against the
   region rect.
3. **Draw** - walk top-down (parent before child, so z-order is correct),
   emitting quads, text, and sprites, and registering click hitboxes.

You never call the passes. `app.run` drives them every frame. The escape hatches
`zigui.render_tree` / `zigui.render_tree_at` exist for code that drives the
backend by hand, but app code does not touch them.

## Regions and render order

A window has up to four regions, each its own view fn. `app.run` takes them as a
`Views` struct:

```zig
try app.run(&state, .{
    .body = App.view,        // required
    .titlebar = titlebar.view,
    .overlay = overlay.view,
    .hud = hud.view,
});
```

| Region | Fn signature | Default | Role |
| --- | --- | --- | --- |
| `body` | `fn (*Frame, State) *Node` | required | main content, laid out in the body rect |
| `titlebar` | `fn (*Frame, State) *Node` | `null` | fills the title band (past the traffic lights) |
| `overlay` | `fn (*Frame, State) ?*Node` | `null` | modal/anchored layer; `null` = nothing floating |
| `hud` | `fn (*Frame, State) ?*Node` | `null` | non-modal top layer (toasts, tooltips) |

Build and draw order per frame: the overlay is built first to decide modality,
then titlebar, then body, then the overlay is drawn, then the hud last.

- **overlay** is modal. A non-null overlay covers the body and makes it inert -
  the body keeps rendering but stops taking hover/clicks. Use it for dialogs,
  open dropdowns (`select_overlay`, `menu_overlay`), popovers, and the modal
  `sheet`. Return `null` when nothing is up so the body stays live.
- **hud** is non-modal and drawn last over everything. It never blocks body
  hover - a tooltip needs its trigger to stay hovered to remain visible. Use it
  for `toasts` and `tooltip_overlay`.

Anchored overlays attach to a body widget through its laid-out rect. Give the
trigger a `rect_out` to capture its on-screen rect, then point the overlay's
`trigger` at the same `[4]f32`:

```zig
// body: capture the trigger rect
zigui.button("Open menu", .{ .on_click = zigui.on(App, on_open), .rect_out = &app.menu.rect });

// overlay: anchor to it
zigui.menu_overlay(.{ .items = &items, .state = &app.menu.state, .trigger = &app.menu.rect, ... });
```

## Keeping the loop ticking

The paint loop idles after a frame with no input. Anything that animates from
the clock (a spinner, a toast countdown, an easing transition) must keep the
loop awake by calling `zigui.animate()` from the view while the animation is
live:

```zig
zigui.animate(); // keep the loading spinners advancing
```

A pointer move or click already triggers a redraw, so input-driven feedback
(hover fills, chart tooltips) needs no `animate()`. Drive time-based motion off
`f.time` and call `animate()` only while the motion is in flight:

```zig
if (s.t != target) zigui.animate(); // tick only while sliding
```

## Batching (why overlays mask glyphs)

Draw output is batched: all quads draw together, all text draws together, as
separate GPU passes. Within a region this is invisible. Across the body/overlay
split it has one consequence worth knowing - a region's quads do not occlude an
earlier region's text per-node. That is exactly why a modal overlay scrims and
frosts the whole backdrop (one covering layer) instead of relying on its own
boxes to hide the body's glyphs underneath. If you compose your own floating
panel, cover the area you sit over rather than assuming a box hides text behind
it.

## See also

- [App & window](app-window.md) - `App.init`, `App.run`, the `Views` struct.
- [Layout](layout.md) - the flex/grid engine the layout pass runs.
- [Kit](kit/overview.md) - components as `*Node` leaves, callbacks, state.
