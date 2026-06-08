const std = @import("std");
const types = @import("../window/types.zig");
const builder = @import("../render/builder.zig");
const RenderError = builder.RenderError;
const primitives = @import("../primitives.zig");

pub const RenderBuilder = builder.RenderBuilder;
pub const Theme = types.Theme;
pub const Quad = primitives.Quad;
pub const SizeF = @import("../geometry.zig").SizeF;

pub const ProgressOptions = struct {
    theme: *const Theme,
    height: f32 = 8,
    // phase is caller-owned 0..1: advance each frame and set PaintContext.animating.
    indeterminate: bool = false,
    phase: f32 = 0,
};

const INDET_FRAC: f32 = 0.35;

pub fn render(
    b: *RenderBuilder,
    x: f32,
    y: f32,
    w: f32,
    value: f32,
    opts: ProgressOptions,
) RenderError!SizeF {
    std.debug.assert(w >= 0);
    std.debug.assert(opts.height > 0);
    const theme = opts.theme;
    const h = opts.height;
    var track = Quad.init(x, y, w, h);
    _ = track.set_background(theme.secondary).set_corner_radius(h / 2);
    try b.append_quad(track);

    if (opts.indeterminate) {
        const seg = w * INDET_FRAC;
        // triangle wave so the segment ping-pongs instead of jumping at phase wrap.
        const tri = 1 - @abs(@mod(opts.phase, 1.0) * 2 - 1);
        const fx = x + (w - seg) * tri;
        var fill = Quad.init(fx, y, seg, h);
        _ = fill.set_background(theme.primary).set_corner_radius(h / 2);
        try b.append_quad(fill);
        return SizeF.init(w, h);
    }

    const v = std.math.clamp(value, 0, 1);
    const fw = w * v;
    if (fw <= 0) return SizeF.init(w, h);
    var fill = Quad.init(x, y, fw, h);
    _ = fill.set_background(theme.primary).set_corner_radius(h / 2);
    try b.append_quad(fill);
    return SizeF.init(w, h);
}
