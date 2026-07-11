// The Node-tree DSL. Components are builder FUNCTIONS that return a *Node value;
// children are arena-owned slices passed as a nested literal. Foldable braces, no
// method chaining:
//
//   const body = col(a, .{ .gap = 16, .pad = 24 }, &.{
//       text(a, "Title", .{ .size = 22, .weight = .semi_bold }),
//       row(a, .{ .gap = 8 }, &.{
//           button_like,
//           spacer(a),
//       }),
//   });
//   try render(&eng, &b, &theme, body, viewport);
//
// Build a fresh tree into the per-frame arena each frame, lay out, draw, discard
// (the arena resets). The builders do the engine work; render() drives the passes.
// Text colour resolves at DRAW time from the theme, so builders stay theme-light;
// box bg/border are explicit Rgba (the caller already holds the theme).

const std = @import("std");
const builtin = @import("builtin");
const layout = @import("layout.zig");
const tokens = @import("theme.zig");
const styles = @import("style.zig");
const geometry = @import("geometry.zig");
const color = @import("color.zig");
const primitives = @import("primitives.zig");
const types = @import("window/types.zig");
const text_system = @import("text_system.zig");
const label = @import("render/label.zig");
const builder = @import("render/builder.zig");
const callbacks = @import("callbacks.zig");
const paint = @import("window/paint.zig");

const Style = styles.Style;
const Length = styles.Length;
const Edges = styles.Edges;
const FlexDirection = styles.FlexDirection;
const LayoutEngine = layout.LayoutEngine;
const LayoutId = layout.LayoutId;
const MAX_DEPTH = layout.MAX_LAYOUT_DEPTH;
const Quad = primitives.Quad;
const Rgba = color.Rgba;
const Theme = types.Theme;
const RenderBuilder = builder.RenderBuilder;
const RenderError = builder.RenderError;
const SizeF = geometry.SizeF;
const BoundsF = geometry.BoundsF;
const A = std.mem.Allocator;

pub const FontWeight = text_system.FontWeight;

const Kind = enum { box, text, leaf };

// A kit component as a tree leaf. measure() sizes it (it carries `b` already, so
// no engine MeasureFunc needed); draw() paints it at the laid-out rect. ctx is the
// component's Options payload, arena-owned; the @ptrCast back to its real type
// lives ONLY in the per-component adapter that paired these fns with it.
const LeafMeasure = *const fn (b: *RenderBuilder, ctx: *anyopaque) SizeF;
const LeafDraw = *const fn (b: *RenderBuilder, ctx: *anyopaque, r: BoundsF) RenderError!void;

pub const Node = struct {
    kind: Kind,
    style: Style = .{},
    // box surface (a box with neither bg nor border draws nothing - layout only)
    bg: ?Rgba = null,
    // Fill swapped in while the pointer is over the box (ghost-button-style hover
    // for a composed clickable container); null = no hover feedback.
    hover_bg: ?Rgba = null,
    border: ?Rgba = null,
    radius: f32 = 0,
    border_width: f32 = 1,
    // text (colour resolved at draw: explicit override, else muted/foreground)
    text: []const u8 = "",
    color: ?Rgba = null,
    muted: bool = false,
    font_size: f32 = 14,
    weight: FontWeight = .normal,
    // Empty = the label default (system font / theme default resolved by the
    // facade). Set to a registered family name to override per text node (mono).
    font_family: []const u8 = "",
    leaf_measure: ?LeafMeasure = null,
    leaf_draw: ?LeafDraw = null,
    leaf_ctx: *anyopaque = undefined,
    // Buttons self-wire via their own paint option (for hover); this is for plain
    // boxes/leaves.
    on_click: ?callbacks.ClickFn = null,
    click_ctx: ?*anyopaque = null,
    // A stable id recorded as "hovered" while the pointer is over this box; the
    // frame exposes the topmost one so a view can reveal-on-hover without a callback.
    hover_id: []const u8 = "",
    // A text node clamps to one line with a trailing ellipsis instead of wrapping.
    truncate: bool = false,
    // Laid-out absolute rect written at draw; lets a container anchor an overlay
    // (menu/popover) to itself, the way the kit triggers expose their rect_out.
    rect_out: ?*[4]f32 = null,
    children: []const *Node = &.{},
    // A scroll viewport: clips its child to its box and offsets it by state.y.
    scroll: ?*ScrollState = null,
    scroll_bar: ScrollBar = .hidden,
    // A slide viewport (the navigator page transition): clips its children to its box
    // and offsets them horizontally by slide_px. The children are a row of full-width
    // pages, so a negative slide_px reveals the next page. null = not a slide.
    slide_px: ?f32 = null,
    // A push transition: two full-width pages [base, pushed]; the base parallaxes left and
    // dims while pushed slides in over it. The eased progress 0..1. null = not a parallax.
    parallax_t: ?f32 = null,
    // nil until register; a stray draw before register then reads benign-empty
    // bounds instead of UB.
    id: LayoutId = LayoutId.nil,
};

// Wrap a kit component as a leaf node. The component's adapter passes its measure
// + draw thunks + the arena-stored Options pointer; this is the ONLY bridge.
pub fn leaf(a: A, m: LeafMeasure, d: LeafDraw, ctx: *anyopaque) *Node {
    return make(a, .{ .kind = .leaf, .leaf_measure = m, .leaf_draw = d, .leaf_ctx = ctx });
}

// Terse container config -> engine Style. `align` is a keyword, so the cross-axis
// field is `cross`. Spacing tokens (.gap = .md) read intent; `.px = N` escapes to
// an exact value. min/max_width feed the engine clamp (a fluid cell: .width=null
// + .min_width/.max_width to bound a flex/wrap track between two widths).
pub const Cfg = struct {
    gap: tokens.Spacing = .none,
    row_gap: ?tokens.Spacing = null,
    col_gap: ?tokens.Spacing = null,
    pad: tokens.Spacing = .none,
    grow: f32 = 0,
    width: ?f32 = null,
    height: ?f32 = null,
    min_width: ?f32 = null,
    max_width: ?f32 = null,
    wrap: bool = false,
    grid_cols: ?tokens.GridCols = null,
    justify: styles.JustifyContent = .flex_start,
    cross: styles.AlignItems = .stretch,
    bg: ?Rgba = null,
    hover_bg: ?Rgba = null,
    border: ?Rgba = null,
    radius: f32 = 0,
    border_width: f32 = 1,
    on_click: ?callbacks.ClickFn = null,
    click_ctx: ?*anyopaque = null,
    hover_id: []const u8 = "",
    rect_out: ?*[4]f32 = null,
};

pub const Txt = struct {
    size: f32 = 14,
    weight: FontWeight = .normal,
    muted: bool = false,
    color: ?Rgba = null,
    // Clamp to one line with a trailing ellipsis instead of wrapping.
    truncate: bool = false,
    // Override the font family for this text (e.g. a mono family for code/URLs).
    // Empty inherits the theme's font_family (resolved by the facade).
    font_family: []const u8 = "",
};

fn style_of(cfg: Cfg, dir: FlexDirection) Style {
    return .{
        .flex_direction = dir,
        .flex_wrap = if (cfg.wrap) .wrap else .no_wrap,
        .justify_content = cfg.justify,
        .align_items = cfg.cross,
        .flex_grow = cfg.grow,
        .width = if (cfg.width) |w| .{ .px = w } else .auto,
        .height = if (cfg.height) |h| .{ .px = h } else .auto,
        .min_width = if (cfg.min_width) |w| .{ .px = w } else .auto,
        .max_width = if (cfg.max_width) |w| .{ .px = w } else .auto,
        .row_gap = .{ .px = (cfg.row_gap orelse cfg.gap).resolve() },
        .column_gap = .{ .px = (cfg.col_gap orelse cfg.gap).resolve() },
        .padding = Edges(Length).all(.{ .px = cfg.pad.resolve() }),
        .grid_cols = cfg.grid_cols,
    };
}

// A per-frame arena create is the alloc strategy; OOM on a per-frame arena is a
// programmer error (under-sized arena), so panic rather than thread !T through
// every builder and pollute the call-site literal with `try`.
fn make(a: A, n: Node) *Node {
    const p = a.create(Node) catch @panic("node arena oom");
    p.* = n;
    return p;
}

// A `&.{...}` children literal is a STACK temporary that dies with the caller's
// expression; dupe into the arena so the returned node owns it (else it dangles).
fn own_kids(a: A, kids: []const *Node) []const *Node {
    return a.dupe(*Node, kids) catch @panic("node arena oom");
}

fn box(a: A, dir: FlexDirection, cfg: Cfg, kids: []const *Node) *Node {
    return make(a, .{
        .kind = .box,
        .style = style_of(cfg, dir),
        .bg = cfg.bg,
        .hover_bg = cfg.hover_bg,
        .border = cfg.border,
        .radius = cfg.radius,
        .border_width = cfg.border_width,
        .on_click = cfg.on_click,
        .click_ctx = cfg.click_ctx,
        .hover_id = cfg.hover_id,
        .rect_out = cfg.rect_out,
        .children = own_kids(a, kids),
    });
}

pub fn col(a: A, cfg: Cfg, kids: []const *Node) *Node {
    return box(a, .column, cfg, kids);
}

pub fn row(a: A, cfg: Cfg, kids: []const *Node) *Node {
    return box(a, .row, cfg, kids);
}

// Greedy wrap row: children size themselves and wrap by width. For a fixed or
// responsive column count, use grid_cols instead.
pub fn grid(a: A, cfg: Cfg, kids: []const *Node) *Node {
    var c = cfg;
    c.wrap = true;
    return box(a, .row, c, kids);
}

// Responsive column grid: N equal tracks resolved from the container width
// (spec.base + breakpoint overrides). Unlike grid(), the column count is fixed
// per breakpoint, not greedy; wrap is implied and each child fills one track.
pub fn grid_cols(a: A, spec: tokens.GridCols, cfg: Cfg, kids: []const *Node) *Node {
    var c = cfg;
    c.wrap = true;
    c.grid_cols = spec;
    return box(a, .row, c, kids);
}

pub fn text(a: A, s: []const u8, o: Txt) *Node {
    return make(a, .{
        .kind = .text,
        .text = s,
        .font_size = o.size,
        .weight = o.weight,
        .muted = o.muted,
        .color = o.color,
        .truncate = o.truncate,
        .font_family = o.font_family,
    });
}

pub fn spacer(a: A) *Node {
    return make(a, .{ .kind = .box, .style = .{ .flex_grow = 1 } });
}

// Caller-owned scroll position; the scroll node clamps it to the content each
// frame. Keep one per scroll region in your state, like the other kit states.
// vel/t back the iOS flick momentum + rubber-band spring (unused elsewhere).
pub const ScrollState = struct {
    y: f32 = 0,
    vel: f32 = 0, // points/sec, the coast velocity a flick leaves behind
    t_prev_s: f32 = 0, // previous frame's time, for the momentum/spring dt
};

// hidden: wheel-scrollable but no thumb drawn. auto: thumb shows while overflowing.
pub const ScrollBar = enum { hidden, auto };

pub const ScrollOpts = struct {
    grow: f32 = 0,
    width: ?f32 = null,
    height: ?f32 = null,
    bg: ?Rgba = null,
    bar: ScrollBar = .hidden,
};

// A vertical scroll viewport around `child`. The child keeps its natural height
// (flex_shrink 0, never squashed to the viewport); the node clips it to its own
// box, offsets by state.y, consumes the wheel when hovered, and (bar = .auto)
// draws a thumb once it overflows.
pub fn scroll(a: A, state: *ScrollState, o: ScrollOpts, child: *Node) *Node {
    child.style.flex_shrink = 0;
    const cfg = Cfg{ .grow = o.grow, .width = o.width, .height = o.height };
    return make(a, .{
        .kind = .box,
        .style = style_of(cfg, .column),
        .bg = o.bg,
        .scroll = state,
        .scroll_bar = o.bar,
        .children = own_kids(a, &.{child}),
    });
}

pub const SlideOpts = struct {
    // The viewport (page) width: the box clips to it and each child is pinned to it,
    // so the full-width pages line up side by side.
    width: f32,
    // Horizontal offset applied to the children before clipping; -i*width shows the
    // i-th child (the navigator slides between 2, the carousel pages across N).
    dx: f32,
};

// A horizontal slide viewport: a row of full-width page children, clipped to a
// `width`-wide box and offset by `dx`. Each child is pinned to `width` and never
// shrinks, so the pages line up and dx slides between them (the navigator transition
// uses 2; the carousel uses N). The box fills its height; the row's cross-stretch
// sizes the pages to it.
pub fn slide(a: A, o: SlideOpts, kids: []const *Node) *Node {
    std.debug.assert(o.width > 0); // the clip + the children's pinned width need a real page width
    std.debug.assert(kids.len >= 1); // a slide needs at least one page
    for (kids) |k| {
        k.style.width = .{ .px = o.width };
        k.style.flex_shrink = 0;
    }
    return make(a, .{
        .kind = .box,
        .style = style_of(.{ .grow = 1, .width = o.width }, .row),
        .slide_px = o.dx,
        .children = own_kids(a, kids),
    });
}

// A push-transition viewport: two full-width pages [base, pushed] laid side by side (the
// slide layout), but drawn with the native iOS push - the base parallaxes left and dims
// while pushed slides in over it. `t` is the eased progress (0 = base, 1 = pushed).
pub fn parallax(a: A, width: f32, t: f32, base: *Node, pushed: *Node) *Node {
    std.debug.assert(width > 0);
    std.debug.assert(t >= 0 and t <= 1);
    base.style.width = .{ .px = width };
    base.style.flex_shrink = 0;
    pushed.style.width = .{ .px = width };
    pushed.style.flex_shrink = 0;
    return make(a, .{
        .kind = .box,
        .style = style_of(.{ .grow = 1, .width = width }, .row),
        .parallax_t = t,
        .children = own_kids(a, &.{ base, pushed }),
    });
}

// ---- passes: shape (text intrinsics) -> register (build engine tree) -> draw ----
// All three recurse over children; each carries a depth bounded by the engine's
// own cap (release-safe return), single-sourced from layout.MAX_LAYOUT_DEPTH.

fn shape_text(b: *RenderBuilder, n: *Node, depth: u32) void {
    std.debug.assert(depth <= MAX_DEPTH);
    if (depth > MAX_DEPTH) return;
    switch (n.kind) {
        // Text wraps to the width it is handed at layout, so the engine
        // MeasureFunc (register_tree) reports its size - nothing to pin here.
        .text => {},
        .leaf => if (n.leaf_measure) |m| {
            // A measured 0 on an axis = "fill this axis": leave it .auto so the
            // parent's cross-stretch (or the leaf's own flex_grow) sizes it, then
            // draw() reads the laid-out extent. Pinning .px = 0 would defeat
            // stretch. A non-zero axis is intrinsic and pins exactly.
            const s = m(b, n.leaf_ctx);
            if (s.width > 0) n.style.width = .{ .px = s.width };
            if (s.height > 0) n.style.height = .{ .px = s.height };
            // An intrinsic-sized leaf is atomic: hold the pinned extent, don't let
            // a flex sibling's overflow squish it (a fixed-width sidebar must not
            // narrow because a content page reports a wide basis).
            if (s.width > 0 or s.height > 0) n.style.flex_shrink = 0;
        },
        .box => {},
    }
    for (n.children) |child| shape_text(b, child, depth + 1);
}

// The builder the engine MeasureFunc shapes text through. render_at sets it for
// the span of one synchronous layout (the UI is single-threaded; save/restore
// keeps it safe under any nesting). The text node itself is the measure ctx, so
// the hot path allocates nothing per text node.
var measure_b: ?*RenderBuilder = null;

fn text_measure(ctx: *anyopaque, proposal: geometry.SizeProposal) geometry.Size(f32) {
    const n: *Node = @ptrCast(@alignCast(ctx));
    std.debug.assert(n.kind == .text);
    const b = measure_b.?;
    var sty = label.Style{ .font_size = n.font_size, .weight = n.weight };
    if (n.font_family.len > 0) sty.font_family = n.font_family;
    if (proposal.min_content) {
        const mc = label.min_content_width(b, n.text, sty);
        const wr = label.measure_wrapped(b, n.text, sty, mc);
        return .{ .width = mc, .height = wr.height };
    }
    if (proposal.width) |w| {
        const m = label.measure_wrapped(b, n.text, sty, w);
        return .{ .width = m.width, .height = m.height };
    }
    const m = label.measure(b, n.text, sty);
    return .{ .width = m.width, .height = m.ascent + m.descent };
}

fn register_tree(eng: *LayoutEngine, n: *Node, depth: u32) RenderError!void {
    std.debug.assert(depth <= MAX_DEPTH);
    if (depth > MAX_DEPTH) return;
    if (n.kind == .text and n.text.len > 0) {
        n.id = try eng.add_node_with_measure(n.style, text_measure, n);
    } else {
        n.id = try eng.add_node(n.style);
    }
    for (n.children) |child| {
        try register_tree(eng, child, depth + 1);
        try eng.add_child(n.id, child.id);
    }
}

fn text_color(theme: *const Theme, n: *const Node) Rgba {
    if (n.color) |c| return c;
    return if (n.muted) theme.muted_foreground else theme.foreground;
}

// ox/oy translate the whole tree (engine bounds are viewport-relative; the
// caller offsets the tree below a titlebar band by passing the body origin).
fn draw_tree(
    b: *RenderBuilder,
    eng: *LayoutEngine,
    theme: *const Theme,
    n: *Node,
    depth: u32,
    ox: f32,
    oy: f32,
    pc: ?*paint.PaintContext,
) RenderError!void {
    std.debug.assert(depth <= MAX_DEPTH);
    if (depth > MAX_DEPTH) return;
    const r = eng.get_bounds(n.id);
    const x = r.origin.x + ox;
    const y = r.origin.y + oy;
    // Register the click target before recursing so a clickable child (added
    // later) wins over a clickable parent in the newest-first hit walk.
    if (pc) |p| if (n.on_click != null or n.hover_id.len > 0) {
        try p.add_hitbox(.{
            .x = x,
            .y = y,
            .w = r.size.width,
            .h = r.size.height,
            .on_click = n.on_click,
            .hover_id = n.hover_id,
            .ctx = n.click_ctx,
        });
    };
    if (n.rect_out) |ro| ro.* = .{ x, y, r.size.width, r.size.height };
    const hover_fill: ?Rgba = if (n.hover_bg) |hb| blk: {
        const on = if (pc) |p| p.is_hovered(x, y, r.size.width, r.size.height) else false;
        break :blk if (on) hb else null;
    } else null;
    switch (n.kind) {
        .box => {
            const fill = hover_fill orelse n.bg;
            if (fill != null or n.border != null) {
                var q = Quad.init(x, y, r.size.width, r.size.height);
                if (fill) |bg| _ = q.set_background(bg);
                _ = q.set_corner_radius(n.radius);
                if (n.border) |bc| _ = q.set_border_color(bc).set_border_width(n.border_width);
                try b.append_quad(q);
            }
        },
        .text => {
            var sty = label.Style{
                .font_size = n.font_size,
                .weight = n.weight,
                .color = text_color(theme, n),
            };
            if (n.font_family.len > 0) sty.font_family = n.font_family;
            if (n.truncate) {
                _ = try label.render_clamped(b, x, y, n.text, r.size.width, sty);
            } else {
                _ = try label.render_wrapped(b, x, y, n.text, sty, r.size.width);
            }
        },
        .leaf => if (n.leaf_draw) |d| {
            try d(b, n.leaf_ctx, .{ .origin = .{ .x = x, .y = y }, .size = r.size });
        },
    }
    if (n.scroll) |st| {
        const view = [4]f32{ x, y, r.size.width, r.size.height };
        try draw_scroll(b, eng, theme, n, depth, ox, oy, pc, view, st);
        return;
    }
    if (n.slide_px) |dx| {
        const view = [4]f32{ x, y, r.size.width, r.size.height };
        try draw_slide(b, eng, theme, n, depth, ox, oy, view, dx);
        return;
    }
    if (n.parallax_t) |t| {
        const view = [4]f32{ x, y, r.size.width, r.size.height };
        try draw_parallax(b, eng, theme, n, depth, ox, oy, view, t);
        return;
    }
    for (n.children) |child| try draw_tree(b, eng, theme, child, depth + 1, ox, oy, pc);
}

// The slide-viewport draw: render the page children translated by dx and clip the
// primitives they emit to the view box (the draw_scroll pattern, horizontal). Input
// is suppressed during the slide (pc = null), so a half-slid page is never clickable;
// the transition is brief and the settled page re-renders with its hitboxes.
fn draw_slide(
    b: *RenderBuilder,
    eng: *LayoutEngine,
    theme: *const Theme,
    n: *Node,
    depth: u32,
    ox: f32,
    oy: f32,
    view: [4]f32,
    dx: f32,
) RenderError!void {
    std.debug.assert(depth <= MAX_DEPTH); // the cap draw_tree relies on, before recursing
    std.debug.assert(n.children.len >= 1); // a slide always has at least one page
    std.debug.assert(view[2] >= 0 and view[3] >= 0); // the clip box never has negative extent
    const prim0 = b.prims.items.len;
    const spr0 = b.sprites.items.len;
    const cspr0 = b.color_sprites.items.len;
    for (n.children) |child| try draw_tree(b, eng, theme, child, depth + 1, ox + dx, oy, null);
    clip_since(b, view, prim0, spr0, cspr0);
}

// Clip every primitive emitted since the given buffer lengths to `view` (a slide /
// parallax viewport box), the way draw_scroll clips a scrolled child.
fn clip_since(b: *RenderBuilder, view: [4]f32, prim0: usize, spr0: usize, cspr0: usize) void {
    for (b.prims.items[prim0..]) |*p| switch (p.*) {
        inline else => |*v| {
            v.clip_bounds = clip_isect(v.clip_bounds, view);
        },
    };
    for (b.sprites.items[spr0..]) |*s| s.clip_bounds = clip_isect(s.clip_bounds, view);
    for (b.color_sprites.items[cspr0..]) |*s| s.clip_bounds = clip_isect(s.clip_bounds, view);
}

// The push-transition draw (the native iOS feel): the leaving page parallaxes ~30% left
// and dims while the arriving page slides in over it from the right, on an opaque backing
// so it hides the page behind in the overlap. `t` is the eased progress (0 = base shown,
// 1 = pushed shown). Input is suppressed mid-slide (pc = null); the settled page
// re-renders with its hitboxes.
fn draw_parallax(
    b: *RenderBuilder,
    eng: *LayoutEngine,
    theme: *const Theme,
    n: *Node,
    depth: u32,
    ox: f32,
    oy: f32,
    view: [4]f32,
    t: f32,
) RenderError!void {
    std.debug.assert(depth <= MAX_DEPTH);
    std.debug.assert(n.children.len == 2); // [base, pushed]
    std.debug.assert(view[2] >= 0 and view[3] >= 0);
    const tt = std.math.clamp(t, 0, 1);
    const w = view[2];
    // The leaving page: parallax left, then a dim deepening as the push completes.
    const p0 = b.prims.items.len;
    const s0 = b.sprites.items.len;
    const c0 = b.color_sprites.items.len;
    try draw_tree(b, eng, theme, n.children[0], depth + 1, ox - 0.3 * tt * w, oy, null);
    if (tt > 0.001) {
        var dim = Quad.init(view[0], view[1], w, view[3]);
        _ = dim.set_background(.{ .r = 0, .g = 0, .b = 0, .a = 0.28 * tt });
        try b.append_quad(dim);
    }
    clip_since(b, view, p0, s0, c0);
    // The arriving page on an opaque backing (covers the page behind in the overlap),
    // both sliding in from the right.
    const p1 = b.prims.items.len;
    const s1 = b.sprites.items.len;
    const c1 = b.color_sprites.items.len;
    const bg = theme.background;
    var back = Quad.init(view[0] + (1 - tt) * w, view[1], w, view[3]);
    _ = back.set_background(.{ .r = bg.r, .g = bg.g, .b = bg.b, .a = 1 });
    try b.append_quad(back);
    try draw_tree(b, eng, theme, n.children[1], depth + 1, ox - tt * w, oy, null);
    clip_since(b, view, p1, s1, c1);
}

fn clip_isect(a: [4]f32, c: [4]f32) [4]f32 {
    const x0 = @max(a[0], c[0]);
    const y0 = @max(a[1], c[1]);
    const x1 = @min(a[0] + a[2], c[0] + c[2]);
    const y1 = @min(a[1] + a[3], c[1] + c[3]);
    return .{ x0, y0, @max(0, x1 - x0), @max(0, y1 - y0) };
}

// iOS scroll feel tuning (points, seconds), named like the SCROLLBAR_* chrome
// constants below since they are tuned together.
const SCROLL_DT_MAX: f32 = 0.1; // a stalled frame falls back to one 60Hz step
const SCROLL_RUBBER_STIFFNESS: f32 = 4.0; // higher = the edge resists harder
const SCROLL_VEL_SMOOTH: f32 = 0.6; // EMA weight kept from the prior velocity
const SCROLL_SPRING_RATE: f32 = 16.0; // per-second pull back to the edge
const SCROLL_COAST_MIN_VEL: f32 = 12.0; // below this the coast stops (points/sec)
const SCROLL_FLICK_DECEL: f32 = 5.0; // per-second exponential decay of the coast
const SCROLL_SNAP_EPS: f32 = 0.5; // within this of the edge, snap and stop

fn scroll_overscroll(y: f32, max_y: f32) f32 {
    std.debug.assert(max_y >= 0);
    if (y < 0) return y;
    if (y > max_y) return y - max_y;
    return 0;
}

// iOS scroll feel: a flick coasts (momentum) and the edges rubber-band, then
// spring back. Run per frame off pc.now_s and the drag delta (-wheel_dy);
// animating is re-armed so the loop keeps ticking through the coast and spring.
// Other platforms keep the plain clamped drag.
fn scroll_step_ios(
    p: *paint.PaintContext,
    st: *ScrollState,
    max_y: f32,
    vh: f32,
    view: [4]f32,
) void {
    std.debug.assert(max_y >= 0);
    std.debug.assert(vh >= 0);
    const now: f32 = @floatCast(p.now_s);
    var dt = now - st.t_prev_s;
    if (!(dt > 0) or dt > SCROLL_DT_MAX) dt = 1.0 / 60.0; // first frame or a stall
    st.t_prev_s = now;
    std.debug.assert(dt > 0);

    if (p.is_hovered(view[0], view[1], view[2], view[3])) {
        const delta = -p.wheel_dy;
        const over = scroll_overscroll(st.y, max_y);
        // Past an edge the finger meets rising resistance (the rubber band).
        const damp: f32 = if (over == 0)
            1.0
        else
            1.0 / (1.0 + @abs(over) / @max(vh, 1) * SCROLL_RUBBER_STIFFNESS);
        st.y += delta * damp;
        st.vel = st.vel * SCROLL_VEL_SMOOTH + (delta / dt) * (1.0 - SCROLL_VEL_SMOOTH);
        st.y = std.math.clamp(st.y, -vh, max_y + vh); // backstop the rubber band
        return;
    }

    // Released: spring back from an overscroll, else coast on the flick velocity.
    const over = scroll_overscroll(st.y, max_y);
    if (over != 0) {
        const target = st.y - over;
        st.y += (target - st.y) * @min(@as(f32, 1.0), dt * SCROLL_SPRING_RATE);
        st.vel = 0;
        if (@abs(st.y - target) > SCROLL_SNAP_EPS) p.animating = true else st.y = target;
    } else if (@abs(st.vel) >= SCROLL_COAST_MIN_VEL) {
        st.y += st.vel * dt;
        st.vel *= @exp(-dt * SCROLL_FLICK_DECEL);
        st.y = std.math.clamp(st.y, -vh, max_y + vh);
        p.animating = true;
    } else {
        st.vel = 0;
    }
}

// The child kept its natural height (flex_shrink 0), so its laid-out height is
// the real content extent to clamp the scroll against.
fn draw_scroll(
    b: *RenderBuilder,
    eng: *LayoutEngine,
    theme: *const Theme,
    n: *Node,
    depth: u32,
    ox: f32,
    oy: f32,
    pc: ?*paint.PaintContext,
    view: [4]f32,
    st: *ScrollState,
) RenderError!void {
    std.debug.assert(depth <= MAX_DEPTH); // the cap draw_tree relies on, before recursing
    std.debug.assert(n.children.len == 1);
    const vw = view[2];
    const vh = view[3];
    std.debug.assert(vw >= 0);
    std.debug.assert(vh >= 0);
    const content_h = eng.get_bounds(n.children[0].id).size.height;
    const max_y = @max(0, content_h - vh);
    if (builtin.os.tag == .ios) {
        if (pc) |p| scroll_step_ios(p, st, max_y, vh, view);
    } else {
        if (pc) |p| if (p.is_hovered(view[0], view[1], vw, vh)) {
            st.y -= p.wheel_dy;
        };
        st.y = std.math.clamp(st.y, 0, max_y);
    }

    const prim0 = b.prims.items.len;
    const spr0 = b.sprites.items.len;
    const cspr0 = b.color_sprites.items.len;
    for (n.children) |child| try draw_tree(b, eng, theme, child, depth + 1, ox, oy - st.y, pc);
    for (b.prims.items[prim0..]) |*p| switch (p.*) {
        inline else => |*v| {
            v.clip_bounds = clip_isect(v.clip_bounds, view);
        },
    };
    for (b.sprites.items[spr0..]) |*s| s.clip_bounds = clip_isect(s.clip_bounds, view);
    for (b.color_sprites.items[cspr0..]) |*s| s.clip_bounds = clip_isect(s.clip_bounds, view);

    if (max_y > 0 and n.scroll_bar == .auto) try draw_scrollbar(b, theme, view, content_h, st.y);
}

const SCROLLBAR_W: f32 = 6;
const SCROLLBAR_INSET: f32 = 2;
const SCROLLBAR_THUMB_MIN: f32 = 24;
const SCROLLBAR_THUMB_ALPHA: f32 = 0.4; // no theme token for chrome alpha; named here

// Appended after the content clip so the thumb stays visible (unclipped).
fn draw_scrollbar(
    b: *RenderBuilder,
    theme: *const Theme,
    view: [4]f32,
    content_h: f32,
    sy: f32,
) RenderError!void {
    std.debug.assert(content_h > 0);
    std.debug.assert(view[3] >= 0);
    const vh = view[3];
    const track = @max(0, vh - SCROLLBAR_INSET * 2);
    const thumb = @max(@min(track, SCROLLBAR_THUMB_MIN), track * vh / content_h);
    const span = @max(1, content_h - vh);
    const thumb_y = view[1] + SCROLLBAR_INSET + (sy / span) * (track - thumb);
    const tx = view[0] + view[2] - SCROLLBAR_W - SCROLLBAR_INSET;
    var q = Quad.init(tx, thumb_y, SCROLLBAR_W, thumb);
    var bar = theme.muted_foreground;
    bar.a = SCROLLBAR_THUMB_ALPHA;
    _ = q.set_background(bar).set_corner_radius(SCROLLBAR_W / 2);
    try b.append_quad(q);
}

// Draws top-down (parent before child = correct z-order). The caller resets the
// arena + eng.clear() before building the tree.
pub fn render(
    eng: *LayoutEngine,
    b: *RenderBuilder,
    theme: *const Theme,
    root: *Node,
    viewport: SizeF,
    pc: ?*paint.PaintContext,
) RenderError!void {
    try render_at(eng, b, theme, root, .{ .origin = .{ .x = 0, .y = 0 }, .size = viewport }, pc);
}

// Lay out against body.size and draw translated to body.origin. The shell hands
// the consumer a body rect inset below the default titlebar; pass it here and the
// whole tree sits below the band with zero coordinate math at the call site.
pub fn render_at(
    eng: *LayoutEngine,
    b: *RenderBuilder,
    theme: *const Theme,
    root: *Node,
    body: BoundsF,
    pc: ?*paint.PaintContext,
) RenderError!void {
    const prev_measure_b = measure_b;
    measure_b = b;
    defer measure_b = prev_measure_b;
    shape_text(b, root, 0);
    try register_tree(eng, root, 0);
    eng.set_root(root.id);
    eng.compute(body.size);
    try draw_tree(b, eng, theme, root, 0, body.origin.x, body.origin.y, pc);
}
