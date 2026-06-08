const types = @import("../window/types.zig");
const builder = @import("../render/builder.zig");
const callbacks = @import("../callbacks.zig");
const RenderError = builder.RenderError;
const label = @import("../render/label.zig");
const primitives = @import("../primitives.zig");
const custom_paint = @import("../window/paint.zig");
const tr = @import("theme_resolve.zig");

pub const RenderBuilder = builder.RenderBuilder;
pub const Theme = types.Theme;
pub const Quad = primitives.Quad;
pub const SizeF = @import("../geometry.zig").SizeF;
pub const SizeProposal = @import("../geometry.zig").SizeProposal;

pub const SwitchOptions = struct {
    on: bool = false,
    label: []const u8 = "",
    disabled: bool = false,
    invalid: bool = false,
    theme: *const Theme,
    paint: ?*custom_paint.PaintContext = null,
    on_toggle: ?callbacks.ToggleFn = null,
    ctx: ?*anyopaque = null,
};

const W: f32 = 38;
const H: f32 = 22;
const LABEL_GAP: f32 = 10;

pub fn measure(b: *RenderBuilder, proposal: SizeProposal, opts: SwitchOptions) SizeF {
    _ = proposal;
    const label_sty = label.Style{ .font_size = opts.theme.font_size, .weight = .medium };
    const label_w: f32 = if (opts.label.len > 0)
        LABEL_GAP + label.measure(b, opts.label, label_sty).width
    else
        0;
    return SizeF.init(W + label_w, H);
}

pub fn render(b: *RenderBuilder, x: f32, y: f32, opts: SwitchOptions) RenderError!SizeF {
    const theme = opts.theme;
    if (opts.paint != null and !opts.disabled) {
        try opts.paint.?.add_hitbox(.{
            .x = x,
            .y = y,
            .w = W,
            .h = H,
            .on_click = opts.on_toggle,
            .ctx = opts.ctx,
        });
    }

    const a: f32 = if (opts.disabled) tr.DISABLED_ALPHA else 1;
    var track = Quad.init(x, y, W, H);
    const track_bg = if (opts.on) theme.primary else theme.input;
    _ = track.set_background(tr.fade(track_bg, a)).set_corner_radius(H / 2);
    if (opts.invalid) _ = track.set_border_color(theme.destructive).set_border_width(2);
    try b.append_quad(track);

    const knob: f32 = H - 4;
    const kx = if (opts.on) x + W - knob - 2 else x + 2;
    var knob_q = Quad.init(kx, y + 2, knob, knob);
    _ = knob_q.set_background(tr.fade(theme.background, a)).set_corner_radius(knob / 2);
    try b.append_quad(knob_q);

    if (opts.label.len > 0) {
        const col = if (opts.disabled)
            theme.muted_foreground
        else if (opts.invalid)
            theme.destructive
        else
            theme.foreground;
        const sty = label.Style{ .font_size = theme.font_size, .weight = .medium, .color = col };
        const m = label.measure(b, opts.label, sty);
        _ = try label.render(b, x + W + LABEL_GAP, label.centered_top(y, H, m), opts.label, sty);
    }
    return measure(b, .{}, opts);
}
