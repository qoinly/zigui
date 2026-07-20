# Display

Read-only widgets: a label, a status chip, a glyph, a divider, a loading
placeholder, a key cap, a progress bar, a spinner. All stateless - pass values,
get a `*Node`. No allocator, no theme, no context; the frame supplies them.

- [badge](#badge)
- [avatar](#avatar)
- [image](#image)
- [icon](#icon)
- [separator](#separator)
- [skeleton](#skeleton)
- [kbd](#kbd)
- [progress](#progress)
- [spinner](#spinner)

## badge

A small status or count label.

```zig
zigui.badge("New", .default)
zigui.badge("99+", .destructive)
```

```zig
fn badge(label: []const u8, variant: zigui.kit.Variant) *Node
```

`variant` is positional, not an options struct. `Variant`:

| Variant | Meaning |
| --- | --- |
| `.default` | Solid primary fill. |
| `.secondary` | Muted fill. |
| `.destructive` | Red fill. |
| `.outline` | Background fill with a border. |
| `.ghost` | Transparent; text only. |
| `.link` | Transparent; primary-colored text. |

## avatar

A user's initials in a circle - a text fallback when there is no image.

```zig
zigui.avatar("OM", 36)
```

```zig
fn avatar(initials: []const u8, size: f32) *Node
```

`size` is the circle diameter in points. Pass one or two letters; the kit centers
them and sizes the text to the circle.

## image

A decoded PNG or baseline JPEG, drawn as a node - a real avatar photo, a logo, an
illustration. Decode once into an App-owned `ImageSource`, then reference it; the
texture uploads lazily and a still image never re-renders on its own.

```zig
const App = struct { photo: zigui.ImageSource };

app.photo = try zigui.ImageSource.decode(gpa, @embedFile("me.png"));
defer app.photo.deinit();

zigui.image(&app.photo, .{ .fit = .cover })
```

```zig
fn image(source: *zigui.ImageSource, opts: zigui.FrameOpts) *Node
```

It fills its cell and fits per `opts.fit` (`.contain` default). `image` shares
`FrameOpts` / `FrameFit` with live frames - see [External frames](../frames.md)
for the `ImageSource` methods, the decode/upload details, and the fit table.

## icon

One glyph from the portable `Icon` enum.

```zig
zigui.icon(.search, .{})
zigui.icon(.trash, .{ .size = 22, .color = t.destructive })
```

```zig
fn icon(ic: zigui.Icon, opts: zigui.IconOpts) *Node
```

`Icon` is an enum - the only way to name an icon. It maps to a per-platform glyph.
Some members:

```zig
.search  .gear  .bell  .info  .warning  .trash  .folder
.chevron_down  .arrow_right  .plus  .check  .close  .heart  .copy
```

`*_fill` members (`.gear_fill`, `.check_circle_fill`, ...) are native-only. The
full list is in `src/icon.zig`.

### IconOpts

| Option | Type | Default | Meaning |
| --- | --- | --- | --- |
| `size` | `f32` | `16` | Point size; the node reserves a square slot this wide. |
| `color` | `Rgba` | `{ 1, 1, 1, 1 }` | Tint. Pass a theme color (e.g. `t.foreground`). |
| `source` | `?IconSource` | `null` | Where the glyph comes from. `null` uses the engine default. |

`IconSource`:

| Source | Meaning |
| --- | --- |
| `.native` | The OS's own set (SF Symbols on macOS). |
| `.bundled` | Lucide, the same glyph on every platform. |

A member with no glyph in the chosen source logs one dev warning and draws nothing
(e.g. a `*_fill` member under `.bundled`, since Lucide is stroke-only).

## separator

A hairline divider.

```zig
zigui.separator(.horizontal)
zigui.separator(.vertical)
```

```zig
fn separator(orientation: zigui.kit.separator.Orientation) *Node
```

`Orientation` is `.horizontal` or `.vertical`. The hairline is 0 on its long axis -
it fills the container's cross axis via stretch (horizontal in a `col`, vertical in
a `row`). Put it in a sized parent or it has nothing to fill.

## skeleton

A loading placeholder block.

```zig
zigui.skeleton(40, 40, 20)   // a circle stand-in (radius = half the side)
zigui.skeleton(180, 12, 4)   // a text-line stand-in
```

```zig
fn skeleton(w: f32, h: f32, radius: f32) *Node
```

All three are points: width, height, corner radius.

## kbd

A keyboard key cap, or a combo of them.

```zig
zigui.kbd(&.{"Esc"})
zigui.kbd(&.{ zigui.key_command, "K" })
zigui.kbd(&.{ zigui.key_command, zigui.key_shift, "P" })
```

```zig
fn kbd(keys: []const []const u8) *Node
```

Each string is one cap, drawn left to right. Use the platform modifier constants
instead of a hardcoded glyph so the combo reads right on each OS:

| Constant | macOS | Elsewhere |
| --- | --- | --- |
| `zigui.key_command` | the Command sign | `Ctrl` |
| `zigui.key_shift` | the Shift sign | `Shift` |
| `zigui.key_option` | the Option sign | `Alt` |
| `zigui.key_return` | the Return sign | `Enter` |

The key strings are borrowed by pointer and must outlive the frame - string
literals are static, so a `&.{ ... }` call site is safe.

## progress

A horizontal progress bar.

```zig
zigui.progress(0.65, 8)        // 65%, 8pt thick
zigui.progress_indeterminate(8) // unknown duration
```

```zig
fn progress(value: f32, height: f32) *Node
fn progress_indeterminate(height: f32) *Node
```

`value` is `0..1`; `height` is the bar thickness in points. The track is 0 wide and
fills its parent via cross-stretch - put it in a `col` or a width-sized box.
`progress_indeterminate` runs a sweeping bar (it self-drives the redraw loop).

## spinner

An indeterminate loading indicator. Self-animates - it keeps the frame loop
ticking on its own, no `animate()` needed.

```zig
zigui.spinner(8, t.primary)
zigui.spinner(16, t.muted_foreground)
```

```zig
fn spinner(radius: f32, c: zigui.Rgba) *Node
```

`radius` is the ring radius in points; `c` is the dot color. Pass a theme color.
