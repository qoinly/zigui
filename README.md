<p align="center">
  <img src="assets/logo.svg" alt="zigui" width="220">
</p>

<p align="center">
  Yet another GUI library for Zig, but cross-platform and GPU-rendered. (early stage)
</p>

## Requirements

- Zig 0.16.0
- macOS (Metal), Windows (Direct3D 11), Linux (Vulkan; Wayland or X11),
  Android (Vulkan; min API 26), or iOS (Metal; min 15.0, Simulator)

## Install

Add zigui to your project:

```sh
zig fetch --save git+https://github.com/qoinly/zigui
```

Wire the module into your exe in `build.zig` (it carries its own platform links,
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

Or scaffold a fresh project (desktop, android, ios, or a mix) with the CLI - it writes
the build files and a starter `main.zig` for you:

```sh
zig build cli                                  # builds zig-out/bin/zigui
zigui create myapp --target desktop,ios
```

See [docs/cli.md](docs/cli.md).

A consumer `build.zig` declares its targets with one `zigui.app` call; the engine wires
a build step per platform (`zig build desktop|android|ios`) and one run dispatcher
(`zig build run -- <platform> [device]`). Android packages a signed APK (the app writes
no Java - zigui ships its own activity under `io.qoinly.zigui`); iOS assembles a `.app`
for the Simulator. See [docs/android.md](docs/android.md) and [docs/ios.md](docs/ios.md)
for each toolchain.

## Docs

The API docs live in [docs/](docs/README.md) - app & window, layout, theming, the
kit, rendering, plus external frames, input capture, and system integration
(clipboard, fullscreen, displays). [docs/android.md](docs/android.md) and
[docs/ios.md](docs/ios.md) cover the mobile backends, and [docs/cli.md](docs/cli.md)
the project-scaffolding CLI.

## Build from source

```sh
zig build        # build the library
zig build test   # run the tests

cd examples/showcase && zig build run   # the demo app
```

The desktop demo doubles as the visual reference. `examples/android-app` and
`examples/ios-app` are the mobile counterparts - `zig build android` / `zig build ios`
build them (see [docs/android.md](docs/android.md), [docs/ios.md](docs/ios.md)).

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
  resize), `tabbar` (closeable, reorderable, pinnable), `bottom_bar` (mobile
  nav, standard + floating)
- **Charts** - `line_chart` (curve, fill, gradient, stacked, dots),
  `bar_chart` (grouped, stacked), `donut`

## Status

| Platform | Status | Renderer |
|---|---|---|
| macOS | works | Metal |
| Windows | works | Direct3D 11 |
| Linux | works | Vulkan (Wayland + X11) |
| Android | works | Vulkan (NativeActivity) |
| iOS | works | Metal (Simulator) |

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
  caption buttons on Windows and Linux, drag-to-move, double-click zoom.
- Multiple windows, each with its own state, render loop, and input routing.
- External frames: draw a decoded video / remote screen as a node (NV12,
  YUV->RGB on the GPU; zero-copy import on macOS, Windows, and Linux).
- Input capture: grab the mouse and keyboard for raw relative motion + scancodes.
- System integration: clipboard read/write + change-notify, native fullscreen, and
  display enumeration.
- SF Symbols on macOS, with a bundled Lucide fallback. Over 100 icon names
  resolve on either path.
- Android: the same kit renders through Vulkan with touch input and a soft
  keyboard, and a native-API surface (notifications, toasts, clipboard, haptics,
  battery and connectivity, brightness and orientation, links and share, file
  picker, biometric prompt, accessibility, notification listener, broadcasts, and
  SMS) reaches the platform through a shipped Java shell - the app writes no Java.
  Plus off-UI-thread background work and headless background events (a Zig handler
  runs on a notification or a manifest broadcast even when the app is closed).
- iOS: the same kit renders through Metal with touch input and a native-API surface
  (notifications + toasts, clipboard, haptics, battery and connectivity, status-bar
  style, immersive mode, orientation lock, brightness, links and share, file picker,
  Face ID, runtime permissions, SMS compose), reached through the shared Objective-C
  runtime - no Swift, no `.m`. The window is scene-managed, so a rotation reflows the
  surface and the safe area.

## Limitations

- On Windows, native file dialogs and the detached-panel helpers aren't there yet.
- On Linux, fractional display scaling falls back to the nearest integer factor.
- On Android and iOS there is one fullscreen surface: no extra windows, no custom
  chrome, and `app.run` hands the loop to the framework (it never returns), so the
  app state must outlive `main`. See [docs/android.md](docs/android.md),
  [docs/ios.md](docs/ios.md).
- iOS ships for the Simulator only; a real-device build (code signing + `devicectl`)
  is not wired up yet.
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

## Acknowledgments

Thanks to the projects zigui learned from:

- [GPUI](https://www.gpui.rs/) and [GPUI Component](https://github.com/longbridge/gpui-component) -
  the GPU rendering approach and the component kit.
- [shadcn/ui](https://ui.shadcn.com/) - the design we based ours on.
- [Clay](https://github.com/nicbarker/clay) - the inspiration for the
  immediate-mode layout.
- [Lucide](https://lucide.dev/) - the bundled icons, used under the
  [ISC license](https://github.com/lucide-icons/lucide/blob/main/LICENSE).

## License

[MIT](LICENSE). Bundled Lucide icons are ISC - see Acknowledgments.
