const std = @import("std");
const types = @import("../window/types.zig");
const builder = @import("../render/builder.zig");
const RenderError = builder.RenderError;
const label = @import("../render/label.zig");
const primitives = @import("../primitives.zig");
const custom_paint = @import("../window/paint.zig");
const callbacks = @import("../callbacks.zig");
const button = @import("button.zig");
const tr = @import("theme_resolve.zig");

pub const RenderBuilder = builder.RenderBuilder;
pub const Theme = types.Theme;
pub const Variant = types.Variant;
pub const Quad = primitives.Quad;
pub const Rect = [4]f32;

const PAD: f32 = 22;
const DESC_DY: f32 = 28; // title top to description top
const TITLE_DELTA: f32 = 4; // title size above base font
const ELEVATION: f32 = 0.06;
const ACTION_GAP: f32 = 8;
const ACTION_PAD_X: f32 = 16; // label-to-edge inside an action button
const ACTIONS_MAX: usize = 4; // a dialog footer past this is a caller bug

// Each action carries its own handler, so the dialog needs no shared state to
// report which was clicked.
pub const DialogAction = struct {
    label: []const u8,
    variant: Variant = .default,
    on_click: ?callbacks.ClickFn = null,
    ctx: ?*anyopaque = null,
};

pub const DialogOptions = struct {
    title: []const u8,
    description: ?[]const u8 = null,
    // Footer buttons, laid out right-aligned. Empty = headless: the caller fills
    // the returned rect with its own content + buttons.
    actions: []const DialogAction = &.{},
    width: f32,
    height: f32,
    theme: *const Theme,
    paint: ?*custom_paint.PaintContext = null,
};

// Caller must draw the scrim AND mask the body glyphs behind the rect: the
// renderer flushes glyphs over all quads, so a scrim quad alone can't hide them.
pub fn render(b: *RenderBuilder, x: f32, y: f32, opts: DialogOptions) RenderError!Rect {
    std.debug.assert(opts.width > 0);
    std.debug.assert(opts.height > 0);
    const theme = opts.theme;
    var card = Quad.init(x, y, opts.width, opts.height);
    _ = card.set_background(tr.elevate(theme, ELEVATION))
        .set_corner_radius(theme.radius + 2)
        .set_border_color(theme.border)
        .set_border_width(1);
    try b.append_quad(card);

    _ = try label.render(b, x + PAD, y + PAD, opts.title, .{
        .font_size = theme.font_size + TITLE_DELTA,
        .weight = .semi_bold,
        .color = theme.popover_foreground,
    });
    if (opts.description) |desc| {
        _ = try label.render(b, x + PAD, y + PAD + DESC_DY, desc, .{
            .font_size = theme.font_size,
            .weight = .normal,
            .color = theme.muted_foreground,
        });
    }

    if (opts.actions.len > 0) {
        std.debug.assert(opts.actions.len <= ACTIONS_MAX);
        const ah = tr.button_geom_for(.default, theme).height;
        const ay = y + opts.height - PAD - ah;
        const sty = label.Style{ .font_size = theme.font_size, .weight = .medium };
        var ax = x + opts.width - PAD;
        var i = opts.actions.len;
        while (i > 0) { // right-to-left so the primary action lands at the right edge
            i -= 1;
            const act = opts.actions[i];
            const aw = label.measure(b, act.label, sty).width + ACTION_PAD_X * 2;
            ax -= aw;
            _ = try button.render(b, ax, ay, aw, act.label, .{
                .variant = act.variant,
                .theme = theme,
                .paint = opts.paint,
                .on_click = act.on_click,
                .ctx = act.ctx,
            });
            ax -= ACTION_GAP;
        }
    }
    return .{ x, y, opts.width, opts.height };
}
