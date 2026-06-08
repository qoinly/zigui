# Charts

Three chart leaves: `line_chart`, `bar_chart`, `donut`. Each takes its options
struct and a fixed pixel height, and returns a `*zigui.Node` you nest like any
other:

```zig
const ch = zigui.kit.chart;

zigui.line_chart(.{ .theme = f.theme, .series = &series }, 168)
```

Charts are immediate-mode leaves: they draw straight into the frame's render
buffer at the size layout gives them. You own the options - including the
theme and the data slices. The facade injects `paint` for you, so hover
tooltips work without wiring; leave the `paint` field default.

The first argument of every option struct is `theme: *const Theme`. Pass
`f.theme` from the frame. Data slices (`series`, `slices`, `labels`) are
borrowed for the frame - keep them alive in your state.

Limits: up to 8 series (`ch.MAX_SERIES`), 64 points per series
(`ch.MAX_POINTS`), 16 donut slices (`ch.MAX_SLICES`).

## Series

`line_chart` and `bar_chart` plot a slice of `Series`:

| Field | Type | Default | Meaning |
| --- | --- | --- | --- |
| `name` | `[]const u8` | `""` | Label shown in the hover tooltip |
| `color` | `Rgba` | required | Line / bar colour |
| `values` | `[]const f32` | required | One value per category |
| `point_colors` | `[]const Rgba` | `&.{}` | Per-point override (dots, mixed bars) |

```zig
const series = [_]ch.Series{
    .{ .name = "Desktop", .color = blue, .values = &.{ 186, 305, 237, 273 } },
    .{ .name = "Mobile",  .color = green, .values = &.{ 120, 190, 130, 240 } },
};
```

`labels` (on the chart options, not the series) supplies x-axis category
text. Give it one entry per category. Without it the axis is unlabelled.

## line_chart

```zig
zigui.line_chart(o: ch.LineChartOptions, height: f32) *Node
```

| Option | Type | Default | Meaning |
| --- | --- | --- | --- |
| `theme` | `*const Theme` | required | Pass `f.theme` |
| `series` | `[]const ch.Series` | required | One or more lines |
| `labels` | `[]const []const u8` | `&.{}` | X-axis category labels |
| `curve` | `ch.Curve` | `.linear` | `.linear` or `.step` |
| `fill` | `bool` | `false` | Area fill under each series |
| `gradient` | `bool` | `false` | Fade the fill toward the baseline (implies `fill`) |
| `axes` | `bool` | `false` | Draw solid left + bottom axis lines |
| `stacked` | `bool` | `false` | Stack the series' areas (implies `fill`) |
| `expand` | `bool` | `false` | Normalise each stack to 100% (implies `stacked`) |
| `dots` | `bool` | `false` | Mark each point |
| `dot_radius` | `f32` | `0` | Dot radius; `0` = default |
| `dot_hollow` | `bool` | `false` | Ring instead of solid dot |
| `point_labels` | `bool` | `false` | Print each value above its point |
| `label_color` | `?Rgba` | `null` | Override the point-label colour |
| `max` | `f32` | `0` | Fixed y-axis max; `0` = auto |
| `grid` | `bool` | `true` | Draw the y-grid + value labels |

```zig
// plain line
zigui.line_chart(.{ .theme = f.theme, .series = &series, .labels = &labels }, 168)

// gradient area
zigui.line_chart(.{
    .theme = f.theme,
    .series = &series,
    .labels = &labels,
    .fill = true,
    .gradient = true,
}, 168)

// stacked area normalised to 100%
zigui.line_chart(.{
    .theme = f.theme,
    .series = &multi,
    .labels = &labels,
    .expand = true,
}, 168)
```

Colour individual dots with `Series.point_colors`:

```zig
const dotted = [_]ch.Series{
    .{ .name = "Visitors", .color = blue, .values = &vals, .point_colors = &palette },
};
zigui.line_chart(.{ .theme = f.theme, .series = &dotted, .dots = true, .dot_radius = 4 }, 168)
```

## bar_chart

```zig
zigui.bar_chart(o: ch.BarChartOptions, height: f32) *Node
```

| Option | Type | Default | Meaning |
| --- | --- | --- | --- |
| `theme` | `*const Theme` | required | Pass `f.theme` |
| `series` | `[]const ch.Series` | required | One or more series |
| `labels` | `[]const []const u8` | `&.{}` | Category labels |
| `dir` | `ch.BarDir` | `.vertical` | `.vertical` or `.horizontal` |
| `stacked` | `bool` | `false` | Stack series; grouped side-by-side when `false` |
| `bar_labels` | `bool` | `false` | Print each value on its bar |
| `label_color` | `?Rgba` | `null` | Override the bar-label colour |
| `neg_color` | `?Rgba` | `null` | Colour for below-zero bars (else series colour) |
| `max` | `f32` | `0` | Fixed axis max; `0` = auto |
| `grid` | `bool` | `true` | Draw the grid + value labels |

```zig
// grouped vertical bars
zigui.bar_chart(.{ .theme = f.theme, .series = &multi, .labels = &labels }, 168)

// stacked horizontal
zigui.bar_chart(.{
    .theme = f.theme,
    .series = &multi,
    .labels = &labels,
    .dir = .horizontal,
    .stacked = true,
}, 168)

// negative bars in a contrast colour
zigui.bar_chart(.{
    .theme = f.theme,
    .series = &net,
    .labels = &labels,
    .neg_color = zigui.Rgba.from_hex(0xEF4444),
}, 168)
```

`point_colors` on a series gives each bar its own colour in a single-series
chart.

## donut

```zig
zigui.donut(o: ch.DonutChartOptions, height: f32) *Node
```

Slices are `ch.Slice`:

| Field | Type | Default | Meaning |
| --- | --- | --- | --- |
| `label` | `[]const u8` | `""` | Slice name (tooltip + name labels) |
| `value` | `f32` | required | Share of the whole |
| `color` | `Rgba` | required | Slice colour |

| Option | Type | Default | Meaning |
| --- | --- | --- | --- |
| `theme` | `*const Theme` | required | Pass `f.theme` |
| `slices` | `[]const ch.Slice` | required | The wedges |
| `inner_ratio` | `f32` | `0.62` | Hole size; `0` = full pie |
| `center_top` | `[]const u8` | `""` | Big number in the hole |
| `center_bottom` | `[]const u8` | `""` | Caption under it |
| `slice_labels` | `ch.SliceLabel` | `.none` | `.none`, `.name`, `.value`, `.percent` |
| `label_pos` | `ch.LabelPos` | `.inside` | `.inside` the slice, or `.outside` the rim |
| `label_lines` | `bool` | `false` | Leader line from rim to an outside label |
| `active` | `?usize` | `null` | Index of a popped-out, emphasised slice |

```zig
const slices = [_]ch.Slice{
    .{ .label = "Chrome",  .value = 275, .color = zigui.Rgba.from_hex(0x3B82F6) },
    .{ .label = "Safari",  .value = 200, .color = zigui.Rgba.from_hex(0x22C55E) },
    .{ .label = "Firefox", .value = 187, .color = zigui.Rgba.from_hex(0xF59E0B) },
};

// donut with a centre readout
zigui.donut(.{
    .theme = f.theme,
    .slices = &slices,
    .center_top = "925",
    .center_bottom = "Visitors",
}, 200)

// full pie with outside percent labels + leader lines
zigui.donut(.{
    .theme = f.theme,
    .slices = &slices,
    .inner_ratio = 0,
    .slice_labels = .percent,
    .label_pos = .outside,
    .label_lines = true,
}, 200)
```

For a clickable pie, `ch.donut_hit_test(cx, cy, size, inner_ratio, slices, mx, my)`
returns the hovered slice index; feed it back as `.active` to pop that slice.

## Hover

All three charts draw a tooltip when the pointer is over them - the facade
wires `paint` from the frame, so you get it for free. The tooltip shows the
category label as a header and one row per series (`Series.name` plus its
value); the donut shows the slice label, value, and percent. A pointer move
redraws on its own, so charts need no `zigui.animate()`.

## Layout

A chart fills the width its parent gives it and is exactly `height` pixels
tall. Wrap it in a card and let a `grid` reflow several:

```zig
zigui.grid(.{ .gap = .md }, &.{
    card(t, "Linear", zigui.line_chart(.{ .theme = t, .series = &s }, 168)),
    card(t, "Bars",   zigui.bar_chart(.{ .theme = t, .series = &s }, 168)),
})
```
