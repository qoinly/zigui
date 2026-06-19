// A bottom navigation bar: a persistent row of 3-5 destinations (icon + label) that
// switches top-level sections. A tap calls on_select with the index. The widget is
// platform-agnostic; the engine renders each platform's bottom-nav idiom, and this is
// the Android pass (the iOS pass draws the tab bar instead).
//
// Two layouts: `standard` is the full-width bar flush at the screen bottom with a 1px
// top border; `floating` is a detached, fully rounded card inset from the edges with a
// soft drop shadow. Either way `indicator` highlights the active destination (here, a
// pill behind the icon). The bar's background fills the bottom safe area so it reaches
// the screen edge under the system nav.

const std = @import("std");
const types = @import("../window/types.zig");
const builder = @import("../render/builder.zig");
const RenderError = builder.RenderError;
const label = @import("../render/label.zig");
const icon_render = @import("../render/icon.zig");
const primitives = @import("../primitives.zig");
const custom_paint = @import("../window/paint.zig");
const callbacks = @import("../callbacks.zig");

pub const RenderBuilder = builder.RenderBuilder;
pub const Theme = types.Theme;
pub const Quad = primitives.Quad;
pub const Icon = icon_render.Icon;
pub const Rgba = @import("../color.zig").Rgba;
const SizeF = @import("../geometry.zig").SizeF;

// The items' band height in points (the Android pass uses the platform's 64dp bar);
// the safe area extends the background below it.
pub const BAR_H: f32 = 64;
// The floating card's inset from the left/right/bottom edges.
pub const FLOAT_MARGIN: f32 = 12;
// Bottom bars top out at 5 destinations across platforms; one slot of slack.
pub const MAX_ITEMS = 6;

pub const Style = enum {
    standard, // full-width band flush at the bottom edge
    floating, // detached rounded card, inset and elevated
};

// A hitbox's ctx is read on a later input event, so each item's payload must outlive
// the render call - the caller owns this slab (the tabs pattern), so two bars never
// clobber each other and rendering stays reentrant. Bounded by MAX_ITEMS (asserted).
const Shim = struct { on_select: ?callbacks.SelectFn, ctx: ?*anyopaque, index: usize };

pub const State = struct {
    shims: [MAX_ITEMS]Shim = undefined,
    shim_len: usize = 0,
};

pub const Item = struct {
    icon: Icon,
    label: []const u8,
};

pub const Options = struct {
    items: []const Item, // borrowed for the frame; the slice must outlive the render call

    active: usize = 0,
    style: Style = .standard,
    indicator: bool = true, // highlight the active destination (a pill in this pass)
    // Background height added below the band for the system nav inset, so it reaches
    // the screen edge; the items and their hitboxes stay in the top BAR_H.
    safe_bottom: f32 = 0,
    // Colors - null derives from the theme. The surface defaults to the theme's
    // `secondary` (a distinct elevated tone), since some themes set card == background;
    // the caller overrides any of these to match its own palette.
    surface: ?Rgba = null, // the band / floating card fill
    active_color: ?Rgba = null, // active icon + label
    inactive_color: ?Rgba = null, // inactive icon + label
    indicator_color: ?Rgba = null, // the active-indicator pill fill
    theme: *const Theme,
    paint: ?*custom_paint.PaintContext = null,
    on_select: ?callbacks.SelectFn = null,
    ctx: ?*anyopaque = null,
};

// The layout height the leaf reserves: the items' band only (plus the floating gap).
// safe_bottom is NOT counted here - it extends the standard surface DOWNWARD past the
// band, into the inset, so the bar fills to the screen edge while the items stay in
// the top BAR_H above the system nav. The items sit at the bottom of the safe area.
pub fn height(style: Style) f32 {
    return BAR_H + if (style == .floating) FLOAT_MARGIN else 0;
}

fn shim_click(ctx: ?*anyopaque) void {
    const s: *const Shim = @ptrCast(@alignCast(ctx orelse return));
    if (s.on_select) |cb| cb(s.ctx, s.index);
}

pub fn render(
    b: *RenderBuilder,
    x: f32,
    y: f32,
    w: f32,
    state: *State,
    opts: Options,
) RenderError!SizeF {
    const theme = opts.theme;
    std.debug.assert(w > 0);
    std.debug.assert(opts.items.len > 0);
    std.debug.assert(opts.items.len <= MAX_ITEMS);

    const fg = theme.foreground;
    const surface = opts.surface orelse theme.secondary;
    const active_c = opts.active_color orelse fg;
    const inactive_c = opts.inactive_color orelse theme.muted_foreground;
    const indicator_c = opts.indicator_color orelse
        Rgba{ .r = fg.r, .g = fg.g, .b = fg.b, .a = 0.12 };

    const floating = opts.style == .floating;
    const m: f32 = if (floating) FLOAT_MARGIN else 0;
    const bx = x + m;
    const bw = w - m * 2;
    std.debug.assert(bw > 0);

    if (floating) {
        const radius = BAR_H / 2; // a fully rounded capsule card
        // Soft elevation: a wide low-alpha halo under a tighter contact shadow.
        var halo = Quad.init(bx - 5, y + 5, bw + 10, BAR_H);
        _ = halo.set_background(.{ .r = 0, .g = 0, .b = 0, .a = 0.06 });
        _ = halo.set_corner_radius(radius + 5);
        try b.append_quad(halo);
        var contact = Quad.init(bx, y + 6, bw, BAR_H);
        _ = contact.set_background(.{ .r = 0, .g = 0, .b = 0, .a = 0.16 });
        _ = contact.set_corner_radius(radius);
        try b.append_quad(contact);
        // An elevated surface distinct from the page background.
        var card = Quad.init(bx, y, bw, BAR_H);
        _ = card.set_background(surface).set_corner_radius(radius);
        try b.append_quad(card);
    } else {
        var band = Quad.init(x, y, w, BAR_H + opts.safe_bottom);
        _ = band.set_background(surface);
        try b.append_quad(band);
        var sep = Quad.init(x, y, w, 1); // a 1px top border (the app_bar idiom)
        _ = sep.set_background(theme.border);
        try b.append_quad(sep);
    }

    state.shim_len = 0;
    const n: f32 = @floatFromInt(opts.items.len);
    const seg = bw / n;
    const icon_size: f32 = 24;
    const gap: f32 = 6; // between the icon and its label (the native bar's airier spacing)
    const pill_h: f32 = 32; // the indicator pill, taller than the icon
    // Center the icon + label group vertically in the band: measure the label line
    // height (font-fixed, text-independent) so the group, not just the icon, centers.
    const lm0 = label.measure(b, "Ag", .{ .font_size = 12 });
    const group_h = icon_size + gap + lm0.ascent + lm0.descent;
    const icon_top = y + (BAR_H - group_h) / 2;
    const label_top = icon_top + icon_size + gap;
    const pill_top = icon_top + (icon_size - pill_h) / 2; // pill centered on the icon
    for (opts.items, 0..) |item, i| {
        const sx = bx + @as(f32, @floatFromInt(i)) * seg;
        const cx = sx + seg / 2;
        const active = i == opts.active;

        if (opts.paint) |p| {
            std.debug.assert(state.shim_len < state.shims.len);
            state.shims[state.shim_len] = .{
                .on_select = opts.on_select,
                .ctx = opts.ctx,
                .index = i,
            };
            try p.add_hitbox(.{
                .x = sx,
                .y = y,
                .w = seg,
                .h = BAR_H,
                .on_click = shim_click,
                .ctx = @ptrCast(&state.shims[state.shim_len]),
            });
            state.shim_len += 1;
        }

        if (active and opts.indicator) {
            const pill_w = @max(0, @min(seg - 8, 56)); // never negative on a tiny segment
            var pill = Quad.init(cx - pill_w / 2, pill_top, pill_w, pill_h);
            _ = pill.set_background(indicator_c);
            _ = pill.set_corner_radius(pill_h / 2);
            try b.append_quad(pill);
        }

        const tint = if (active) active_c else inactive_c;
        _ = try icon_render.render_icon_centered_xy(b, sx, icon_top, seg, icon_size, item.icon, .{
            .point_size = 21,
            .color = tint,
        });
        const sty = label.Style{
            .font_size = 12,
            .weight = if (active) .semi_bold else .medium,
            .color = tint,
        };
        const lm = label.measure(b, item.label, sty);
        _ = try label.render(b, cx - lm.width / 2, label_top, item.label, sty);
    }
    return SizeF.init(w, height(opts.style));
}
