const std = @import("std");
const types = @import("../window/types.zig");
const color = @import("../color.zig");
const builder = @import("../render/builder.zig");
const RenderError = builder.RenderError;
const label = @import("../render/label.zig");
const icon = @import("../render/icon.zig");
const primitives = @import("../primitives.zig");
const tr = @import("theme_resolve.zig");

pub const RenderBuilder = builder.RenderBuilder;
pub const Theme = types.Theme;
pub const Quad = primitives.Quad;
pub const Rgba = color.Rgba;
pub const SizeF = @import("../geometry.zig").SizeF;
pub const SizeProposal = @import("../geometry.zig").SizeProposal;

pub const ToastVariant = enum { default, success, destructive };

pub const ToastOptions = struct {
    title: []const u8,
    description: []const u8 = "",
    variant: ToastVariant = .default,
    icon: ?icon.Icon = null,
    theme: *const Theme,
    opacity: f32 = 1, // for the shell's enter/exit fade
};

pub const HEIGHT_PLAIN: f32 = 44;
pub const HEIGHT_DESC: f32 = 62;

const PAD: f32 = 14;
const ICON_COL: f32 = 26; // icon box + gap before the text
const DESC_GAP: f32 = 4;
const ICON_PT: f32 = 16;
const ELEVATION: f32 = 0.05;

pub fn measure(b: *RenderBuilder, proposal: SizeProposal, opts: ToastOptions) SizeF {
    _ = b;
    const h: f32 = if (opts.description.len > 0) HEIGHT_DESC else HEIGHT_PLAIN;
    return SizeF.init(proposal.width orelse 0, h);
}

// Shell owns placement, stacking, and enter/exit timing; opacity drives the fade.
pub fn render(b: *RenderBuilder, x: f32, y: f32, w: f32, opts: ToastOptions) RenderError!SizeF {
    std.debug.assert(w > 0);
    const theme = opts.theme;
    const op = opts.opacity;
    const accent = switch (opts.variant) {
        .default => theme.foreground,
        .success => theme.success,
        .destructive => theme.destructive,
    };
    const has_desc = opts.description.len > 0;
    const h: f32 = if (has_desc) HEIGHT_DESC else HEIGHT_PLAIN;

    var card = Quad.init(x, y, w, h);
    _ = card.set_background(tr.fade(tr.elevate(theme, ELEVATION), op))
        .set_corner_radius(theme.radius)
        .set_border_color(tr.fade(theme.border, op))
        .set_border_width(1);
    try b.append_quad(card);

    const title_sty = label.Style{
        .font_size = theme.font_size,
        .weight = .semi_bold,
        .color = tr.fade(theme.popover_foreground, op),
    };
    const desc_sty = label.Style{
        .font_size = theme.font_size - 1,
        .weight = .normal,
        .color = tr.fade(theme.muted_foreground, op),
    };
    const tm = label.measure(b, opts.title, title_sty);
    const title_h = tm.ascent + tm.descent;

    // Icon centers on the title line, not the block, so glyph and label
    // share one optical mid-line.
    const desc_h: f32 = if (has_desc) blk: {
        const dm = label.measure(b, opts.description, desc_sty);
        break :blk DESC_GAP + dm.ascent + dm.descent;
    } else 0;
    const block_h = title_h + desc_h;
    const block_top = y + (h - block_h) / 2;
    const title_cy = block_top + title_h / 2;

    const has_icon = opts.icon != null;
    const tx = x + PAD + (if (has_icon) ICON_COL else 0);
    if (has_icon) _ = try icon.render_icon_centered_y(
        b,
        x + PAD,
        title_cy,
        0,
        opts.icon.?,
        .{ .point_size = ICON_PT, .color = tr.fade(accent, op) },
    );

    _ = try label.render(b, tx, block_top, opts.title, title_sty);
    if (has_desc) {
        _ = try label.render(b, tx, block_top + title_h + DESC_GAP, opts.description, desc_sty);
    }
    return SizeF.init(w, h);
}
