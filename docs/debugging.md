# Debugging layout

zigui can tell you where everything landed. Two tools read the laid-out tree:

- **The overlay** draws an outline around every node, and can print each node's
  position and size on top of it. One screenshot then carries its own
  measurements.
- **The dump** writes one JSON line per node to the log, so you can check a
  layout as numbers instead of judging pixels.

Both exist only in Debug builds. A release build compiles them out completely.

## Turning it on

The tools are switched on while the app runs. No rebuild is needed.

```sh
# Android
adb shell setprop debug.zigui "boxes labels"

# Desktop
ZIGUI_DEBUG="boxes labels" ./zig-out/bin/app
```

The value is a list of words:

| Word | Effect |
|---|---|
| `boxes` | outline every node, colored by depth |
| `labels` | print each node's `x,y wxh` on it, and its name if it has one |
| `dump` | write the layout of the next frame to the log, once |
| `input` | write it again after every click and key press |
| `all` | `boxes`, `labels`, and `dump` |
| `off` | turn everything off |

On Android the property is read every frame, so the overlay appears on the next
redraw. Touch the screen or scroll if the app is idle.

## Reading a dump

A dump covers every region of one frame: the titlebar if the app draws one, the
body, and then the overlay and the hud if they are showing. Each region starts
with a header line, followed by one line per node in draw order (a parent before
its children).

```text
layout dump begin: 18 nodes in the region at 0.0,0.0 392.7x850.9
{"d":8,"k":"box","n":"response_fab","x":337.7,"y":722.9,"w":34.0,"h":34.0,"t":""}
{"d":5,"k":"box","n":"send_fab","x":332.7,"y":766.9,"w":44.0,"h":44.0,"t":""}
```

| Field | Meaning |
|---|---|
| `d` | depth in the tree, 0 for the region's root |
| `k` | `box` (a container), `text`, or `leaf` (a kit widget or custom drawing) |
| `n` | the node's `name`, empty if it has none |
| `x`, `y` | the top left corner, in window coordinates |
| `w`, `h` | the size |
| `t` | the text of a text node, cut to 48 characters |

Every value is in points (dp on Android), the same unit you write in `width`,
`pad`, and the other options. A screenshot is in physical pixels, so divide its
measurements by the display scale before comparing them with a dump. Positions
are where the node is drawn, after any scroll offset.

To get it:

```sh
# Android: arm it, make the app draw one frame, then read the log
adb logcat -c
adb shell setprop debug.zigui off
adb shell setprop debug.zigui dump
adb shell input swipe 500 1500 500 1400 100
adb logcat -d | grep zigui_dbg

# Desktop: the dump goes to stderr, one line per node after "zigui_dbg"
ZIGUI_DEBUG=dump ./zig-out/bin/app 2> layout.txt
grep zigui_dbg layout.txt
```

A dump fires once each time the value changes. To take another one, set the
value to something else first, as the `off` line above does.

On desktop the value comes from the environment, so it never changes while the
app runs. Add `input` to get a fresh dump after each click or key press. That
lets you click a control, for example with a synthetic click, and then read the
layout it led to:

```sh
ZIGUI_DEBUG="dump input" ./zig-out/bin/app 2> layout.txt
```

## Naming nodes

Most boxes in a dump look alike. Give the ones you care about a `name` so you
can find them:

```zig
zigui.col(.{ .name = "send_button", .width = 44, .height = 44 }, &.{ ... })
```

The name has no effect on layout or drawing, so it is fine to leave it in.

## Checking a layout with a dump

Questions like these are faster to answer from a dump than from a screenshot:

- **Are two buttons the same width?** Compare their `w`.
- **Are they centered on the same line?** Compare `x + w / 2`.
- **Is the gap right?** Take the second node's `y` minus the first node's
  `y + h`.
- **Does a title line up with the content below it?** Compare the `x` of the
  title's text node with the `x` of the box under it.

A dump shows where a box is, not what it looks like. Colors, corner radius, and
whether text is clipped still need a screenshot, and so does the ink of a glyph,
which sits slightly inside its text box.

## Testing layout without a window

`zigui.testing.Layout` lays out a tree inside a unit test, with no window, GPU,
or fonts. Build the tree with the normal builders between `begin` and `layout`,
then look the boxes up by name:

```zig
const zigui = @import("zigui");

test "the two actions split the row" {
    var t = zigui.testing.Layout.init(std.testing.allocator, 400, 100);
    defer t.deinit();
    t.begin(null); // or a pointer to your state, if the view needs it
    const root = zigui.row(.{ .gap = .{ .px = 10 } }, &.{
        zigui.col(.{ .name = "cancel", .grow = 1, .basis = 0 }, &.{}),
        zigui.col(.{ .name = "save", .grow = 1, .basis = 0 }, &.{}),
    });
    try t.layout(root);
    try std.testing.expectEqual((try t.get("cancel")).w, (try t.get("save")).w);
}
```

`get` fails the test with the missing name when no node has it. `find` returns
null instead. Every node is also in `t.rects`, in draw order.

What it does not do:

- Text is measured with a fixed width per character, not a real font. Boxes
  around text get a plausible size, so test the boxes, not the exact text width.
- Kit components are not measured. They only take the size the layout gives
  them, so put your assertions on the boxes around them.
- Scroll offsets are ignored. Positions are where nodes sit before scrolling.

## Limits

- Kit widgets are drawn as a single `leaf`, so a dump shows their outer box but
  not the parts inside them.
- A region records up to 8192 nodes. Anything past that is left out of the
  overlay and the dump.
