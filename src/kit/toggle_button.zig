const std = @import("std");
const types = @import("../window/types.zig");
const color = @import("../color.zig");
const builder = @import("../render/builder.zig");
const callbacks = @import("../callbacks.zig");
const RenderError = builder.RenderError;
const label = @import("../render/label.zig");
const icon = @import("../render/icon.zig");
const primitives = @import("../primitives.zig");
const custom_paint = @import("../window/paint.zig");
const tr = @import("theme_resolve.zig");

pub const RenderBuilder = builder.RenderBuilder;
pub const Theme = types.Theme;
pub const Size = types.Size;
pub const Rgba = color.Rgba;
pub const Quad = primitives.Quad;
pub const SizeF = @import("../geometry.zig").SizeF;
pub const SizeProposal = @import("../geometry.zig").SizeProposal;

pub const ToggleVariant = enum { default, outline };

pub const ToggleButtonOptions = struct {
    on: bool = false,
    variant: ToggleVariant = .default,
    size: Size = .default,
    disabled: bool = false,
    invalid: bool = false,
    // Leading icon; with no text it is icon-only.
    icon: ?icon.Icon = null,
    theme: *const Theme,
    paint: ?*custom_paint.PaintContext = null,
    on_toggle: ?callbacks.ToggleFn = null,
    ctx: ?*anyopaque = null,
};

const ICON_GAP: f32 = 6;
const ICON_PAD: f32 = 2;
const PAD_X: f32 = 10;

// Never narrower than the height, so an icon-only toggle stays square.
pub fn measure(
    b: *RenderBuilder,
    proposal: SizeProposal,
    text: []const u8,
    opts: ToggleButtonOptions,
) SizeF {
    _ = proposal;
    const geom = tr.button_geom_for(opts.size, opts.theme);
    if (text.len == 0) return SizeF.init(geom.height, geom.height);
    const ls = label.Style{
        .font_size = geom.font_size,
        .weight = .medium,
        .color = tr.transparent(),
    };
    const m = label.measure(b, text, ls);
    const has_icon = opts.icon != null;
    const islot: f32 = if (has_icon) geom.font_size + ICON_PAD + ICON_GAP else 0;
    return SizeF.init(@max(geom.height, PAD_X * 2 + islot + m.width), geom.height);
}

// Pass w_in <= 0 to size to content.
pub fn render(
    b: *RenderBuilder,
    x: f32,
    y: f32,
    w_in: f32,
    text: []const u8,
    opts: ToggleButtonOptions,
) RenderError!SizeF {
    const theme = opts.theme;
    const geom = tr.button_geom_for(opts.size, theme);
    const h = geom.height;
    const w = if (w_in > 0) w_in else measure(b, .{}, text, opts).width;
    std.debug.assert(w > 0);

    var bg = if (opts.on) theme.accent else tr.transparent();
    var fg = if (opts.on) theme.accent_foreground else theme.foreground;
    if (opts.paint) |p| {
        if (!opts.disabled) {
            if (!opts.on and p.is_hovered(x, y, w, h)) {
                bg = theme.muted;
                fg = theme.muted_foreground;
            }
            try p.add_hitbox(.{
                .x = x,
                .y = y,
                .w = w,
                .h = h,
                .on_click = opts.on_toggle,
                .ctx = opts.ctx,
            });
        }
    }
    const a: f32 = if (opts.disabled) tr.DISABLED_ALPHA else 1;
    fg = tr.fade(fg, a);

    var q = Quad.init(x, y, w, h);
    _ = q.set_background(tr.fade(bg, a)).set_corner_radius(theme.radius - 2);
    if (opts.invalid) {
        _ = q.set_border_color(tr.fade(theme.destructive, a)).set_border_width(1);
    } else if (opts.variant == .outline) {
        _ = q.set_border_color(tr.fade(theme.border, a)).set_border_width(1);
    }
    try b.append_quad(q);

    const ls = label.Style{ .font_size = geom.font_size, .weight = .medium, .color = fg };
    const has_icon = opts.icon != null;
    const ipt = geom.font_size + ICON_PAD;

    if (has_icon and text.len == 0) {
        _ = try icon.render_icon_centered_xy(
            b,
            x,
            y,
            w,
            h,
            opts.icon.?,
            .{ .point_size = ipt, .color = fg },
        );
        return SizeF.init(w, h);
    }
    const m = label.measure(b, text, ls);
    if (!has_icon) {
        _ = try label.render(b, x + (w - m.width) / 2, label.centered_top(y, h, m), text, ls);
        return SizeF.init(w, h);
    }
    const total = ipt + ICON_GAP + m.width;
    const gx = x + (w - total) / 2;
    _ = try icon.render_icon_centered_xy(
        b,
        gx,
        y,
        ipt,
        h,
        opts.icon.?,
        .{ .point_size = ipt, .color = fg },
    );
    _ = try label.render(b, gx + ipt + ICON_GAP, label.centered_top(y, h, m), text, ls);
    return SizeF.init(w, h);
}
