const std = @import("std");
const types = @import("../window/types.zig");
const builder = @import("../render/builder.zig");
const callbacks = @import("../callbacks.zig");
const RenderError = builder.RenderError;
const label = @import("../render/label.zig");
const primitives = @import("../primitives.zig");
const custom_paint = @import("../window/paint.zig");
const input = @import("input.zig");

pub const RenderBuilder = builder.RenderBuilder;
pub const Theme = types.Theme;
pub const Quad = primitives.Quad;
pub const SizeF = @import("../geometry.zig").SizeF;

// Plain hover-highlighted label until focused, then a real input box whose native
// editor the caller overlays. Caller owns value + focus (one native editor shared
// across fields, same as input).
pub const EditableOptions = struct {
    value: []const u8 = "",
    placeholder: []const u8 = "Click to edit",
    focused: bool = false,
    theme: *const Theme,
    paint: ?*custom_paint.PaintContext = null,
    on_focus: ?callbacks.FocusFn = null,
    ctx: ?*anyopaque = null,
};

// Matches input.zig's text inset so the idle label aligns with the box text.
const PAD: f32 = 12;

pub fn height_for() f32 {
    return input.height_for(.default);
}

pub fn render(b: *RenderBuilder, x: f32, y: f32, w: f32, opts: EditableOptions) RenderError!SizeF {
    std.debug.assert(w > 0);
    const theme = opts.theme;
    const h = input.height_for(.default);

    // Empty value: the caller's native editor draws the text over the box.
    if (opts.focused) {
        return input.render(b, x, y, w, .{
            .value = "",
            .focused = true,
            .theme = theme,
            .paint = opts.paint,
            .on_focus = opts.on_focus,
            .ctx = opts.ctx,
        });
    }

    // No border, so the muted hover fill is the only cue this label is a click target.
    if (opts.paint) |p| {
        if (p.is_hovered(x, y, w, h)) {
            var hl = Quad.init(x, y, w, h);
            _ = hl.set_background(theme.muted).set_corner_radius(theme.radius - 2);
            try b.append_quad(hl);
        }
    }
    const has_val = opts.value.len > 0;
    const shown = if (has_val) opts.value else opts.placeholder;
    const fg = if (has_val) theme.foreground else theme.muted_foreground;
    const sty = label.Style{ .font_size = theme.font_size, .weight = .normal, .color = fg };
    const m = label.measure(b, shown, sty);
    _ = try label.render(b, x + PAD, label.centered_top(y, h, m), shown, sty);
    if (opts.paint) |p| {
        try p.add_hitbox(.{
            .x = x,
            .y = y,
            .w = w,
            .h = h,
            .on_click = opts.on_focus,
            .ctx = opts.ctx,
        });
    }
    return SizeF.init(w, h);
}
