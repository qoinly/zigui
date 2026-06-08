const std = @import("std");
const types = @import("../window/types.zig");
const builder = @import("../render/builder.zig");
const callbacks = @import("../callbacks.zig");
const RenderError = builder.RenderError;
const label = @import("../render/label.zig");
const icon = @import("../render/icon.zig");
const primitives = @import("../primitives.zig");
const spinner = @import("spinner.zig");
const custom_paint = @import("../window/paint.zig");
const tr = @import("theme_resolve.zig");

pub const RenderBuilder = builder.RenderBuilder;
pub const Theme = types.Theme;
pub const Variant = types.Variant;
pub const Size = types.Size;
pub const Quad = primitives.Quad;
pub const SizeF = @import("../geometry.zig").SizeF;
pub const SizeProposal = @import("../geometry.zig").SizeProposal;

pub const IconPos = enum { leading, trailing };

pub const ButtonOptions = struct {
    variant: Variant = .default,
    size: Size = .default,
    disabled: bool = false,
    // Sole content under size = .icon; text is ignored there.
    icon: ?icon.Icon = null,
    icon_pos: IconPos = .leading,
    // spin_phase is caller-owned: the widget reads it, never advances it.
    loading: bool = false,
    spin_phase: f32 = 0,
    theme: *const Theme,
    paint: ?*custom_paint.PaintContext = null,
    on_click: ?callbacks.ClickFn = null,
    ctx: ?*anyopaque = null,
};

const ICON_GAP: f32 = 6;
const GLYPH_SLOT_PAD: f32 = 2; // pads the glyph slot so a narrow icon still aligns with text
const ICON_ONLY_RATIO: f32 = 0.42;

// Natural floor only; render still accepts a wider w.
pub fn measure(
    b: *RenderBuilder,
    proposal: SizeProposal,
    text: []const u8,
    opts: ButtonOptions,
) SizeF {
    _ = proposal;
    const geom = tr.button_geom_for(opts.size, opts.theme);
    const h = geom.height;
    if (opts.size == .icon or opts.size == .icon_sm) return SizeF.init(h, h);
    const ls = label.Style{
        .font_size = geom.font_size,
        .weight = .medium,
        .color = opts.theme.foreground,
    };
    const m = label.measure(b, text, ls);
    const has_glyph = opts.loading or opts.icon != null;
    const islot: f32 = if (has_glyph) geom.font_size + GLYPH_SLOT_PAD + ICON_GAP else 0;
    return SizeF.init(geom.pad_x * 2 + islot + m.width, h);
}

pub fn render(
    b: *RenderBuilder,
    x: f32,
    y: f32,
    w: f32,
    text: []const u8,
    opts: ButtonOptions,
) RenderError!SizeF {
    std.debug.assert(w > 0);
    const theme = opts.theme;
    var palette = tr.palette_for(opts.variant, theme);
    const geom = tr.button_geom_for(opts.size, theme);
    const h = geom.height;
    const inert = opts.disabled or opts.loading;

    if (opts.paint) |p| {
        if (!inert) {
            if (p.is_hovered(x, y, w, h)) apply_hover(opts.variant, theme, &palette);
            try p.add_hitbox(.{
                .x = x,
                .y = y,
                .w = w,
                .h = h,
                .on_click = opts.on_click,
                .ctx = opts.ctx,
            });
        }
    }
    if (inert) {
        palette.bg.a *= tr.DISABLED_ALPHA;
        palette.fg.a *= tr.DISABLED_ALPHA;
        palette.border.a *= tr.DISABLED_ALPHA;
    }

    var q = Quad.init(x, y, w, h);
    _ = q.set_background(palette.bg).set_corner_radius(theme.radius - 2);
    if (opts.variant == .outline) _ = q.set_border_color(palette.border).set_border_width(1);
    try b.append_quad(q);

    const ls = label.Style{ .font_size = geom.font_size, .weight = .medium, .color = palette.fg };

    if (opts.size == .icon or opts.size == .icon_sm) {
        // icon_sm keeps the glyph at ~font-size so a compact toolbar button matches
        // sibling icon glyphs instead of scaling with h.
        const ipt = if (opts.size == .icon_sm) geom.font_size + 1 else h * ICON_ONLY_RATIO;
        if (opts.loading) {
            try spinner.render(b, x + w / 2, y + h / 2, ipt / 2, .{
                .color = palette.fg,
                .phase = opts.spin_phase,
            });
        } else if (opts.icon) |ic| {
            _ = try icon.render_icon_centered_xy(b, x, y, w, h, ic, .{
                .point_size = ipt,
                .color = palette.fg,
            });
        }
        return SizeF.init(w, h);
    }

    const m = label.measure(b, text, ls);
    const has_glyph = opts.loading or opts.icon != null;
    if (!has_glyph) {
        _ = try label.render(b, x + (w - m.width) / 2, label.centered_top(y, h, m), text, ls);
        return SizeF.init(w, h);
    }

    const slot = geom.font_size + GLYPH_SLOT_PAD;
    const total = slot + ICON_GAP + m.width;
    const gx = x + (w - total) / 2;
    const leading = opts.icon_pos == .leading;
    const glyph_x = if (leading) gx else gx + m.width + ICON_GAP;
    const label_x = if (leading) gx + slot + ICON_GAP else gx;

    if (opts.loading) {
        try spinner.render(b, glyph_x + slot / 2, y + h / 2, slot / 2 * 0.95, .{
            .color = palette.fg,
            .phase = opts.spin_phase,
        });
    } else if (opts.icon) |ic| {
        _ = try icon.render_icon_centered_xy(b, glyph_x, y, slot, h, ic, .{
            .point_size = slot,
            .color = palette.fg,
        });
    }
    _ = try label.render(b, label_x, label.centered_top(y, h, m), text, ls);
    return SizeF.init(w, h);
}

fn apply_hover(variant: Variant, theme: *const Theme, palette: *tr.Palette) void {
    switch (variant) {
        .default => palette.bg = tr.mix(palette.bg, theme.background, 0.1),
        .secondary => palette.bg = tr.mix(palette.bg, theme.background, 0.2),
        .destructive => palette.bg = tr.mix(palette.bg, theme.background, 0.1),
        .outline, .ghost => {
            palette.bg = theme.accent;
            palette.fg = theme.accent_foreground;
        },
        .link => {},
    }
}
