const std = @import("std");
const types = @import("../window/types.zig");
const builder = @import("../render/builder.zig");
const RenderError = builder.RenderError;
const label = @import("../render/label.zig");
const icon = @import("../render/icon.zig");
const primitives = @import("../primitives.zig");

pub const RenderBuilder = builder.RenderBuilder;
pub const Theme = types.Theme;
pub const Quad = primitives.Quad;
pub const SizeF = @import("../geometry.zig").SizeF;
pub const SizeProposal = @import("../geometry.zig").SizeProposal;

pub const AlertVariant = enum { default, destructive };

pub const AlertOptions = struct {
    title: []const u8,
    description: []const u8 = "",
    variant: AlertVariant = .default,
    icon: ?icon.Icon = .info,
    theme: *const Theme,
};

const PAD: f32 = 16;
const ICON_COL: f32 = 26;
const DESC_GAP: f32 = 4;
const ICON_PT: f32 = 16;
const H_PLAIN: f32 = 48;
const H_DESC: f32 = 70;

pub fn measure(b: *RenderBuilder, proposal: SizeProposal, opts: AlertOptions) SizeF {
    _ = b;
    const h: f32 = if (opts.description.len > 0) H_DESC else H_PLAIN;
    return SizeF.init(proposal.width orelse 0, h);
}

pub fn render(b: *RenderBuilder, x: f32, y: f32, w: f32, opts: AlertOptions) RenderError!SizeF {
    std.debug.assert(w > 0);
    const theme = opts.theme;
    const accent = switch (opts.variant) {
        .default => theme.foreground,
        .destructive => theme.destructive,
    };
    const has_desc = opts.description.len > 0;
    const h: f32 = if (has_desc) H_DESC else H_PLAIN;

    var card = Quad.init(x, y, w, h);
    const border_color = if (opts.variant == .destructive) theme.destructive else theme.border;
    _ = card.set_background(theme.card)
        .set_corner_radius(theme.radius)
        .set_border_color(border_color)
        .set_border_width(1);
    try b.append_quad(card);

    const title_sty = label.Style{
        .font_size = theme.font_size,
        .weight = .semi_bold,
        .color = accent,
    };
    const desc_sty = label.Style{
        .font_size = theme.font_size - 1,
        .weight = .normal,
        .color = theme.muted_foreground,
    };
    const tm = label.measure(b, opts.title, title_sty);
    const title_h = tm.ascent + tm.descent;

    // Icon centers on the title line so glyph and title share one optical mid-line.
    const desc_h: f32 = if (has_desc) blk: {
        const dm = label.measure(b, opts.description, desc_sty);
        break :blk DESC_GAP + dm.ascent + dm.descent;
    } else 0;
    const block_top = y + (h - (title_h + desc_h)) / 2;
    const title_cy = block_top + title_h / 2;

    const has_icon = opts.icon != null;
    const text_x = x + PAD + (if (has_icon) ICON_COL else 0);
    if (has_icon) _ = try icon.render_icon_centered_y(
        b,
        x + PAD,
        title_cy,
        0,
        opts.icon.?,
        .{ .point_size = ICON_PT, .color = accent },
    );

    _ = try label.render(b, text_x, block_top, opts.title, title_sty);
    if (has_desc) {
        _ = try label.render(b, text_x, block_top + title_h + DESC_GAP, opts.description, desc_sty);
    }
    return SizeF.init(w, h);
}
