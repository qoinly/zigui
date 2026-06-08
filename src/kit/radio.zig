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

pub const RadioOptions = struct {
    selected: bool = false,
    label: []const u8 = "",
    disabled: bool = false,
    invalid: bool = false,
    theme: *const Theme,
    paint: ?*custom_paint.PaintContext = null,
    on_select: ?callbacks.ClickFn = null,
    ctx: ?*anyopaque = null,
};

const DOT: f32 = 18;
const LABEL_GAP: f32 = 8;
const INNER: f32 = 8;

// Label is measured at .medium to match the weight render uses; mismatched
// weight here would drift the reported width from the drawn glyphs.
pub fn measure(b: *RenderBuilder, proposal: SizeProposal, opts: RadioOptions) SizeF {
    _ = proposal;
    const lm = label.measure(b, opts.label, .{
        .font_size = opts.theme.font_size,
        .weight = .medium,
    });
    const label_w: f32 = if (opts.label.len > 0) LABEL_GAP + lm.width else 0;
    return SizeF.init(DOT + label_w, DOT);
}

// One radio only; grouping and exclusive selection are the caller's job.
pub fn render(b: *RenderBuilder, x: f32, y: f32, opts: RadioOptions) RenderError!SizeF {
    const theme = opts.theme;
    const sz = measure(b, .{}, opts);
    var hovered = false;
    if (opts.paint != null and !opts.disabled) {
        const p = opts.paint.?;
        hovered = p.is_hovered(x, y, sz.width, DOT);
        try p.add_hitbox(.{
            .x = x,
            .y = y,
            .w = sz.width,
            .h = DOT,
            .on_click = opts.on_select,
            .ctx = opts.ctx,
        });
    }

    const a: f32 = if (opts.disabled) tr.DISABLED_ALPHA else 1;
    var ring = Quad.init(x, y, DOT, DOT);
    const bc = if (opts.invalid)
        theme.destructive
    else if (opts.selected)
        theme.primary
    else if (hovered)
        theme.ring
    else
        theme.border;
    _ = ring.set_background(tr.transparent())
        .set_corner_radius(DOT / 2)
        .set_border_color(tr.fade(bc, a))
        .set_border_width(1.5);
    try b.append_quad(ring);

    if (opts.selected) {
        var dot = Quad.init(x + (DOT - INNER) / 2, y + (DOT - INNER) / 2, INNER, INNER);
        _ = dot.set_background(tr.fade(theme.primary, a)).set_corner_radius(INNER / 2);
        try b.append_quad(dot);
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
        const ty = label.centered_top(y, DOT, m);
        _ = try label.render(b, x + DOT + LABEL_GAP, ty, opts.label, sty);
    }
    return sz;
}
