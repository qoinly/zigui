# Feedback

Surfaces that talk back to the user: a callout (`alert`), a brief floating
notice (`toast`), and a hover hint (`tooltip`). Toast and tooltip do not nest
in the body - they ride the non-modal `hud` region so they float over
everything without ever blocking body hover. Alert is a plain inline node.

## alert

A callout card. Inline node - nest it in `col` / `row` like any other.

```zig
zigui.alert("Heads up!", .{ .description = "Add components with the CLI.", .icon = .info })
```

`alert(title: []const u8, o: AlertOpts) -> *Node`

| Option | Type | Default | Meaning |
|---|---|---|---|
| `description` | `[]const u8` | `""` | Second line under the title; empty = title-only card |
| `variant` | `AlertVariant` | `.default` | `default` or `destructive` (destructive tints title + border) |
| `icon` | `?Icon` | `.info` | Leading glyph; `null` drops the icon column |

The card fills its parent's width and sizes its own height (48 plain, 70 with a
description). Cap it with a container `max_width`:

```zig
zigui.col(.{ .gap = .md, .max_width = 520 }, &.{
    zigui.alert("Heads up!", .{
        .description = "Add components with the CLI.",
        .icon = .info,
    }),
    zigui.alert("Error", .{
        .description = "Your session has expired.",
        .variant = .destructive,
        .icon = .warning,
    }),
    zigui.alert("Update available", .{ .icon = .arrow_down_circle }),
})
```

## toast

A brief, auto-dismissing notice. It floats bottom-right and self-expires off
the frame clock - no dismiss button, no hitboxes. The `toasts` node draws the
whole stack; you own the slot array and push into it from a callback.

`toasts(o: ToastsOpts) -> *Node`

| Option | Type | Default | Meaning |
|---|---|---|---|
| `slots` | `[]ToastSlot` | (required) | Caller-owned, cross-frame; one entry per concurrent toast |
| `bottom_inset` | `f32` | `0` | Extra space reserved at the bottom of the hud, so the stack floats above a footer / status bar the hud draws over |

Long lines don't overflow: the toast title and description are clamped to the
card's inner width and ellipsized.

`ToastSlot`:

| Field | Type | Default | Meaning |
|---|---|---|---|
| `active` | `bool` | `false` | Slot is live; the node draws it and times it out |
| `started` | `bool` | `false` | Stamped on first render (a click has no frame clock) |
| `start_s` | `f64` | `0` | Wall-clock start, set when `started` flips |
| `text` | `[]const u8` | `""` | The line shown; a static literal - the slot borrows it across frames |
| `variant` | `ToastVariant` | `.default` | `default`, `success`, or `destructive` (sets accent + leading icon) |

`ToastVariant` = `{ default, success, destructive }`.

### Wiring

The slot array lives in your state, sized to the max concurrent toasts. A
helper pushes into the first free slot:

```zig
pub const App = struct {
    toasts: [3]zigui.ToastSlot = .{ .{}, .{}, .{} },

    // text must be a static literal - the slot borrows it across frames.
    pub fn toast(self: *App, text: []const u8, variant: zigui.ToastVariant) void {
        for (&self.toasts) |*s| {
            if (!s.active) {
                s.* = .{ .active = true, .text = text, .variant = variant };
                return;
            }
        }
        self.toasts[0] = .{ .active = true, .text = text, .variant = variant };
    }
};
```

Push from any callback:

```zig
fn show_default(app: *App) void { app.toast("Event has been created", .default); }
fn show_success(app: *App) void { app.toast("Your changes were saved", .success); }
fn show_error(app: *App)   void { app.toast("Something went wrong", .destructive); }

// in a view:
zigui.button("Show toast", .{ .on_click = zigui.on(App, show_default) })
```

Draw the stack in the `hud` view (the non-modal top layer - see
[App & window](../app-window.md)). Only emit the node while a slot is live, so
the layer is empty otherwise:

```zig
pub fn hud(f: *zigui.Frame, app: *App) ?*zigui.Node {
    _ = f;
    for (app.toasts) |s| {
        if (s.active) return zigui.toasts(.{ .slots = &app.toasts });
    }
    return null;
}
```

Register it on `run`:

```zig
try app.run(&state, .{ .body = App.view, .hud = hud });
```

The node keeps the loop ticking while any toast lives, so the fade in/out and
the timeout animate without an `animate()` call.

## tooltip

A hover hint anchored above a trigger. Like toast, it rides the `hud` region so
the trigger underneath stays hoverable. It self-gates: the bubble draws only
while the trigger rect is hovered.

`tooltip_overlay(o: TooltipOverlayOpts) -> *Node`

| Option | Type | Default | Meaning |
|---|---|---|---|
| `text` | `[]const u8` | (required) | The hint line (must be non-empty) |
| `trigger` | `*const [4]f32` | (required) | The trigger's laid-out rect `{x, y, w, h}`, read at draw |

### Wiring

The trigger writes its laid-out box to a `[4]f32` you own via `rect_out`; the
tooltip reads that same rect to position the bubble and to hover-test. Keep the
rect in your state so it outlives the per-frame tree:

```zig
pub const App = struct {
    tip: struct { rect: [4]f32 = .{ 0, 0, 0, 0 } } = .{},
};
```

The trigger is any node with a `rect_out`. A hover-only target sets no
`on_click`:

```zig
pub fn view(f: *zigui.Frame, app: *App) *zigui.Node {
    return zigui.button("Hover me", .{ .variant = .outline, .rect_out = &app.tip.rect });
}
```

The bubble goes in the `hud` view, pointed at the same rect:

```zig
pub fn hud(f: *zigui.Frame, app: *App) ?*zigui.Node {
    _ = f;
    return zigui.tooltip_overlay(.{
        .text = "Add to library",
        .trigger = &app.tip.rect,
    });
}
```

`rect_out` is only known after layout, so the first frame's rect is zero; the
tooltip skips a zero-width trigger and shows once the rect lands.

## See also

- [App & window](../app-window.md) - the `overlay` and `hud` regions on `run`.
- [Containers](containers.md) - `dialog`, `popover`, `menu`, `sheet` (the modal
  `overlay` region).
- [Display](display.md) - `progress`, `spinner` (inline status, not feedback
  surfaces).
