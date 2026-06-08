const std = @import("std");
const types = @import("../window/types.zig");
const builder = @import("../render/builder.zig");
const callbacks = @import("../callbacks.zig");
const RenderError = builder.RenderError;
const label = @import("../render/label.zig");
const icon = @import("../render/icon.zig");
const primitives = @import("../primitives.zig");
const custom_paint = @import("../window/paint.zig");

pub const RenderBuilder = builder.RenderBuilder;
pub const Theme = types.Theme;
pub const Quad = primitives.Quad;
pub const Rect = [4]f32;

pub const SheetSide = enum { top, right, bottom, left };

pub const SheetOptions = struct {
    side: SheetSide = .right,
    size: f32 = 360, // panel width (left/right) or height (top/bottom)
    open_t: f32 = 1, // slide progress: 0 = off-screen, 1 = fully open
    top_inset: f32 = 0, // keep the panel below a custom title bar / traffic lights
    title: []const u8 = "",
    description: []const u8 = "",
    show_close: bool = true,
    theme: *const Theme,
    paint: ?*custom_paint.PaintContext = null,
    on_close: ?callbacks.CloseFn = null,
    ctx: ?*anyopaque = null,
};

const PAD: f32 = 22;
const DESC_DY: f32 = 26;
const TITLE_DELTA: f32 = 3;
const HEADER_H: f32 = 56;
const CLOSE_SZ: f32 = 26;

// Caller owns the backdrop/scrim and the open_t animation.
pub fn render(b: *RenderBuilder, frame_w: f32, frame_h: f32, opts: SheetOptions) RenderError!Rect {
    // Big enough that the header + padding leave a non-degenerate body rect.
    std.debug.assert(opts.size > HEADER_H + PAD * 2);
    const theme = opts.theme;
    const t = std.math.clamp(opts.open_t, 0, 1);
    const inset = opts.top_inset;
    const avail_h = frame_h - inset;
    std.debug.assert(avail_h > HEADER_H + PAD * 2);

    var px: f32 = 0;
    var py: f32 = inset;
    var pw: f32 = opts.size;
    var ph: f32 = avail_h;
    switch (opts.side) {
        .right => px = frame_w - opts.size * t,
        .left => px = -opts.size * (1 - t),
        .top => {
            pw = frame_w;
            ph = @min(opts.size, avail_h);
            py = inset - ph * (1 - t);
        },
        .bottom => {
            pw = frame_w;
            ph = @min(opts.size, avail_h);
            py = frame_h - ph * t;
        },
    }

    var card = Quad.init(px, py, pw, ph);
    _ = card.set_background(theme.background).set_border_color(theme.border).set_border_width(1);
    try b.append_quad(card);

    if (opts.title.len > 0) {
        _ = try label.render(b, px + PAD, py + PAD, opts.title, .{
            .font_size = theme.font_size + TITLE_DELTA,
            .weight = .semi_bold,
            .color = theme.foreground,
        });
    }
    if (opts.description.len > 0) {
        _ = try label.render(b, px + PAD, py + PAD + DESC_DY, opts.description, .{
            .font_size = theme.font_size - 1,
            .weight = .normal,
            .color = theme.muted_foreground,
        });
    }

    if (opts.show_close) {
        const cx = px + pw - PAD - CLOSE_SZ + 6;
        const cy = py + PAD - 5;
        if (opts.paint) |p| {
            if (p.is_hovered(cx, cy, CLOSE_SZ, CLOSE_SZ)) {
                var hov = Quad.init(cx, cy, CLOSE_SZ, CLOSE_SZ);
                _ = hov.set_background(theme.accent).set_corner_radius(theme.radius - 2);
                try b.append_quad(hov);
            }
            try p.add_hitbox(.{
                .x = cx,
                .y = cy,
                .w = CLOSE_SZ,
                .h = CLOSE_SZ,
                .on_click = opts.on_close,
                .ctx = opts.ctx,
            });
        }
        _ = try icon.render_icon_centered_xy(b, cx, cy, CLOSE_SZ, CLOSE_SZ, .close, .{
            .point_size = theme.font_size + 1,
            .color = theme.muted_foreground,
        });
    }

    const body_y = py + PAD + HEADER_H;
    return .{ px + PAD, body_y, pw - PAD * 2, py + ph - body_y - PAD };
}
