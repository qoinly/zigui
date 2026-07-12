const std = @import("std");
const types = @import("../window/types.zig");
const builder = @import("../render/builder.zig");
const RenderError = builder.RenderError;
const label = @import("../render/label.zig");
const icon = @import("../render/icon.zig");
const kbd = @import("kbd.zig");
const primitives = @import("../primitives.zig");
const custom_paint = @import("../window/paint.zig");
const tr = @import("theme_resolve.zig");
const callbacks = @import("../callbacks.zig");

pub const RenderBuilder = builder.RenderBuilder;
pub const Theme = types.Theme;
pub const Quad = primitives.Quad;

// (x, y, w, h) bounding box of every panel drawn (root + open flyouts). The
// renderer flushes glyphs after all quads, so a panel quad alone can't hide
// body text; the caller masks body glyphs behind this whole rect in one pass.
pub const Rect = [4]f32;

pub const ItemKind = enum { item, separator, label, checkbox, radio, submenu };

pub const MenuEntry = struct {
    kind: ItemKind = .item,
    id: []const u8 = "",
    label: []const u8 = "",
    // Leading icon. On a plain item it replaces the check slot; on a checked radio
    // it makes a select-style option (icon leads, the check moves to the trailing edge).
    icon: ?icon.Icon = null,
    shortcut: []const u8 = "", // right-aligned text hint, e.g. a caller-formatted "Cmd X"
    keys: []const []const u8 = &.{}, // right-aligned kbd chips (takes precedence over shortcut)
    checked: bool = false,
    disabled: bool = false,
    destructive: bool = false, // red text; red fill on hover
    children: []const MenuEntry = &.{},
};

pub const MenuOptions = struct {
    items: []const MenuEntry,
    theme: *const Theme,
    paint: ?*custom_paint.PaintContext = null,
    on_select: ?callbacks.SelectIdFn = null,
    ctx: ?*anyopaque = null,
    min_width: f32 = 200,
    // Edge-flip region; a 0 extent disables that axis. Pass the content rect,
    // not the whole window, so the menu can't flip onto the chrome.
    view_x: f32 = 0,
    view_y: f32 = 0,
    view_w: f32 = 0,
    view_h: f32 = 0,
    // Caller-owned vertical scroll, used only when the menu is taller than its
    // region (a long menu in a short window). Clamped to [0, max] on render;
    // feed it from the wheel while the menu is open. maxScrollY() reports max.
    scroll_y: f32 = 0,
};

pub const MAX_ITEMS = 64;
pub const MAX_DEPTH = 4;

const PAD_V: f32 = 5;
const ROW_H: f32 = 30;
const SEP_H: f32 = 9;
const SIDE: f32 = 8;
const ROW_INSET: f32 = 4;
const LEAD_SLOT: f32 = 22; // check / icon column
const CHEVRON_SLOT: f32 = 16;
const SHORTCUT_GAP: f32 = 24;
const FONT_DELTA: f32 = 1;
const ICON_PT: f32 = 14;
const CHECK_PT: f32 = 13;
const RADIO_R: f32 = 3;
const ELEV_PANEL: f32 = 0.05;
const ELEV_HOVER: f32 = 0.16;
// overlap parent so the cursor crossing the gap doesn't dismiss the flyout
const FLYOUT_OVERLAP: f32 = 4;

const ClickShim = struct {
    on_select: ?callbacks.SelectIdFn,
    ctx: ?*anyopaque,
    id: []const u8,
};

// Caller-owned across frames: a hitbox's ctx is read on a later input event, so
// each payload in the slab must outlive render. open_path tracks the open flyout
// per depth by trigger id, so the pointer can cross a trigger into its flyout
// without it closing; caller-owned so two menus never clobber each other. Call
// reset() on open to collapse stale flyouts.
pub const MenuState = struct {
    shims: [MAX_ITEMS]ClickShim = undefined,
    shim_len: usize = 0,
    open_path: [MAX_DEPTH][]const u8 = .{ "", "", "", "" },

    pub fn reset(self: *MenuState) void {
        for (&self.open_path) |*p| p.* = "";
    }
};

fn swallow(_: ?*anyopaque) void {}

fn shim_click(ctx: ?*anyopaque) void {
    const s: *const ClickShim = @ptrCast(@alignCast(ctx orelse return));
    if (s.on_select) |cb| cb(s.ctx, s.id);
}

fn any_lead(items: []const MenuEntry) bool {
    for (items) |it| {
        const mark = it.kind == .checkbox or it.kind == .radio;
        if (mark or it.icon != null) return true;
    }
    return false;
}

fn panel_width(b: *RenderBuilder, opts: *const MenuOptions, items: []const MenuEntry) f32 {
    const sty = label.Style{
        .font_size = opts.theme.font_size - FONT_DELTA,
        .weight = .normal,
        .color = opts.theme.popover_foreground,
    };
    const lead: f32 = if (any_lead(items)) LEAD_SLOT else 0;
    var w = opts.min_width;
    for (items) |it| {
        if (it.kind == .separator) continue;
        const m = label.measure(b, it.label, sty);
        var trail: f32 = 0;
        if (it.kind == .submenu) {
            trail = CHEVRON_SLOT;
        } else if (it.keys.len > 0) {
            trail = kbd.measure(b, .{}, it.keys, .{ .theme = opts.theme, .size = .sm }).width + SHORTCUT_GAP;
        } else if (it.shortcut.len > 0) {
            trail = label.measure(b, it.shortcut, sty).width + SHORTCUT_GAP;
        }
        w = @max(w, lead + m.width + trail + SIDE * 2);
    }
    return w;
}

fn panel_height(items: []const MenuEntry) f32 {
    var h = PAD_V * 2;
    for (items) |it| h += if (it.kind == .separator) SEP_H else ROW_H;
    return h;
}

pub fn render(
    b: *RenderBuilder,
    ax: f32,
    ay: f32,
    state: *MenuState,
    opts: MenuOptions,
) RenderError!Rect {
    std.debug.assert(opts.items.len > 0);
    std.debug.assert(opts.items.len <= MAX_ITEMS);
    const w = panel_width(b, &opts, opts.items);
    const h = panel_height(opts.items);
    var x = ax;
    var y = ay;
    if (opts.view_w > 0) {
        if (x + w > opts.view_x + opts.view_w) x = opts.view_x + opts.view_w - w;
        if (x < opts.view_x) x = opts.view_x;
    }
    // Too tall for the region: pin to the top and scroll; otherwise flip.
    var scroll: f32 = 0;
    var clip: [4]f32 = .{ 0, 0, 0, 0 }; // w == 0 disables clipping
    if (opts.view_w > 0 and opts.view_h > 0) {
        clip = .{ opts.view_x, opts.view_y, opts.view_w, opts.view_h };
    }
    if (opts.view_h > 0) {
        if (h > opts.view_h) {
            y = opts.view_y;
            scroll = std.math.clamp(opts.scroll_y, 0, h - opts.view_h);
        } else {
            if (y + h > opts.view_y + opts.view_h) y = opts.view_y + opts.view_h - h;
            if (y < opts.view_y) y = opts.view_y;
        }
    }
    state.shim_len = 0;
    var bounds: [4]f32 = .{ x, y, x + w, y + h };
    try render_panel(b, &opts, state, &bounds, x, y, w, opts.items, 0, scroll, clip);
    return .{ bounds[0], bounds[1], bounds[2] - bounds[0], bounds[3] - bounds[1] };
}

// max(0, content height - region height); the caller clamps its wheel pan here.
pub fn max_scroll_y(items: []const MenuEntry, view_h: f32) f32 {
    if (view_h <= 0) return 0;
    return @max(0, panel_height(items) - view_h);
}

// Per-panel geometry passed to the row helpers (all in points).
const PanelView = struct {
    x: f32,
    w: f32,
    lead: f32,
    depth: usize,
    vis_top: f32,
    vis_bot: f32,
};

// A submenu flyout recorded during the row loop, drawn after the panel's own
// clip so it always sits on top.
const Flyout = struct {
    items: []const MenuEntry,
    cx: f32,
    cy: f32,
    cw: f32,
};

const ItemDraw = struct { advance: f32, flyout: ?Flyout = null };

// Panel bg + border + the click-swallow hitbox over the visible band (so dead
// areas don't fall through to the dismiss scrim), and grow the overall bounds.
fn draw_panel_chrome(
    b: *RenderBuilder,
    opts: *const MenuOptions,
    bounds: *[4]f32,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    vis_top: f32,
    vis_bot: f32,
) RenderError!void {
    const theme = opts.theme;
    bounds[0] = @min(bounds[0], x);
    bounds[1] = @min(bounds[1], @max(y, vis_top));
    bounds[2] = @max(bounds[2], x + w);
    bounds[3] = @max(bounds[3], @min(y + h, vis_bot));
    var bg = Quad.init(x, y, w, h);
    _ = bg.set_background(tr.elevate(theme, ELEV_PANEL)).set_corner_radius(theme.radius);
    try b.append_quad(bg);
    var border = Quad.init(x, y, w, h);
    _ = border.set_background(tr.transparent())
        .set_corner_radius(theme.radius)
        .set_border_color(theme.border)
        .set_border_width(1);
    try b.append_quad(border);
    if (opts.paint) |p| {
        const sh = @min(y + h, vis_bot) - @max(y, vis_top);
        if (sh > 0) try p.add_hitbox(.{
            .x = x,
            .y = @max(y, vis_top),
            .w = w,
            .h = sh,
            .on_click = swallow,
        });
    }
}

// Leading glyph in the reserved slot: a check, a radio dot, or the item icon
// (mutually exclusive).
fn draw_row_lead(
    b: *RenderBuilder,
    it: MenuEntry,
    x: f32,
    ry: f32,
    fg: tr.Rgba,
) RenderError!void {
    if (it.kind == .checkbox and it.checked) {
        const check_x = x + (LEAD_SLOT - CHECK_PT) / 2 + 2;
        _ = try icon.render_icon_centered_y(b, check_x, ry, ROW_H, .check, .{
            .point_size = CHECK_PT,
            .color = fg,
        });
        // A radio with an icon is a select-style option: the icon leads here and the
        // check moves to the trailing edge (draw_row_trailing). Only an icon-less
        // radio keeps the minimalist leading dot.
    } else if (it.kind == .radio and it.checked and it.icon == null) {
        const dot_x = x + LEAD_SLOT / 2 - RADIO_R + 2;
        const dot_y = ry + ROW_H / 2 - RADIO_R;
        var dot = Quad.init(dot_x, dot_y, RADIO_R * 2, RADIO_R * 2);
        _ = dot.set_background(fg).set_corner_radius(RADIO_R);
        try b.append_quad(dot);
    } else if (it.icon != null) {
        _ = try icon.render_icon_centered_y(b, x + SIDE, ry, ROW_H, it.icon.?, .{
            .point_size = ICON_PT,
            .color = fg,
        });
    }
}

// Trailing affordance: a submenu chevron, or a right-aligned shortcut hint.
fn draw_row_trailing(
    b: *RenderBuilder,
    theme: *const Theme,
    it: MenuEntry,
    x: f32,
    w: f32,
    ry: f32,
    fg: tr.Rgba,
    hovered: bool,
    tsty: label.Style,
) RenderError!void {
    if (it.kind == .radio and it.checked and it.icon != null) {
        // Select-style option: leading icon, trailing check for the current choice.
        const ck_x = x + w - SIDE - CHECK_PT;
        _ = try icon.render_icon_centered_y(b, ck_x, ry, ROW_H, .check, .{
            .point_size = CHECK_PT,
            .color = fg,
        });
    } else if (it.kind == .submenu) {
        const chev_x = x + w - SIDE - CHEVRON_SLOT + 2;
        _ = try icon.render_icon_centered_y(b, chev_x, ry, ROW_H, .chevron_right, .{
            .point_size = ICON_PT - 1,
            .color = fg,
        });
    } else if (it.keys.len > 0) {
        const kopts = kbd.KbdOptions{ .theme = theme, .size = .sm };
        const km = kbd.measure(b, .{}, it.keys, kopts);
        const kx = x + w - SIDE - km.width;
        const ky = ry + (ROW_H - km.height) / 2;
        _ = try kbd.render(b, kx, ky, it.keys, kopts);
    } else if (it.shortcut.len > 0) {
        var sc = tsty;
        const sc_hl = hovered and !it.destructive;
        sc.color = if (sc_hl) theme.accent_foreground else theme.muted_foreground;
        if (it.disabled) sc.color.a *= 0.45;
        const sm = label.measure(b, it.shortcut, sc);
        const sm_x = x + w - SIDE - sm.width;
        const sm_y = ry + (ROW_H - (sm.ascent + sm.descent)) / 2;
        _ = try label.render(b, sm_x, sm_y, it.shortcut, sc);
    }
}

// Click slot for a selectable (non-submenu) row, confined to the visible band so
// a partially-scrolled row isn't clickable below the fold. The shim slab is
// shared across the root + every flyout; once full a row just goes click-less.
fn add_row_hitbox(
    opts: *const MenuOptions,
    state: *MenuState,
    it: MenuEntry,
    row_x: f32,
    row_w: f32,
    ry: f32,
    vis_top: f32,
    vis_bot: f32,
) RenderError!void {
    const p = opts.paint orelse return;
    const row_vis = ry + ROW_H > vis_top and ry < vis_bot;
    const has_slot = state.shim_len < state.shims.len;
    if (it.disabled or it.kind == .submenu or !row_vis or !has_slot) return;
    state.shims[state.shim_len] = .{ .on_select = opts.on_select, .ctx = opts.ctx, .id = it.id };
    const hy = @max(ry, vis_top);
    const hh = @min(ry + ROW_H, vis_bot) - hy;
    try p.add_hitbox(.{
        .x = row_x,
        .y = hy,
        .w = row_w,
        .h = hh,
        .on_click = shim_click,
        .ctx = @ptrCast(&state.shims[state.shim_len]),
    });
    state.shim_len += 1;
}

// Position of an open submenu's flyout (flip-left + clamp to the view), or null.
fn flyout_for(
    b: *RenderBuilder,
    opts: *const MenuOptions,
    state: *MenuState,
    it: MenuEntry,
    x: f32,
    w: f32,
    ry: f32,
    depth: usize,
) ?Flyout {
    const is_open = std.mem.eql(u8, state.open_path[depth], it.id);
    const can_nest = depth + 1 < MAX_DEPTH;
    if (!(it.kind == .submenu and it.children.len > 0 and is_open and can_nest)) return null;
    const cw = panel_width(b, opts, it.children);
    const ch = panel_height(it.children);
    var cx = x + w - FLYOUT_OVERLAP;
    if (opts.view_w > 0 and cx + cw > opts.view_x + opts.view_w) {
        cx = @max(opts.view_x, x - cw + FLYOUT_OVERLAP);
    }
    var cy = ry - PAD_V;
    if (opts.view_h > 0 and cy + ch > opts.view_y + opts.view_h) {
        cy = opts.view_y + opts.view_h - ch;
    }
    if (opts.view_h > 0 and cy < opts.view_y) cy = opts.view_y;
    return .{ .items = it.children, .cx = cx, .cy = cy, .cw = cw };
}

// One menu row: separator / label / interactive item. Returns the row's height
// advance and, for an open submenu, the flyout to draw after the loop.
fn draw_item(
    b: *RenderBuilder,
    opts: *const MenuOptions,
    state: *MenuState,
    it: MenuEntry,
    pv: PanelView,
    ry: f32,
) RenderError!ItemDraw {
    const theme = opts.theme;
    if (it.kind == .separator) {
        var line = Quad.init(pv.x + SIDE, ry + SEP_H / 2, pv.w - SIDE * 2, 1);
        _ = line.set_background(theme.border);
        try b.append_quad(line);
        return .{ .advance = SEP_H };
    }
    if (it.kind == .label) {
        const sty = label.Style{
            .font_size = theme.font_size - FONT_DELTA - 1,
            .weight = .semi_bold,
            .color = theme.muted_foreground,
        };
        const m = label.measure(b, it.label, sty);
        const ly = ry + (ROW_H - (m.ascent + m.descent)) / 2;
        _ = try label.render(b, pv.x + SIDE, ly, it.label, sty);
        return .{ .advance = ROW_H };
    }
    const row_x = pv.x + ROW_INSET;
    const row_w = pv.w - ROW_INSET * 2;
    const row_vis = ry + ROW_H > pv.vis_top and ry < pv.vis_bot;
    var hovered = false;
    if (opts.paint) |p| {
        if (!it.disabled and row_vis) hovered = p.is_hovered(row_x, ry, row_w, ROW_H);
    }
    if (hovered) {
        state.open_path[pv.depth] = if (it.kind == .submenu) it.id else "";
        var d = pv.depth + 1;
        while (d < MAX_DEPTH) : (d += 1) state.open_path[d] = "";
        var hl = Quad.init(row_x, ry, row_w, ROW_H);
        const hbg = if (it.destructive) theme.destructive else tr.elevate(theme, ELEV_HOVER);
        _ = hl.set_background(hbg).set_corner_radius(theme.radius - 3);
        try b.append_quad(hl);
    }
    var fg = if (it.destructive) theme.destructive else theme.popover_foreground;
    if (hovered) fg = if (it.destructive) theme.destructive_foreground else theme.accent_foreground;
    if (it.disabled) fg.a *= 0.45;

    try draw_row_lead(b, it, pv.x, ry, fg);
    const tsty = label.Style{
        .font_size = theme.font_size - FONT_DELTA,
        .weight = .normal,
        .color = fg,
    };
    const tm = label.measure(b, it.label, tsty);
    const tm_y = ry + (ROW_H - (tm.ascent + tm.descent)) / 2;
    _ = try label.render(b, pv.x + SIDE + pv.lead, tm_y, it.label, tsty);
    try draw_row_trailing(b, theme, it, pv.x, pv.w, ry, fg, hovered, tsty);
    try add_row_hitbox(opts, state, it, row_x, row_w, ry, pv.vis_top, pv.vis_bot);
    const fly = flyout_for(b, opts, state, it, pv.x, pv.w, ry, pv.depth);
    return .{ .advance = ROW_H, .flyout = fly };
}

// Draw the recorded flyout on top, then mask any of THIS panel's glyphs the
// flyout sits over (a cramped flip-left overlaps the parent; glyphs flush after
// quads, so the opaque flyout bg alone can't hide them).
fn draw_flyout(
    b: *RenderBuilder,
    opts: *const MenuOptions,
    state: *MenuState,
    bounds: *[4]f32,
    f: Flyout,
    depth: usize,
    clip: [4]f32,
    x: f32,
    w: f32,
    spr0: usize,
) RenderError!void {
    const child_spr0 = b.sprites.items.len;
    try render_panel(b, opts, state, bounds, f.cx, f.cy, f.cw, f.items, depth + 1, 0, clip);
    const cr_w = @max(f.cw, x + w - f.cx);
    const cr: [4]f32 = .{ f.cx, f.cy, cr_w, panel_height(f.items) };
    for (b.sprites.items[spr0..child_spr0]) |*s| {
        const sx = s.position[0];
        const sy = s.position[1];
        const overlap_x = sx + s.size[0] > cr[0] and sx < cr[0] + cr[2];
        const overlap_y = sy + s.size[1] > cr[1] and sy < cr[1] + cr[3];
        if (overlap_x and overlap_y) s.clip_bounds = .{ 0, 0, 0, 0 };
    }
}

fn render_panel(
    b: *RenderBuilder,
    opts: *const MenuOptions,
    state: *MenuState,
    bounds: *[4]f32,
    x: f32,
    y: f32,
    w: f32,
    items: []const MenuEntry,
    depth: usize,
    scroll: f32,
    clip: [4]f32,
) !void {
    std.debug.assert(depth < MAX_DEPTH);
    std.debug.assert(items.len <= MAX_ITEMS);
    const h = panel_height(items);
    const clipping = clip[2] > 0;
    // Visible band the panel is confined to (the region when clipping, else all).
    const vis_top = if (clipping) clip[1] else y;
    const vis_bot = if (clipping) clip[1] + clip[3] else y + h;

    const prim0 = b.prims.items.len;
    const spr0 = b.sprites.items.len;
    try draw_panel_chrome(b, opts, bounds, x, y, w, h, vis_top, vis_bot);

    const pv = PanelView{
        .x = x,
        .w = w,
        .lead = if (any_lead(items)) LEAD_SLOT else 0,
        .depth = depth,
        .vis_top = vis_top,
        .vis_bot = vis_bot,
    };
    var pend: ?Flyout = null;
    var ry = y + PAD_V - scroll;
    for (items) |it| {
        const d = try draw_item(b, opts, state, it, pv, ry);
        if (d.flyout) |fly| pend = fly;
        ry += d.advance;
    }

    // Confine this panel's quads + glyphs to the visible band BEFORE the flyout
    // draws, so the flyout stays unclipped-by-us and on top.
    if (clipping) {
        for (b.prims.items[prim0..]) |*pp| switch (pp.*) {
            .quad => |*q| q.clip_bounds = tr.clip_intersect(q.clip_bounds, clip),
            else => {},
        };
        for (b.sprites.items[spr0..]) |*sp| {
            sp.clip_bounds = tr.clip_intersect(sp.clip_bounds, clip);
        }
    }

    if (pend) |f| try draw_flyout(b, opts, state, bounds, f, depth, clip, x, w, spr0);
}
