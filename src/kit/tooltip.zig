const std = @import("std");
const types = @import("../window/types.zig");
const builder = @import("../render/builder.zig");
const RenderError = builder.RenderError;
const label = @import("../render/label.zig");
const primitives = @import("../primitives.zig");

pub const RenderBuilder = builder.RenderBuilder;
pub const Theme = types.Theme;
pub const Quad = primitives.Quad;
pub const Rect = [4]f32;

const PAD_X: f32 = 9;
const H: f32 = 26;
const RADIUS: f32 = 6;
const CARET: f32 = 10; // square; half buried in the bubble bottom
const CARET_ROT: f32 = std.math.pi / 4.0;
const FONT_DELTA: f32 = 2;

pub const TooltipOptions = struct {
    theme: *const Theme,
};

// Caller draws this last so it overlays; returned rect is for behind-masking.
pub fn render(
    b: *RenderBuilder,
    x: f32,
    y: f32,
    text: []const u8,
    opts: TooltipOptions,
) RenderError!Rect {
    std.debug.assert(text.len > 0);
    const theme = opts.theme;
    const sty = label.Style{
        .font_size = theme.font_size - FONT_DELTA,
        .weight = .medium,
        .color = theme.primary_foreground,
    };
    const m = label.measure(b, text, sty);
    const w = m.width + PAD_X * 2;

    var bubble = Quad.init(x, y, w, H);
    _ = bubble.set_background(theme.primary).set_corner_radius(RADIUS);
    try b.append_quad(bubble);

    const cx = x + w / 2;
    var caret = Quad.init(cx - CARET / 2, y + H - CARET / 2, CARET, CARET);
    _ = caret.set_background(theme.primary).set_rotation(CARET_ROT);
    try b.append_quad(caret);

    _ = try label.render(b, x + PAD_X, label.centered_top(y, H, m), text, sty);
    return .{ x, y, w, H + CARET / 2 };
}
