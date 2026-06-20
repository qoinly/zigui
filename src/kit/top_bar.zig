// The iOS top navigation bar. Content scrolls under it (edge-to-edge per Apple's HIG);
// the frost is the scroll edge effect. It floats (reserves no flow space). Several
// native styles via `style`: a small inline title, or a large title that either
// collapses to the inline one as the body scrolls, stays put while a frost ramps in, or
// fades away entirely as the body scrolls down.

const std = @import("std");
const builtin = @import("builtin");
const types = @import("../window/types.zig");
const builder = @import("../render/builder.zig");
const RenderError = builder.RenderError;
const label = @import("../render/label.zig");
const icon_render = @import("../render/icon.zig");
const callbacks = @import("../callbacks.zig");
const custom_paint = @import("../window/paint.zig");
const custom_shell = @import("../custom_shell.zig");
const node = @import("../node.zig");
const primitives = @import("../primitives.zig");
const Quad = primitives.Quad;

pub const RenderBuilder = builder.RenderBuilder;
pub const Theme = types.Theme;
const SizeF = @import("../geometry.zig").SizeF;
const Rgba = @import("../color.zig").Rgba;
pub const ScrollState = node.ScrollState;

const IOS_NAV_H: f32 = 44; // the small nav-title row, below the status bar
const IOS_LARGE_H: f32 = 48; // the large-title row, below the nav row
const SEARCH_H: f32 = 52; // the sticky search-field row, below the nav row
const ios_title = Rgba{ .r = 0.96, .g = 0.96, .b = 0.98, .a = 1 };
const ios_muted = Rgba{ .r = 0.62, .g = 0.62, .b = 0.66, .a = 1 };

pub const Style = enum {
    none, // no nav title (the page supplies its own, e.g. inside the content)
    inline_, // a small centered title, always frosted
    large, // a large title that collapses to the small one as the body scrolls
    large_sticky, // a large title that stays put; a frost ramps in as content scrolls under
    large_hide, // a large title that fades away entirely as the body scrolls down
};

pub const Icon = icon_render.Icon;

pub const Options = struct {
    title: []const u8,
    style: Style = .inline_,
    scroll: ?*ScrollState = null, // the scrolled body; drives the collapse
    frost: bool = true, // a full-width frosted nav background (the scroll edge effect)
    search: ?[]const u8 = null, // a sticky search field below the nav (placeholder text)
    on_back: ?callbacks.ClickFn = null, // a circle glass back button at the left
    on_action: ?callbacks.ClickFn = null, // an optional circle glass action button, right
    action_icon: ?Icon = null, // the action button's glyph
    ctx: ?*anyopaque = null,
    theme: *const Theme,
    paint: ?*custom_paint.PaintContext = null,
};

const CIRCLE_D: f32 = 44; // the glass circle buttons' diameter (the iOS nav touch target)

// iOS floats the bar (no flow space); other platforms reserve the nav row.
pub fn height() f32 {
    return if (builtin.os.tag == .ios) 0 else IOS_NAV_H;
}

pub fn render(b: *RenderBuilder, x: f32, y: f32, w: f32, opts: Options) RenderError!SizeF {
    std.debug.assert(w > 0);
    if (builtin.os.tag != .ios) return SizeF.init(w, IOS_NAV_H);
    _ = y;
    const top: f32 = @floatCast(custom_shell.safe_area_insets().top);
    std.debug.assert(top >= 0);
    const offset = if (opts.scroll) |s| s.y else 0;
    const collapse = std.math.clamp(offset / IOS_LARGE_H, 0, 1); // 0 expanded, 1 collapsed
    // For the collapsing large title: it fades over the first part of the scroll; the frost
    // + small title ramp in only after it is gone, so a visible large title never sits on a
    // card. Sticky keeps the large title and ramps the frost in on any scroll; hide fades
    // the whole bar (and its frost) away.
    const frost_strength: f32 = switch (opts.style) {
        .none, .inline_ => 1,
        .large => std.math.clamp((collapse - 0.6) / 0.4, 0, 1),
        .large_sticky => std.math.clamp(offset / 12, 0, 1),
        .large_hide => 0,
    };
    const small_a: f32 = switch (opts.style) {
        .inline_ => 1,
        .none, .large_sticky, .large_hide => 0,
        .large => frost_strength,
    };
    const large_a: f32 = switch (opts.style) {
        .none, .inline_ => 0,
        .large_sticky => 1,
        .large => std.math.clamp(1 - collapse / 0.6, 0, 1),
        .large_hide => std.math.clamp(1 - collapse, 0, 1),
    };
    // The search field fades with the bar in the hide style; otherwise it stays put (pinned).
    const search_a: f32 = if (opts.style == .large_hide) large_a else 1;
    // A full-width frosted nav background (configurable): the scroll edge effect. A search
    // field extends it to cover the field's row too.
    const nav_frost_h = top + IOS_NAV_H + (if (opts.search != null) SEARCH_H else 0);
    if (opts.frost) {
        if (opts.paint) |p| add_frost(p, b, .{ x, 0, w, nav_frost_h, 0, frost_strength });
    }
    try render_titles(b, x, w, top, opts.title, small_a, large_a);
    if (opts.search) |placeholder| {
        if (search_a > 0.01) try render_search(b, x, w, top, placeholder, search_a);
    }
    // Circle glass buttons (additive, any style): back at the left, optional action right.
    if (opts.on_back) |cb| try circle_button(b, x + 16, top + 6, .chevron_left, cb, opts);
    if (opts.on_action) |cb| {
        const ax = x + w - 16 - CIRCLE_D;
        if (opts.action_icon) |ic| try circle_button(b, ax, top + 6, ic, cb, opts);
    }
    return SizeF.init(w, 0);
}

// The small centered nav-row title (fades in with the frost) and the large left-aligned
// title (the iOS idiom); each draws only while its alpha is meaningful.
fn render_titles(
    b: *RenderBuilder,
    x: f32,
    w: f32,
    top: f32,
    title: []const u8,
    small_a: f32,
    large_a: f32,
) RenderError!void {
    if (small_a > 0.01) {
        const c = fade(ios_title, small_a);
        const sty = label.Style{ .font_size = 17, .weight = .semi_bold, .color = c };
        const lm = label.measure(b, title, sty);
        const ty = top + (IOS_NAV_H - (lm.ascent + lm.descent)) / 2;
        _ = try label.render(b, x + w / 2 - lm.width / 2, ty, title, sty);
    }
    if (large_a > 0.01) {
        const c = fade(ios_title, large_a);
        const sty = label.Style{ .font_size = 32, .weight = .bold, .color = c };
        _ = try label.render(b, x + 20, top + 8, title, sty);
    }
}

// A sticky search field below the nav row (over the frost): the search-tab idiom. Its
// alpha lets it fade out with the bar in the hide style.
fn render_search(
    b: *RenderBuilder,
    x: f32,
    w: f32,
    top: f32,
    placeholder: []const u8,
    alpha: f32,
) RenderError!void {
    const sy = top + IOS_NAV_H + 6;
    const fh: f32 = SEARCH_H - 16;
    var field = Quad.init(x + 16, sy, w - 32, fh);
    _ = field.set_background(.{ .r = 1, .g = 1, .b = 1, .a = 0.14 * alpha });
    _ = field.set_corner_radius(10);
    try b.append_quad(field);
    const isz: f32 = 18;
    const muted = fade(ios_muted, alpha);
    const iy = sy + (fh - isz) / 2;
    _ = try icon_render.render_icon_centered_xy(b, x + 24, iy, isz, isz, .search, .{
        .point_size = 16,
        .color = muted,
    });
    const sty = label.Style{ .font_size = 15, .weight = .medium, .color = muted };
    const lm = label.measure(b, placeholder, sty);
    const ty = sy + (fh - (lm.ascent + lm.descent)) / 2;
    _ = try label.render(b, x + 24 + isz + 8, ty, placeholder, sty);
}

fn add_frost(p: *custom_paint.PaintContext, b: *RenderBuilder, rect: [6]f32) void {
    // The frame's first frost rect marks the backdrop split (everything so far blurs
    // under the bars); the rest append.
    if (p.frost_count == 0) {
        p.backdrop_prims = @intCast(b.prims.items.len);
        p.backdrop_sprites = @intCast(b.sprites.items.len);
        p.backdrop_color = @intCast(b.color_sprites.items.len);
    }
    if (p.frost_count < p.frost_rects.len) {
        p.frost_rects[p.frost_count] = rect;
        p.frost_count += 1;
    }
}

// A circle Liquid-Glass button (the modern iOS nav idiom): a frosted disc + a glyph,
// sticky over the scrolling content.
fn circle_button(
    b: *RenderBuilder,
    cx: f32,
    cy: f32,
    icon: Icon,
    cb: callbacks.ClickFn,
    opts: Options,
) RenderError!void {
    std.debug.assert(CIRCLE_D > 0);
    if (opts.paint) |p| {
        add_frost(p, b, .{ cx, cy, CIRCLE_D, CIRCLE_D, CIRCLE_D / 2, 1 });
        try p.add_hitbox(
            .{ .x = cx, .y = cy, .w = CIRCLE_D, .h = CIRCLE_D, .on_click = cb, .ctx = opts.ctx },
        );
    }
    const isz: f32 = 24;
    const iy = cy + (CIRCLE_D - isz) / 2;
    _ = try icon_render.render_icon_centered_xy(b, cx, iy, CIRCLE_D, isz, icon, .{
        .point_size = 21,
        .color = ios_title,
    });
}

fn fade(c: Rgba, a: f32) Rgba {
    std.debug.assert(a >= 0);
    return .{ .r = c.r, .g = c.g, .b = c.b, .a = c.a * a };
}
