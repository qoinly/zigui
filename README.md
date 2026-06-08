<p align="center">
  <img src="assets/logo.svg" alt="zigui" width="220">
</p>

<p align="center">
  Yet another native GUI library for Zig, but cross-platform. (early stage, macOS first)
</p>

## Requirements

- Zig 0.16.0
- macOS (Metal). Windows in progress.

## Install

Add zigui to your project:

```sh
zig fetch --save git+https://github.com/qoinly/zigui
```

Wire the module into your exe in `build.zig` (it carries its own framework links,
so you do not repeat them):

```zig
const zigui = b.dependency("zigui", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("zigui", zigui.module("zigui"));
```

```zig
const zigui = @import("zigui");
```

## Docs

The API docs live in [docs/](docs/README.md) - app & window, layout, theming,
the kit, and rendering.

## Build from source

```sh
zig build        # build the library
zig build test   # run the tests

cd examples/showcase && zig build run   # the demo app
```

## Components

Everything returns `*Node` and nests. Full APIs in [docs/kit](docs/kit/overview.md).

- **Structure** - `col`, `row`, `grid` (greedy wrap), `grid_cols` (responsive
  column tracks), `text`, `spacer`, `scroll`
- **Actions** - `button` (variants, sizes, icon, loading), `toggle_button`
- **Inputs** - `input`, `text_input` (native editor), `text_editable`,
  `textarea` (soft-wrap, syntax spans), `checkbox`, `radio`, `toggle`,
  `toggle_group`, `slider` (multi-thumb), `select` (+ `select_overlay` with
  search and groups), `tabs`
- **Display** - `badge`, `avatar`, `icon`, `separator`, `skeleton`, `kbd`,
  `progress` (+ indeterminate), `spinner`
- **Feedback** - `alert`, `toasts` (auto-dismiss stack), `tooltip_overlay`
- **Containers / overlays** - `dialog`, `sheet` (edge slide),
  `popover_overlay`, `menu_overlay` (submenus), `sidebar` (disclosure tree,
  resize), `tabbar` (closeable, reorderable, pinnable)
- **Charts** - `line_chart` (curve, fill, gradient, stacked, dots),
  `bar_chart` (grouped, stacked), `donut`

## Status

| Platform | Status | Renderer |
|---|---|---|
| macOS | works | Metal |
| Windows | partial | Direct3D 11 |
| Linux | not started | - |

What works:

- GPU rendering with batched primitives (quads, lines, polylines, rings) and
  per-instance clipping.
- Flexbox layout: direction, grow, wrap, justify, align, gap, pad. Plus
  `grid_cols` with `sm`/`md`/`lg`/`xl` breakpoints and fluid scaling. The
  breakpoints key off the container width, not the viewport.
- Dark and light themes from a token set. Call sites pull colours and spacing
  from the theme instead of hardcoding values.
- Native text editing. `input` and `textarea` get soft-wrap, caret follow,
  undo/redo, and focus routing to a native editor.
- Wheel scrolling, auto-hide scrollbars, and per-region scroll state.
- Four render regions (body, titlebar, modal overlay, non-modal hud) with
  depth-ordered hit-testing and drag capture.
- Overlays - dialog, sheet, popover, nested menus - drawn over a blurred backdrop.
- Custom window chrome: painted title band, native traffic lights on macOS,
  drag-to-move, double-click zoom.
- SF Symbols on macOS, with a bundled Lucide fallback. Over 100 icon names
  resolve on either path.

## Limitations

- Platforms: macOS is the only one that's solid. Windows is partial - the
  custom chrome works, but the native window, sidebar, toolbar, and file-dialog
  APIs are stubs. No Linux.
- One window per process. Core state is process-global, so there's no
  multi-window.
- No accessibility. Nothing wires up VoiceOver or NSAccessibility roles and
  labels.
- Text is BMP only. No IME composition (so no CJK input), no emoji or colour
  glyphs, no bidi/RTL.
- Some layout props are declared but do nothing - `position: absolute` + `inset`,
  `overflow` clipping, `margin`, percent padding/gap, baseline align, and
  `wrap_reverse` all silently no-op.
- A few things are capped: geometry batches, layout depth (64), and flex
  children per line (128). Go over and release builds drop the excess without
  warning.

## License

[MIT](LICENSE).
