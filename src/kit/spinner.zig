const std = @import("std");
const color = @import("../color.zig");
const builder = @import("../render/builder.zig");
const RenderError = builder.RenderError;
const primitives = @import("../primitives.zig");

pub const RenderBuilder = builder.RenderBuilder;
pub const Rgba = color.Rgba;
pub const Quad = primitives.Quad;

const DOTS = 8;
const TRAIL = 0.85; // comet-tail fade depth

// Pure colour primitive: resolves no theme tokens, caller picks the colour.
// phase is caller-owned - advance it each frame and set PaintContext.animating;
// only its fractional part matters.
pub const SpinnerOptions = struct {
    color: Rgba,
    phase: f32 = 0,
};

pub fn render(
    b: *RenderBuilder,
    cx: f32,
    cy: f32,
    radius: f32,
    opts: SpinnerOptions,
) RenderError!void {
    std.debug.assert(radius > 0);
    const c = opts.color;
    const dot_r = radius * 0.26;
    const head = opts.phase * DOTS;
    var i: usize = 0;
    while (i < DOTS) : (i += 1) {
        const fi: f32 = @floatFromInt(i);
        const ang = std.math.tau * fi / @as(f32, DOTS) - std.math.pi / 2.0;
        const px = cx + radius * @cos(ang);
        const py = cy + radius * @sin(ang);
        const dist = @mod(head - fi, @as(f32, DOTS));
        var dc = c;
        dc.a *= 1.0 - (dist / @as(f32, DOTS)) * TRAIL;
        var dot = Quad.init(px - dot_r, py - dot_r, dot_r * 2, dot_r * 2);
        _ = dot.set_background(dc).set_corner_radius(dot_r);
        try b.append_quad(dot);
    }
}
