const std = @import("std");
const types = @import("../window/types.zig");
const builder = @import("../render/builder.zig");
const RenderError = builder.RenderError;
const primitives = @import("../primitives.zig");

pub const RenderBuilder = builder.RenderBuilder;
pub const Theme = types.Theme;
pub const Quad = primitives.Quad;
pub const SizeF = @import("../geometry.zig").SizeF;

pub const THICKNESS: f32 = 1;

pub const Orientation = enum { horizontal, vertical };

pub const SeparatorOptions = struct {
    orientation: Orientation = .horizontal,
    theme: *const Theme,
};

pub fn render(
    b: *RenderBuilder,
    x: f32,
    y: f32,
    len: f32,
    opts: SeparatorOptions,
) RenderError!SizeF {
    std.debug.assert(len > 0);
    var line = switch (opts.orientation) {
        .horizontal => Quad.init(x, y, len, THICKNESS),
        .vertical => Quad.init(x, y, THICKNESS, len),
    };
    _ = line.set_background(opts.theme.border);
    try b.append_quad(line);
    return switch (opts.orientation) {
        .horizontal => SizeF.init(len, THICKNESS),
        .vertical => SizeF.init(THICKNESS, len),
    };
}
