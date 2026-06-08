# Layout

Build structure with `col`, `row`, `grid`, and `grid_cols`; leaves are `text`,
`spacer`, and kit components. Everything returns `*zigui.Node` and nests freely.
The facade reads the per-frame context, so the builders take no allocator, theme,
or paint - just config and children.

## Containers

```zig
zigui.col(.{ .gap = .md, .pad = .lg }, &.{ a, b, c })  // vertical stack
zigui.row(.{ .gap = .sm }, &.{ a, b, c })              // horizontal stack
zigui.grid(.{ .gap = .sm }, &.{ ... })                 // greedy wrap row
```

`col` and `row` are flex containers; `grid` is a `row` with `wrap = true`. Each
takes a `Config` and a slice of children.

### Config

| Field | Type | Default | Meaning |
|---|---|---|---|
| `gap` | `Spacing` | `.none` | space between children (both axes) |
| `row_gap` | `?Spacing` | `null` | vertical gap; falls back to `gap` |
| `col_gap` | `?Spacing` | `null` | horizontal gap; falls back to `gap` |
| `pad` | `Spacing` | `.none` | inner padding, all sides |
| `grow` | `f32` | `0` | flex-grow share of leftover main-axis space |
| `width` | `?f32` | `null` | fixed width (`null` = auto) |
| `height` | `?f32` | `null` | fixed height (`null` = auto) |
| `min_width` | `?f32` | `null` | min-width clamp |
| `max_width` | `?f32` | `null` | max-width clamp |
| `wrap` | `bool` | `false` | wrap children onto the next line |
| `grid_cols` | `?GridCols` | `null` | equal-track count on a wrap row (see below) |
| `justify` | `JustifyContent` | `.flex_start` | main-axis alignment |
| `cross` | `AlignItems` | `.stretch` | cross-axis alignment (`align` is a keyword) |
| `bg` | `?Rgba` | `null` | background fill |
| `hover_bg` | `?Rgba` | `null` | fill swapped while the pointer is over the box |
| `border` | `?Rgba` | `null` | border color |
| `radius` | `f32` | `0` | corner radius |
| `border_width` | `f32` | `1` | border thickness |
| `on_click` | `?ClickFn` | `null` | click handler for the whole box |
| `rect_out` | `?*[4]f32` | `null` | laid-out abs rect, written at draw; anchor an overlay to this box |

`Spacing` is a token (`.none`, `.xs`, `.sm`, `.md`, ...) or `.{ .px = N }` for an
exact value. Use the token, not a bare number: `.pad = .lg`, not `.pad = 16`. See
[Theming](theming.md).

A box draws nothing unless it has `bg` or `border` - it is layout-only otherwise.
A clickable box (`on_click` set) gets your run state as the callback context, so
`.on_click = zigui.on(App, f)` works the same as on a button:

```zig
zigui.col(.{ .grow = 1, .on_click = zigui.on(App, blur) }, &.{ ... })
```

## Text

```zig
zigui.text("Hello", .{ .size = 16, .weight = .semi_bold })
```

| Field | Type | Default | Meaning |
|---|---|---|---|
| `size` | `f32` | `14` | font size |
| `weight` | `FontWeight` | `.normal` | `.thin` ... `.normal`, `.medium`, `.semi_bold`, `.bold` ... `.black` |
| `muted` | `bool` | `false` | resolve to `theme.muted_foreground` |
| `color` | `?Rgba` | `null` | explicit override; else muted/foreground at draw |

Text color resolves at draw time from the theme - leave `color` null to track
light/dark. Text wraps to the width it is handed by layout.

## Spacer

```zig
zigui.spacer()  // a box with grow = 1; pushes its siblings apart
```

## Scroll

A vertical scroll viewport around one child. The child keeps its natural height
and the viewport clips and offsets it. Keep one `ScrollState` per region in your
state, like the other kit states.

```zig
const App = struct { body: zigui.ScrollState = .{} };

zigui.scroll(&app.body, .{ .grow = 1 }, content)
```

### ScrollOpts

| Field | Type | Default | Meaning |
|---|---|---|---|
| `grow` | `f32` | `0` | flex-grow of the viewport |
| `width` | `?f32` | `null` | fixed viewport width |
| `height` | `?f32` | `null` | fixed viewport height |
| `bg` | `?Rgba` | `null` | viewport background |
| `bar` | `ScrollBar` | `.hidden` | `.hidden` = wheel only; `.auto` = thumb when overflowing |

## Flex

`col` / `row` are CSS-flex containers. The main axis follows the direction
(vertical for `col`, horizontal for `row`); the cross axis is the other one.

- `grow` shares leftover main-axis space (flex-grow). `0` = take only the
  intrinsic size; `1`+ = expand into the gap.
- Shrink is on by default: a row that overflows shrinks its children down to
  their min size. Pin `width` (or `min_width`) to hold a track.
- `justify` packs children along the main axis: `.flex_start`, `.flex_end`,
  `.center`, `.space_between`, `.space_around`, `.space_evenly`.
- `cross` aligns children along the cross axis: `.flex_start`, `.flex_end`,
  `.center`, `.stretch` (default), `.baseline`.

```zig
zigui.row(.{ .cross = .center, .justify = .space_between }, &.{ left, right })
```

Sizing: `width` / `height` pin a size; `min_width` / `max_width` clamp it. A
fluid track is `width = null` with `min_width` / `max_width` to bound it between
two widths.

## Grids

Two ways to lay children out in a grid - both are wrap rows.

### Greedy: `grid`

`grid` wraps children by width. Each child sizes itself and flows onto the next
line when it runs out of room. No fixed column count.

```zig
zigui.grid(.{ .gap = .md }, &.{ a, b, c, d })
```

### Responsive: `grid_cols`

`grid_cols` slices the row into N equal tracks, with N resolved per frame from
the container width. Each child fills one track. The column count is fixed per
breakpoint, not greedy.

```zig
zigui.grid_cols(.{ .base = 1, .sm = 2, .md = 4 }, .{ .gap = .md }, &.{ a, b, c, d })
```

`GridCols` cascades like Tailwind - the widest matching breakpoint wins, floored
at 1 column:

| Field | Type | Default |
|---|---|---|
| `base` | `u8` | `1` |
| `sm` | `?u8` | `null` |
| `md` | `?u8` | `null` |
| `lg` | `?u8` | `null` |
| `xl` | `?u8` | `null` |

Breakpoints key on the container width: `sm` 640, `md` 768, `lg` 1024, `xl` 1280
(px). An undefined breakpoint holds the last defined one. The example above is 1
column under 640px, 2 from 640px, 4 from 768px up.

## Spacing tokens

`Spacing` resolves to pixels:

| Token | px |
|---|---|
| `.none` | `0` |
| `.xs` | `4` |
| `.sm` | `8` |
| `.md` | `12` |
| `.lg` | `16` |
| `.xl` | `24` |
| `.xxl` | `32` |
| `.{ .px = N }` | `N` (exact escape) |

## Responsive

Resolve sizes against the current frame width (`f.size.width`):

```zig
.size = zigui.fluid(f.size.width, 320, 1280, 14, 22) // 14 at 320px -> 22 at 1280px
```

- `fluid(width, w0, w1, lo, hi)` clamps + lerps `lo..hi` as the width moves
  `w0..w1` (asserts `w1 > w0`).
- `bp(width)` wraps a width for breakpoint queries: `.at()`, `.ge(bp)`,
  `.lt(bp)`, `.min(edge)` over `base` / `sm` / `md` / `lg` / `xl`.

For a responsive column count, prefer `grid_cols` over hand-branching on `bp`.
