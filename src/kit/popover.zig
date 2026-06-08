const std = @import("std");
const types = @import("../window/types.zig");
const builder = @import("../render/builder.zig");
const RenderError = builder.RenderError;
const primitives = @import("../primitives.zig");
const tr = @import("theme_resolve.zig");

pub const RenderBuilder = builder.RenderBuilder;
pub const Theme = types.Theme;
pub const Quad = primitives.Quad;
pub const Rect = [4]f32;

const ELEVATION: f32 = 0.05;

pub const PopoverOptions = struct {
    theme: *const Theme,
    width: f32,
    height: f32,
};

// Caller must mask body glyphs behind the returned rect: the renderer
// flushes glyphs over all quads.
pub fn render(b: *RenderBuilder, x: f32, y: f32, opts: PopoverOptions) RenderError!Rect {
    std.debug.assert(opts.width > 0);
    std.debug.assert(opts.height > 0);
    const theme = opts.theme;
    var bg = Quad.init(x, y, opts.width, opts.height);
    _ = bg.set_background(tr.elevate(theme, ELEVATION)).set_corner_radius(theme.radius);
    try b.append_quad(bg);
    var border = Quad.init(x, y, opts.width, opts.height);
    _ = border.set_background(tr.transparent())
        .set_corner_radius(theme.radius)
        .set_border_color(theme.border)
        .set_border_width(1);
    try b.append_quad(border);
    return .{ x, y, opts.width, opts.height };
}
