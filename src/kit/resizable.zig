const std = @import("std");
const types = @import("../window/types.zig");
const builder = @import("../render/builder.zig");
const callbacks = @import("../callbacks.zig");
const RenderError = builder.RenderError;
const primitives = @import("../primitives.zig");
const custom_paint = @import("../window/paint.zig");

pub const RenderBuilder = builder.RenderBuilder;
pub const Theme = types.Theme;
pub const Quad = primitives.Quad;
pub const LineSegment = primitives.LineSegment;
pub const SizeF = @import("../geometry.zig").SizeF;

pub const Orientation = enum { horizontal, vertical };

// accent's highlighted centre segment is accent_frac of the length.
pub const HandleKind = enum { line, grip, accent };

pub const ResizableOptions = struct {
    orientation: Orientation = .horizontal,
    kind: HandleKind = .line,
    accent_frac: f32 = 0.35,
    // When two dividers' grab bands meet (a T-junction) both would light up.
    // The kit can't see its siblings, so the caller (which owns the layout)
    // resolves priority and forces the hover state here; null = self-detect.
    show_hover: ?bool = null,
    theme: *const Theme,
    paint: ?*custom_paint.PaintContext = null,
    on_drag: ?callbacks.DragFn = null,
    on_drag_end: ?callbacks.DragEndFn = null,
    ctx: ?*anyopaque = null,
};

const HIT: f32 = 5; // grab slop each side of the 1px line
const GRIP_THICK: f32 = 4;
const GRIP_LONG: f32 = 26;
const ACCENT_THICK: f32 = 2;
const GLOW_BANDS: usize = 24; // bands per side from the centre outward
const GLOW_REACH: f32 = 0.35; // glow reaches this fraction of len each way
const GLOW_PEAK: f32 = 0.7; // alpha at the centre; fades to GLOW_EDGE at the rim
const GLOW_EDGE: f32 = 0.05;
const GLOW_THICK: f32 = 1.5;

fn hit_rect(horizontal: bool, x: f32, y: f32, len: f32) [4]f32 {
    return if (horizontal) .{ x - HIT, y, HIT * 2, len } else .{ x, y - HIT, len, HIT * 2 };
}

// Whether the cursor is over this divider's grab band. The caller uses this to
// break ties at a T-junction before deciding each handle's show_hover.
pub fn hovered(
    p: *custom_paint.PaintContext,
    orientation: Orientation,
    x: f32,
    y: f32,
    len: f32,
) bool {
    const r = hit_rect(orientation == .horizontal, x, y, len);
    return p.is_hovered(r[0], r[1], r[2], r[3]);
}

// Horizontal orientation = panels side by side, so the divider is VERTICAL and
// spans [y, y+len]; vertical = stacked panels, a HORIZONTAL divider spanning
// [x, x+len].
pub fn render(
    b: *RenderBuilder,
    x: f32,
    y: f32,
    len: f32,
    opts: ResizableOptions,
) RenderError!SizeF {
    std.debug.assert(len > 0);
    const theme = opts.theme;
    const horizontal = opts.orientation == .horizontal;
    const r = hit_rect(horizontal, x, y, len);

    if (horizontal) {
        try b.append_line(LineSegment.init(x, y, x, y + len, 1, theme.border));
    } else {
        try b.append_line(LineSegment.init(x, y, x + len, y, 1, theme.border));
    }

    var hov = false;
    if (opts.paint) |p| {
        hov = opts.show_hover orelse p.is_hovered(r[0], r[1], r[2], r[3]);
        if (hov) {
            p.set_cursor(if (horizontal) .col_resize else .row_resize);
            try draw_glow(b, horizontal, x, y, len, theme);
        }
        try p.add_hitbox(.{
            .x = r[0],
            .y = r[1],
            .w = r[2],
            .h = r[3],
            .on_point = opts.on_drag,
            .on_drag_end = opts.on_drag_end,
            .ctx = opts.ctx,
        });
    }

    switch (opts.kind) {
        .line => {},
        .grip => {
            const gw = if (horizontal) GRIP_THICK else GRIP_LONG;
            const gh = if (horizontal) GRIP_LONG else GRIP_THICK;
            const cx = (if (horizontal) x else x + len / 2) - gw / 2;
            const cy = (if (horizontal) y + len / 2 else y) - gh / 2;
            var pill = Quad.init(cx, cy, gw, gh);
            _ = pill.set_background(if (hov) theme.primary else theme.muted_foreground)
                .set_corner_radius(GRIP_THICK / 2);
            try b.append_quad(pill);
        },
        .accent => {
            const seg = len * std.math.clamp(opts.accent_frac, 0, 1);
            const off = (len - seg) / 2;
            var acc = if (horizontal)
                Quad.init(x - ACCENT_THICK / 2, y + off, ACCENT_THICK, seg)
            else
                Quad.init(x + off, y - ACCENT_THICK / 2, seg, ACCENT_THICK);
            _ = acc.set_background(theme.primary).set_corner_radius(ACCENT_THICK / 2);
            try b.append_quad(acc);
        },
    }
    // The grab band overlaps neighbours, so the laid-out footprint is the 1px
    // line, not the slop.
    return if (horizontal) SizeF.init(1, len) else SizeF.init(len, 1);
}

// Glow centred on the divider's midpoint. Drawn as separate, non-overlapping
// bands fanning out each side so each band's alpha IS the profile (no additive
// build-up): peak GLOW_PEAK at the centre, easing to GLOW_EDGE at the rim.
// Clamped to the divider span so it never spills past the ends.
fn draw_glow(
    b: *RenderBuilder,
    horizontal: bool,
    x: f32,
    y: f32,
    len: f32,
    theme: *const Theme,
) !void {
    const lo = if (horizontal) y else x;
    const hi = lo + len;
    const c = lo + len / 2;
    const step = (len * GLOW_REACH) / @as(f32, @floatFromInt(GLOW_BANDS));
    var k: usize = 0;
    while (k < GLOW_BANDS) : (k += 1) {
        const u = @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(GLOW_BANDS));
        const e = (1 - u) * (1 - u); // ease-out: 1 at centre, 0 at rim
        var col = theme.primary;
        col.a *= GLOW_EDGE + (GLOW_PEAK - GLOW_EDGE) * e;
        const near = @as(f32, @floatFromInt(k)) * step;
        const far = @as(f32, @floatFromInt(k + 1)) * step;
        if (horizontal) {
            try b.append_line(
                LineSegment.init(x, @max(lo, c + near), x, @min(hi, c + far), GLOW_THICK, col),
            );
            try b.append_line(
                LineSegment.init(x, @max(lo, c - far), x, @min(hi, c - near), GLOW_THICK, col),
            );
        } else {
            try b.append_line(
                LineSegment.init(@max(lo, c + near), y, @min(hi, c + far), y, GLOW_THICK, col),
            );
            try b.append_line(
                LineSegment.init(@max(lo, c - far), y, @min(hi, c - near), y, GLOW_THICK, col),
            );
        }
    }
}
