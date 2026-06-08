const std = @import("std");
const types = @import("../window/types.zig");
const builder = @import("../render/builder.zig");
const RenderError = builder.RenderError;
const label = @import("../render/label.zig");
const primitives = @import("../primitives.zig");
const tr = @import("theme_resolve.zig");

pub const RenderBuilder = builder.RenderBuilder;
pub const Theme = types.Theme;
pub const Variant = types.Variant;
pub const Quad = primitives.Quad;
pub const SizeF = @import("../geometry.zig").SizeF;
pub const SizeProposal = @import("../geometry.zig").SizeProposal;

const PAD_X: f32 = 7;
const H: f32 = 18;
const FONT_DELTA: f32 = 3;

pub const BadgeOptions = struct {
    variant: Variant = .default,
    theme: *const Theme,
};

// A pill hugging its text, floored to a circle so single-glyph badges stay round.
pub fn measure(
    b: *RenderBuilder,
    proposal: SizeProposal,
    text: []const u8,
    opts: BadgeOptions,
) SizeF {
    _ = proposal;
    const sty = label.Style{
        .font_size = opts.theme.font_size - FONT_DELTA,
        .weight = .semi_bold,
        .color = opts.theme.foreground,
    };
    const m = label.measure(b, text, sty);
    return SizeF.init(@max(m.width + PAD_X * 2, H), H);
}

pub fn render(
    b: *RenderBuilder,
    x: f32,
    y: f32,
    text: []const u8,
    opts: BadgeOptions,
) RenderError!SizeF {
    std.debug.assert(text.len > 0);
    const palette = tr.palette_for(opts.variant, opts.theme);
    const sty = label.Style{
        .font_size = opts.theme.font_size - FONT_DELTA,
        .weight = .semi_bold,
        .color = palette.fg,
    };
    const m = label.measure(b, text, sty);
    const w: f32 = measure(b, .{}, text, opts).width;
    var pill = Quad.init(x, y, w, H);
    _ = pill.set_background(palette.bg).set_corner_radius(H / 2);
    try b.append_quad(pill);
    const text_x = x + (w - m.width) / 2;
    _ = try label.render(b, text_x, label.centered_top(y, H, m), text, sty);
    return SizeF.init(w, H);
}
