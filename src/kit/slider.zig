const std = @import("std");
const types = @import("../window/types.zig");
const color = @import("../color.zig");
const builder = @import("../render/builder.zig");
const RenderError = builder.RenderError;
const primitives = @import("../primitives.zig");
const custom_paint = @import("../window/paint.zig");

pub const RenderBuilder = builder.RenderBuilder;
pub const Theme = types.Theme;
pub const Quad = primitives.Quad;

pub const Orientation = enum { horizontal, vertical };

// Kit maps the raw hit to a value and picks the nearest thumb, so the caller
// never does pixel math.
pub const ChangeAtFn = *const fn (ctx: ?*anyopaque, index: usize, value: f32) void;

// Geometry + value snapshot captured each render so a later press/drag event can
// map a raw hit to a value. Caller-owned so two sliders never clobber each other;
// values aliases the caller's slice and lives as long as the caller keeps it.
pub const SliderState = struct {
    x: f32 = 0,
    y: f32 = 0,
    main: f32 = 0, // main-axis extent: width when horizontal, height when vertical
    vertical: bool = false,
    step: f32 = 0,
    values: []const f32 = &.{},
    on_change: ?ChangeAtFn = null,
    ctx: ?*anyopaque = null,
};

// Each value in [0,1]. One value fills 0..v; 2+ fill min..max, so a 2-value
// slice is a range and 3+ is multi-thumb.
pub const SliderOptions = struct {
    values: []const f32,
    // 0 = continuous; > 0 snaps to the nearest multiple.
    step: f32 = 0,
    orientation: Orientation = .horizontal,
    disabled: bool = false,
    theme: *const Theme,
    paint: ?*custom_paint.PaintContext = null,
    on_change: ?ChangeAtFn = null,
    ctx: ?*anyopaque = null,
};

const TRACK: f32 = 6;
pub const THUMB: f32 = 18; // diameter doubles as the band height a node wrapper centers in
const MAX_THUMBS: usize = 16;

pub fn render(
    b: *RenderBuilder,
    x: f32,
    y: f32,
    w: f32,
    state: *SliderState,
    opts: SliderOptions,
) RenderError!void {
    const theme = opts.theme;
    std.debug.assert(opts.values.len >= 1);
    std.debug.assert(opts.values.len <= MAX_THUMBS);

    const vertical = opts.orientation == .vertical;
    state.* = .{
        .x = x,
        .y = y,
        .main = w,
        .vertical = vertical,
        .step = opts.step,
        .values = opts.values,
        .on_change = opts.on_change,
        .ctx = opts.ctx,
    };
    if (opts.paint != null and !opts.disabled) {
        const hw: f32 = if (vertical) THUMB else w;
        const hh: f32 = if (vertical) w else THUMB;
        try opts.paint.?.add_hitbox(.{
            .x = x,
            .y = y,
            .w = hw,
            .h = hh,
            .on_point = slider_point,
            .ctx = @ptrCast(state),
        });
    }

    var lo: f32 = 1;
    var hi: f32 = 0;
    for (opts.values) |raw| {
        const v = snap(raw, opts.step);
        lo = @min(lo, v);
        hi = @max(hi, v);
    }
    const fill_lo: f32 = if (opts.values.len == 1) 0 else lo;
    const fill_hi: f32 = hi;

    // Disabled keeps the thumb body opaque; alpha-fading it would let the track
    // bleed through and read as a hollow ring.
    const track_c = theme.secondary;
    const fill_c = if (opts.disabled) theme.muted_foreground else theme.primary;
    const thumb_bg = theme.background;
    const thumb_border = if (opts.disabled) theme.muted_foreground else theme.primary;

    if (vertical) {
        const cx = x + (THUMB - TRACK) / 2;
        var track = Quad.init(cx, y, TRACK, w);
        _ = track.set_background(track_c).set_corner_radius(TRACK / 2);
        try b.append_quad(track);

        // v=0 sits at the bottom (y + w), v=1 at the top (y).
        const top = y + (1 - fill_hi) * w;
        const bot = y + (1 - fill_lo) * w;
        if (bot > top) {
            var fill = Quad.init(cx, top, TRACK, bot - top);
            _ = fill.set_background(fill_c).set_corner_radius(TRACK / 2);
            try b.append_quad(fill);
        }
        for (opts.values) |raw| {
            const v = snap(raw, opts.step);
            const ty = y + (1 - v) * w - THUMB / 2;
            try thumb(b, x, ty, thumb_bg, thumb_border);
        }
    } else {
        const cy = y + (THUMB - TRACK) / 2;
        var track = Quad.init(x, cy, w, TRACK);
        _ = track.set_background(track_c).set_corner_radius(TRACK / 2);
        try b.append_quad(track);

        const fx = x + fill_lo * w;
        const fw = (fill_hi - fill_lo) * w;
        if (fw > 0) {
            var fill = Quad.init(fx, cy, fw, TRACK);
            _ = fill.set_background(fill_c).set_corner_radius(TRACK / 2);
            try b.append_quad(fill);
        }
        for (opts.values) |raw| {
            const v = snap(raw, opts.step);
            try thumb(b, x + v * w - THUMB / 2, y, thumb_bg, thumb_border);
        }
    }
}

fn slider_point(ctx: ?*anyopaque, hx: f32, hy: f32) void {
    const st: *const SliderState = @ptrCast(@alignCast(ctx orelse return));
    std.debug.assert(st.values.len >= 1);
    std.debug.assert(st.values.len <= MAX_THUMBS);
    if (st.main <= 0) return;
    const raw = if (st.vertical) 1 - (hy - st.y) / st.main else (hx - st.x) / st.main;
    const frac = snap(raw, st.step);
    var best: usize = 0;
    var bd: f32 = 2;
    for (st.values, 0..) |v, i| {
        const d = @abs(v - frac);
        if (d < bd) {
            bd = d;
            best = i;
        }
    }
    if (st.on_change) |cb| cb(st.ctx, best, frac);
}

// Both the hit mapping and render run values through here, so a thumb always
// lands on a detent. step <= 0 = continuous.
pub fn snap(frac: f32, step: f32) f32 {
    const c = std.math.clamp(frac, 0, 1);
    if (step <= 0) return c;
    return std.math.clamp(@round(c / step) * step, 0, 1);
}

fn thumb(b: *RenderBuilder, x: f32, y: f32, bg: color.Rgba, border: color.Rgba) !void {
    var t = Quad.init(x, y, THUMB, THUMB);
    _ = t.set_background(bg)
        .set_corner_radius(THUMB / 2)
        .set_border_color(border)
        .set_border_width(2);
    try b.append_quad(t);
}
