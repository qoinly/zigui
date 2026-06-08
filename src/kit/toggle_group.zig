const std = @import("std");
const types = @import("../window/types.zig");
const color = @import("../color.zig");
const builder = @import("../render/builder.zig");
const RenderError = builder.RenderError;
const label = @import("../render/label.zig");
const icon = @import("../render/icon.zig");
const primitives = @import("../primitives.zig");
const custom_paint = @import("../window/paint.zig");
const toggle_button = @import("toggle_button.zig");
const tr = @import("theme_resolve.zig");
const callbacks = @import("../callbacks.zig");

pub const RenderBuilder = builder.RenderBuilder;
pub const Theme = types.Theme;
pub const Size = types.Size;
pub const Quad = primitives.Quad;
pub const LineSegment = primitives.LineSegment;
pub const ToggleVariant = toggle_button.ToggleVariant;
pub const SizeF = @import("../geometry.zig").SizeF;
pub const SizeProposal = @import("../geometry.zig").SizeProposal;

// Caller owns the on-state; single vs multiple selection is just how many
// items the caller keeps on. on_toggle reports the press; the caller flips.
pub const ToggleGroupItem = struct {
    label: []const u8 = "",
    icon: ?icon.Icon = null,
    on: bool = false,
    on_toggle: ?callbacks.ToggleFn = null,
    ctx: ?*anyopaque = null,
};

pub const ToggleGroupOptions = struct {
    items: []const ToggleGroupItem,
    variant: ToggleVariant = .default,
    size: Size = .default,
    connected: bool = false, // touching segments vs spaced pills
    theme: *const Theme,
    paint: ?*custom_paint.PaintContext = null,
};

pub const MAX_ITEMS = 12;
const GAP: f32 = 4;
const PAD_X: f32 = 12;
const ICON_GAP: f32 = 6;
const ICON_PAD: f32 = 2;

fn item_width(b: *RenderBuilder, it: ToggleGroupItem, geom: tr.ButtonGeom, h: f32) f32 {
    if (it.label.len == 0) return h; // icon-only square
    // measure() ignores colour, so the value here is a don't-care placeholder.
    const ls = label.Style{
        .font_size = geom.font_size,
        .weight = .medium,
        .color = tr.transparent(),
    };
    const m = label.measure(b, it.label, ls);
    const has_glyph = it.icon != null;
    const islot: f32 = if (has_glyph) geom.font_size + ICON_PAD + ICON_GAP else 0;
    return PAD_X * 2 + islot + m.width;
}

pub fn measure(b: *RenderBuilder, proposal: SizeProposal, opts: ToggleGroupOptions) SizeF {
    _ = proposal;
    std.debug.assert(opts.items.len <= MAX_ITEMS);
    const geom = tr.button_geom_for(opts.size, opts.theme);
    const h = geom.height;
    const gap: f32 = if (opts.connected) 0 else GAP;
    var total: f32 = 0;
    for (opts.items, 0..) |it, i| {
        total += item_width(b, it, geom, h) + (if (i > 0) gap else 0);
    }
    return SizeF.init(total, h);
}

pub fn render(b: *RenderBuilder, x: f32, y: f32, opts: ToggleGroupOptions) RenderError!SizeF {
    std.debug.assert(opts.items.len <= MAX_ITEMS);
    const theme = opts.theme;
    const geom = tr.button_geom_for(opts.size, theme);
    const h = geom.height;
    const gap: f32 = if (opts.connected) 0 else GAP;
    const radius = theme.radius - 2;

    var widths: [MAX_ITEMS]f32 = undefined;
    var total: f32 = 0;
    for (opts.items, 0..) |it, i| {
        widths[i] = item_width(b, it, geom, h);
        total += widths[i] + (if (i > 0) gap else 0);
    }

    if (opts.connected and opts.variant == .outline) {
        var outer = Quad.init(x, y, total, h);
        _ = outer.set_background(tr.transparent())
            .set_corner_radius(radius)
            .set_border_color(theme.border)
            .set_border_width(1);
        try b.append_quad(outer);
    }

    var ix = x;
    for (opts.items, 0..) |it, i| {
        const iw = widths[i];
        var bg = if (it.on) theme.accent else tr.transparent();
        var fg = if (it.on) theme.accent_foreground else theme.foreground;
        if (opts.paint) |p| {
            if (!it.on and p.is_hovered(ix, y, iw, h)) {
                bg = theme.muted;
                fg = theme.muted_foreground;
            }
            try p.add_hitbox(.{
                .x = ix,
                .y = y,
                .w = iw,
                .h = h,
                .on_click = it.on_toggle,
                .ctx = it.ctx,
            });
        }

        if (opts.connected) {
            if (bg.a > 0) {
                var cell = Quad.init(ix + 1, y + 1, iw - 2, h - 2);
                _ = cell.set_background(bg).set_corner_radius(2);
                try b.append_quad(cell);
            }
            if (i > 0 and opts.variant == .outline) {
                try b.append_line(LineSegment.init(ix, y + 4, ix, y + h - 4, 1, theme.border));
            }
        } else if (bg.a > 0 or opts.variant == .outline) {
            var q = Quad.init(ix, y, iw, h);
            _ = q.set_background(bg).set_corner_radius(radius);
            if (opts.variant == .outline) _ = q.set_border_color(theme.border).set_border_width(1);
            try b.append_quad(q);
        }

        try draw_content(b, ix, y, iw, h, it, geom, fg);
        ix += iw + gap;
    }
    return SizeF.init(total, h);
}

fn draw_content(
    b: *RenderBuilder,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    it: ToggleGroupItem,
    geom: tr.ButtonGeom,
    fg: color.Rgba,
) !void {
    const ipt = geom.font_size + ICON_PAD;
    const ls = label.Style{ .font_size = geom.font_size, .weight = .medium, .color = fg };
    const has_icon = it.icon != null;
    if (it.label.len == 0) {
        if (has_icon) _ = try icon.render_icon_centered_xy(
            b,
            x,
            y,
            w,
            h,
            it.icon.?,
            .{ .point_size = ipt, .color = fg },
        );
        return;
    }
    const m = label.measure(b, it.label, ls);
    if (!has_icon) {
        _ = try label.render(b, x + (w - m.width) / 2, label.centered_top(y, h, m), it.label, ls);
        return;
    }
    const tw = ipt + ICON_GAP + m.width;
    const gx = x + (w - tw) / 2;
    _ = try icon.render_icon_centered_xy(
        b,
        gx,
        y,
        ipt,
        h,
        it.icon.?,
        .{ .point_size = ipt, .color = fg },
    );
    _ = try label.render(b, gx + ipt + ICON_GAP, label.centered_top(y, h, m), it.label, ls);
}
