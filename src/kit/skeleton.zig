const std = @import("std");
const types = @import("../window/types.zig");
const builder = @import("../render/builder.zig");
const RenderError = builder.RenderError;
const primitives = @import("../primitives.zig");

pub const RenderBuilder = builder.RenderBuilder;
pub const Theme = types.Theme;
pub const Quad = primitives.Quad;
pub const SizeF = @import("../geometry.zig").SizeF;

pub const SkeletonOptions = struct {
    theme: *const Theme,
    radius: f32 = 6,
};

// Static: a pulse animation would need a frame clock the shell drives later.
pub fn render(
    b: *RenderBuilder,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    opts: SkeletonOptions,
) RenderError!SizeF {
    std.debug.assert(w > 0);
    std.debug.assert(h > 0);
    var q = Quad.init(x, y, w, h);
    _ = q.set_background(opts.theme.muted).set_corner_radius(opts.radius);
    try b.append_quad(q);
    return SizeF.init(w, h);
}
