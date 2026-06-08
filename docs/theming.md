# Theming

Every color, radius, and font size comes from one `Theme` value. The app holds
it; each frame hands it to your views as `f.theme`. Components read it for you;
your own boxes pull colors off it explicitly.

```zig
fn body(f: *zigui.Frame, app: *App) *zigui.Node {
    const t = f.theme;
    return zigui.col(.{
        .pad = .lg,
        .gap = .md,
        .bg = t.card,
        .border = t.border,
        .radius = t.radius,
    }, &.{
        zigui.text("Title", .{ .size = 16, .weight = .semi_bold }),
        zigui.text("Subtitle", .{ .size = 13, .muted = true }),
    });
}
```

## Theme

`zigui.Theme` is a flat struct of `Rgba` colors plus three scalars. The palette
follows shadcn naming: a base/foreground pair per surface.

| Field | Type | Meaning |
|---|---|---|
| `background` | `Rgba` | window / page base |
| `foreground` | `Rgba` | default text on `background` |
| `card` | `Rgba` | raised surface fill |
| `card_foreground` | `Rgba` | text on a card |
| `popover` | `Rgba` | overlay / floating panel fill |
| `popover_foreground` | `Rgba` | text on a popover |
| `primary` | `Rgba` | primary action fill |
| `primary_foreground` | `Rgba` | text on `primary` |
| `secondary` | `Rgba` | secondary action fill |
| `secondary_foreground` | `Rgba` | text on `secondary` |
| `muted` | `Rgba` | muted surface fill |
| `muted_foreground` | `Rgba` | dimmed text (captions, hints) |
| `accent` | `Rgba` | hover / highlight fill |
| `accent_foreground` | `Rgba` | text on `accent` |
| `destructive` | `Rgba` | danger fill |
| `destructive_foreground` | `Rgba` | text on `destructive` |
| `success` | `Rgba` | success fill |
| `success_foreground` | `Rgba` | text on `success` |
| `border` | `Rgba` | hairline borders |
| `input` | `Rgba` | input field border / fill |
| `ring` | `Rgba` | focus ring |
| `radius` | `f32` | default corner radius (`8`) |
| `font_family` | `[]const u8` | font name (`""` = system default) |
| `font_size` | `f32` | base text size (`14`) |

`Rgba` is `{ r, g, b: f32 = 0, a: f32 = 1 }`. Build one with
`zigui.Rgba.init(r, g, b, a)`, `zigui.Rgba.from_u8(r, g, b, a)`, or
`zigui.Rgba.from_hex(0xRRGGBB)` / `from_hex(0xRRGGBBAA)`.

### Defaults

Two constructors ship; `App.init` uses `default_dark`.

```zig
const dark = zigui.Theme.default_dark();   // bg #0A0A0A, fg #FAFAFA
const light = zigui.Theme.default_light();  // bg #FFFFFF, fg #0A0A0A
```

Both set `radius = 8`, `font_size = 14`, `font_family = ""`. To customize, start
from one and override fields:

```zig
var t = zigui.Theme.default_dark();
t.primary = zigui.Rgba.from_hex(0x3B82F6);
t.radius = 10;
```

## Spacing

`gap` and `pad` take a `Spacing` token, not a raw number. The token reads intent;
`.px` escapes to an exact value.

| Token | px |
|---|---|
| `.none` | `0` |
| `.xs` | `4` |
| `.sm` | `8` |
| `.md` | `12` |
| `.lg` | `16` |
| `.xl` | `24` |
| `.xxl` | `32` |
| `.{ .px = N }` | `N` |

```zig
zigui.col(.{ .gap = .md, .pad = .lg }, &.{ ... })
zigui.row(.{ .gap = .{ .px = 24 } }, &.{ ... })
```

## Responsive

Breakpoints key on a container width (a width you pass in), not a global
viewport. Resolve against the frame: `f.size.width`.

### Breakpoints

`Breakpoint` is `{ base, sm, md, lg, xl }` at px thresholds `0 / 640 / 768 /
1024 / 1280`.

`zigui.bp(width)` wraps a width into a `Width` you can query:

| Method | Returns | Meaning |
|---|---|---|
| `.at()` | `Breakpoint` | the widest breakpoint this width reaches |
| `.ge(bp)` | `bool` | width is at or past `bp` |
| `.lt(bp)` | `bool` | width is below `bp` |
| `.min(edge)` | `bool` | width is at or past a raw px edge |

```zig
if (zigui.bp(f.size.width).ge(.md)) { ... }  // >= 768px
```

### fluid

For values that should scale smoothly (a breakpoint jump would read as a visible
step), `fluid` clamps and lerps `lo..hi` across `w0..w1`.

```zig
.size = zigui.fluid(f.size.width, 320, 1280, 14, 22)  // 14 at 320px -> 22 at 1280px
```

`fluid(width, w0, w1, lo, hi)` asserts `w1 > w0`. Outside the range it returns
`lo` (at/below `w0`) or `hi` (at/above `w1`).

### GridCols

A responsive column count for a wrap-grid, resolved per frame against the
container width. Tailwind-style cascade: the widest matching breakpoint wins;
undefined breakpoints hold the last defined value. Floored at 1.

| Field | Type | Default |
|---|---|---|
| `base` | `u8` | `1` |
| `sm` | `?u8` | `null` |
| `md` | `?u8` | `null` |
| `lg` | `?u8` | `null` |
| `xl` | `?u8` | `null` |

Pass the spec as the first arg to `grid_cols`:

```zig
zigui.grid_cols(.{ .base = 1, .sm = 2, .md = 4 }, .{ .gap = .md }, &.{ ... })
```

One tree, no caller branching: at < 640px it is 1 column, at >= 640px it is 2, at
>= 768px it is 4.

## Deriving shades

`zigui.mix(a, b, t)` blends `a` toward `b` by `t` (`0..1`) and keeps `a`'s alpha,
so a tint of an opaque token stays opaque. Mix a surface toward the foreground for
a hover or elevated shade that tracks both light and dark themes.

```zig
.bg = t.secondary,
.hover_bg = zigui.mix(t.secondary, t.foreground, 0.12),  // lift on hover
```

`mix` asserts `0 <= t <= 1`.

## How a node reads the theme

A `text` node resolves its color at draw time: an explicit `.color` override
wins, else `muted_foreground` when `.muted = true`, else `foreground`. So text
stays theme-light - you usually pass `.muted` or nothing.

```zig
zigui.text("Caption", .{ .muted = true })       // muted_foreground
zigui.text("Hot", .{ .color = t.destructive })  // explicit override
```

A box (`col` / `row` / `grid`) is the opposite: `bg`, `border`, and `hover_bg`
are explicit `Rgba`, because the view already holds the theme. A box with neither
`bg` nor `border` draws nothing - it is layout only.

```zig
zigui.col(.{
    .bg = t.card,
    .border = t.border,
    .radius = t.radius,
}, &.{ ... })
```

Pull colors at the call site so intent reads first; never inline raw RGBA where a
theme token exists.

See also: [Layout](layout.md) for `Config` / `TextOpts` fields, [Kit](kit/overview.md)
for components.
