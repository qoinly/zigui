const types = @import("../window/types.zig");
const builder = @import("../render/builder.zig");
const callbacks = @import("../callbacks.zig");
const RenderError = builder.RenderError;
const label = @import("../render/label.zig");
const icon = @import("../render/icon.zig");
const primitives = @import("../primitives.zig");
const custom_paint = @import("../window/paint.zig");
const tr = @import("theme_resolve.zig");

pub const RenderBuilder = builder.RenderBuilder;
pub const Theme = types.Theme;
pub const Quad = primitives.Quad;
pub const SizeF = @import("../geometry.zig").SizeF;
pub const SizeProposal = @import("../geometry.zig").SizeProposal;

pub const CheckboxOptions = struct {
    checked: bool = false,
    label: []const u8 = "",
    disabled: bool = false,
    invalid: bool = false,
    theme: *const Theme,
    paint: ?*custom_paint.PaintContext = null,
    on_toggle: ?callbacks.ToggleFn = null,
    ctx: ?*anyopaque = null,
};

const BOX: f32 = 18;
const RADIUS: f32 = 5;
const LABEL_GAP: f32 = 8;
const CHECK_PT: f32 = 12;

// Label is drawn at .medium, so measure weighs it the same to stay drift-free.
pub fn measure(b: *RenderBuilder, proposal: SizeProposal, opts: CheckboxOptions) SizeF {
    _ = proposal;
    const label_sty = label.Style{ .font_size = opts.theme.font_size, .weight = .medium };
    const label_w: f32 = if (opts.label.len > 0)
        LABEL_GAP + label.measure(b, opts.label, label_sty).width
    else
        0;
    return SizeF.init(BOX + label_w, BOX);
}

pub fn render(b: *RenderBuilder, x: f32, y: f32, opts: CheckboxOptions) RenderError!SizeF {
    const theme = opts.theme;
    const sz = measure(b, .{}, opts);
    var hovered = false;
    if (opts.paint != null and !opts.disabled) {
        const p = opts.paint.?;
        hovered = p.is_hovered(x, y, sz.width, BOX);
        try p.add_hitbox(.{
            .x = x,
            .y = y,
            .w = sz.width,
            .h = BOX,
            .on_click = opts.on_toggle,
            .ctx = opts.ctx,
        });
    }

    const a: f32 = if (opts.disabled) tr.DISABLED_ALPHA else 1;
    var box = Quad.init(x, y, BOX, BOX);
    if (opts.checked) {
        _ = box.set_background(tr.fade(theme.primary, a))
            .set_corner_radius(RADIUS)
            .set_border_color(tr.fade(theme.primary, a))
            .set_border_width(1);
    } else {
        const bc = if (opts.invalid)
            theme.destructive
        else if (hovered)
            theme.ring
        else
            theme.border;
        _ = box.set_background(tr.transparent())
            .set_corner_radius(RADIUS)
            .set_border_color(tr.fade(bc, a))
            .set_border_width(1.5);
    }
    try b.append_quad(box);

    if (opts.checked) {
        _ = try icon.render_icon_centered_xy(b, x, y, BOX, BOX, .check, .{
            .point_size = CHECK_PT,
            .weight = .bold,
            .color = tr.fade(theme.primary_foreground, a),
        });
    }

    if (opts.label.len > 0) {
        const col = if (opts.disabled)
            theme.muted_foreground
        else if (opts.invalid)
            theme.destructive
        else
            theme.foreground;
        const sty = label.Style{ .font_size = theme.font_size, .weight = .medium, .color = col };
        const m = label.measure(b, opts.label, sty);
        const label_x = x + BOX + LABEL_GAP;
        const label_y = label.centered_top(y, BOX, m);
        _ = try label.render(b, label_x, label_y, opts.label, sty);
    }
    return sz;
}
