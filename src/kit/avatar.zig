const std = @import("std");
const types = @import("../window/types.zig");
const builder = @import("../render/builder.zig");
const RenderError = builder.RenderError;
const label = @import("../render/label.zig");
const primitives = @import("../primitives.zig");

pub const RenderBuilder = builder.RenderBuilder;
pub const Theme = types.Theme;
pub const Quad = primitives.Quad;
pub const SizeF = @import("../geometry.zig").SizeF;
pub const SizeProposal = @import("../geometry.zig").SizeProposal;

const INITIALS_RATIO: f32 = 0.36;

pub const AvatarOptions = struct {
    initials: []const u8,
    theme: *const Theme,
    size: f32 = 40,
};

// Fixed square; centred initials never grow it.
pub fn measure(b: *RenderBuilder, proposal: SizeProposal, opts: AvatarOptions) SizeF {
    _ = b;
    _ = proposal;
    std.debug.assert(opts.size > 0); // render() relies on the same invariant
    return SizeF.init(opts.size, opts.size);
}

pub fn render(b: *RenderBuilder, x: f32, y: f32, opts: AvatarOptions) RenderError!SizeF {
    std.debug.assert(opts.size > 0);
    const theme = opts.theme;
    const s = opts.size;
    var circle = Quad.init(x, y, s, s);
    _ = circle.set_background(theme.secondary).set_corner_radius(s / 2);
    try b.append_quad(circle);

    const sty = label.Style{
        .font_size = s * INITIALS_RATIO,
        .weight = .medium,
        .color = theme.secondary_foreground,
    };
    const m = label.measure(b, opts.initials, sty);
    _ = try label.render(b, x + (s - m.width) / 2, label.centered_top(y, s, m), opts.initials, sty);
    return SizeF.init(s, s);
}
