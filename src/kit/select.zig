const std = @import("std");
const types = @import("../window/types.zig");
const color = @import("../color.zig");
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
pub const Rgba = color.Rgba;
pub const Rect = [4]f32;
pub const SizeF = @import("../geometry.zig").SizeF;

pub const SelectItem = struct {
    id: []const u8,
    label: []const u8,
    disabled: bool = false,
};

pub const SelectGroup = struct {
    label: []const u8 = "", // empty = ungrouped (no header)
    items: []const SelectItem,
};

pub const SelectPosition = enum { item_aligned, popper };

pub const H: f32 = 36; // trigger height (a node wrapper measures to it)
const ROW_H: f32 = 32;
const GROUP_H: f32 = 26;
const PAD_V: f32 = 6;
const CHEVRON_H: f32 = 24; // scroll affordance band
const TRIGGER_PAD_X: f32 = 12;
const CHEVRON_GUTTER: f32 = 24; // right inset for the trigger chevron
const CHEVRON_PT: f32 = 11;
const ROW_INSET: f32 = 4; // row highlight/hitbox inset from panel edge
const ROW_LABEL_X: f32 = 30; // label x (past the checkmark gutter)
const ROW_CHECK_X: f32 = 9;
const CHECK_PT: f32 = 13;
const SCROLL_CHEV_W: f32 = 12; // chevron glyph width for centering
const GROUP_LABEL_H: f32 = 14; // group label cap height for centering
const ROW_FONT_DELTA: f32 = 1; // row text below base font
const GROUP_FONT_DELTA: f32 = 3; // group header below base font
const ELEV_PANEL: f32 = 0.05;
const ELEV_HOVER: f32 = 0.16;

pub const SelectOptions = struct {
    label: []const u8,
    open: bool = false,
    placeholder: bool = false, // render label muted (no value picked)
    disabled: bool = false,
    invalid: bool = false, // destructive border
    theme: *const Theme,
    paint: ?*custom_paint.PaintContext = null,
    on_click: ?callbacks.ClickFn = null,
    ctx: ?*anyopaque = null,
};

pub fn render(b: *RenderBuilder, x: f32, y: f32, w: f32, opts: SelectOptions) RenderError!SizeF {
    std.debug.assert(w >= 0); // drives box width + chevron x
    const theme = opts.theme;
    if (opts.paint != null and !opts.disabled) {
        try opts.paint.?.add_hitbox(.{
            .x = x,
            .y = y,
            .w = w,
            .h = H,
            .on_click = opts.on_click,
            .ctx = opts.ctx,
        });
    }

    var box = Quad.init(x, y, w, H);
    const border = if (opts.invalid)
        theme.destructive
    else if (opts.open)
        theme.ring
    else
        theme.border;
    const bg = if (opts.disabled) theme.muted else theme.background;
    _ = box.set_background(bg)
        .set_corner_radius(theme.radius - 2)
        .set_border_color(border)
        .set_border_width(if (opts.open or opts.invalid) 2 else 1);
    try b.append_quad(box);

    const fg = if (opts.disabled or opts.placeholder)
        theme.muted_foreground
    else if (opts.invalid)
        theme.destructive
    else
        theme.foreground;
    const sty = label.Style{ .font_size = theme.font_size, .weight = .normal, .color = fg };
    const m = label.measure(b, opts.label, sty);
    _ = try label.render(b, x + TRIGGER_PAD_X, label.centered_top(y, H, m), opts.label, sty);

    _ = try icon.render_icon_centered_y(b, x + w - CHEVRON_GUTTER, y, H, .chevron_down, .{
        .point_size = CHEVRON_PT,
        .weight = .light,
        .color = theme.muted_foreground,
    });
    return SizeF.init(w, H);
}

pub const MAX_GROUPS = 32;
pub const MAX_ITEMS = 128;

// Vertical-only band: one delta, vs the 2-axis callbacks.ScrollFn.
pub const ScrollDeltaFn = *const fn (ctx: ?*anyopaque, delta: f32) void;

const Shim = struct {
    on_select: ?callbacks.SelectIdFn,
    ctx: ?*anyopaque,
    id: []const u8,
};
const ScrollShim = struct {
    on_scroll: ?ScrollDeltaFn,
    ctx: ?*anyopaque,
    delta: f32,
};

// Caller-owned so the payloads outlive content(): a hitbox ctx is read on a
// later input event. Per-select state keeps two open selects from clobbering
// each other. Slab bounded by MAX_ITEMS (asserted).
pub const SelectState = struct {
    shims: [MAX_ITEMS]Shim = undefined,
    shim_len: usize = 0,
    up: ScrollShim = undefined,
    down: ScrollShim = undefined,
};

fn count_items(groups: []const SelectGroup) usize {
    var n: usize = 0;
    for (groups) |g| n += g.items.len;
    return n;
}

fn shim_select(ctx: ?*anyopaque) void {
    const s: *const Shim = @ptrCast(@alignCast(ctx orelse return));
    if (s.on_select) |cb| cb(s.ctx, s.id);
}
fn shim_scroll(ctx: ?*anyopaque) void {
    const s: *const ScrollShim = @ptrCast(@alignCast(ctx orelse return));
    if (s.on_scroll) |cb| cb(s.ctx, s.delta);
}

pub const SelectContentOptions = struct {
    groups: []const SelectGroup,
    selected_id: []const u8 = "",
    theme: *const Theme,
    paint: ?*custom_paint.PaintContext = null,
    on_select: ?callbacks.SelectIdFn = null,
    ctx: ?*anyopaque = null,
    position: SelectPosition = .item_aligned,
    trigger_x: f32,
    trigger_y: f32,
    trigger_w: f32,
    width: f32 = 0, // 0 = match trigger_w
    max_height: f32 = 280,
    scroll: f32 = 0, // px offset, caller-owned
    on_scroll: ?ScrollDeltaFn = null,
    // Combobox search box. Caller filters groups and overlays a native edit
    // field over search_rect(); the kit only renders what it's handed.
    search: bool = false,
    query: []const u8 = "",
};

pub const SEARCH_H: f32 = 42;
const SEARCH_FIELD_H: f32 = 20;

// Where the caller pins its native edit field: search-box text area, past the
// magnifier glyph.
pub fn search_rect(panel: Rect) Rect {
    return .{
        panel[0] + ROW_LABEL_X,
        panel[1] + (SEARCH_H - SEARCH_FIELD_H) / 2,
        panel[2] - ROW_LABEL_X - TRIGGER_PAD_X,
        SEARCH_FIELD_H,
    };
}

// Callers clamp a wheel-driven scroll offset against this vs max_height.
pub fn measure_height(groups: []const SelectGroup) f32 {
    std.debug.assert(groups.len <= MAX_GROUPS);
    var h: f32 = PAD_V * 2;
    for (groups) |g| {
        if (g.label.len > 0) h += GROUP_H;
        h += ROW_H * @as(f32, @floatFromInt(g.items.len));
    }
    return h;
}

const SelectLayout = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    search_h: f32,
    rows_h: f32,
    rows_y: f32,
    overflow: bool,
    max_scroll: f32,
    scroll: f32,
};

// Panel geometry + clamped scroll. y placement: a combobox / popper sits below the
// trigger; item_aligned shifts up so the selected row lands over the trigger.
fn place(opts: SelectContentOptions) SelectLayout {
    const w = if (opts.width > 0) opts.width else opts.trigger_w;
    const search_h: f32 = if (opts.search) SEARCH_H else 0;
    const rows_max = opts.max_height - search_h;
    const full = measure_height(opts.groups);
    const rows_h = @min(full, rows_max);
    const overflow = full > rows_h;
    const max_scroll = if (overflow) full - rows_h else 0;
    var y = opts.trigger_y + H + 4;
    if (opts.position == .item_aligned and !opts.search) {
        y = opts.trigger_y - PAD_V - selected_top(opts);
    }
    y = @max(y, 8); // keep on-screen below the titlebar band
    return .{
        .x = opts.trigger_x,
        .y = y,
        .w = w,
        .h = search_h + rows_h,
        .search_h = search_h,
        .rows_h = rows_h,
        .rows_y = y + search_h,
        .overflow = overflow,
        .max_scroll = max_scroll,
        .scroll = std.math.clamp(opts.scroll, 0, max_scroll),
    };
}

// Returns the panel rect for caller hit-testing / native overlays.
pub fn content(
    b: *RenderBuilder,
    state: *SelectState,
    opts: SelectContentOptions,
) RenderError!Rect {
    const item_count = count_items(opts.groups);
    std.debug.assert(opts.groups.len <= MAX_GROUPS);
    std.debug.assert(item_count <= MAX_ITEMS);
    const theme = opts.theme;
    const lay = place(opts);
    const x = lay.x;
    const y = lay.y;
    const w = lay.w;
    const h = lay.h;

    var bg = Quad.init(x, y, w, h);
    _ = bg.set_background(tr.elevate(theme, ELEV_PANEL)).set_corner_radius(theme.radius);
    try b.append_quad(bg);
    var bord = Quad.init(x, y, w, h);
    _ = bord.set_background(tr.transparent())
        .set_corner_radius(theme.radius)
        .set_border_color(theme.border)
        .set_border_width(1);
    try b.append_quad(bord);

    if (opts.search) try draw_search(b, x, y, w, opts);

    if (item_count == 0) {
        try draw_empty(b, opts, lay);
        return .{ x, y, w, h };
    }
    try draw_rows(b, state, opts, lay);
    return .{ x, y, w, h };
}

fn draw_empty(b: *RenderBuilder, opts: SelectContentOptions, lay: SelectLayout) !void {
    const theme = opts.theme;
    const sty = label.Style{
        .font_size = theme.font_size - ROW_FONT_DELTA,
        .weight = .normal,
        .color = theme.muted_foreground,
    };
    const msg = "No results found.";
    const m = label.measure(b, msg, sty);
    const msg_x = lay.x + (lay.w - m.width) / 2;
    _ = try label.render(b, msg_x, label.centered_top(lay.rows_y, lay.rows_h, m), msg, sty);
}

fn draw_rows(
    b: *RenderBuilder,
    state: *SelectState,
    opts: SelectContentOptions,
    lay: SelectLayout,
) !void {
    const theme = opts.theme;
    const x = lay.x;
    const w = lay.w;
    const rows_y = lay.rows_y;
    const rows_h = lay.rows_h;
    // Reserve a chevron band wherever there's more to scroll; rows clip between.
    const has_top = lay.overflow and lay.scroll > 0.5;
    const has_bot = lay.overflow and lay.scroll < lay.max_scroll - 0.5;
    const area_top = rows_y + (if (has_top) CHEVRON_H else PAD_V);
    const area_bot = lay.y + lay.h - (if (has_bot) CHEVRON_H else PAD_V);
    const area: [4]f32 = .{ x, area_top, w, area_bot - area_top };
    const spr0 = b.sprites.items.len;

    state.shim_len = 0;
    var ry = rows_y + PAD_V - lay.scroll;
    for (opts.groups) |grp| {
        if (grp.label.len > 0) {
            if (row_visible(ry, GROUP_H, rows_y, rows_h)) {
                const grp_y = ry + (GROUP_H - GROUP_LABEL_H) / 2;
                _ = try label.render(b, x + TRIGGER_PAD_X, grp_y, grp.label, .{
                    .font_size = theme.font_size - GROUP_FONT_DELTA,
                    .weight = .semi_bold,
                    .color = theme.muted_foreground,
                });
            }
            ry += GROUP_H;
        }
        for (grp.items) |it| {
            if (row_visible(ry, ROW_H, rows_y, rows_h))
                try draw_row(b, x, ry, w, it, state, opts, area);
            ry += ROW_H;
        }
    }
    // Clip row glyphs to the scrollable area: hides what scrolled past or
    // behind the chevron bands.
    for (b.sprites.items[spr0..]) |*s| s.clip_bounds = area;

    if (has_top) try scroll_band(b, x, rows_y, w, true, state, opts);
    if (has_bot) try scroll_band(b, x, lay.y + lay.h - CHEVRON_H, w, false, state, opts);
}

fn draw_search(b: *RenderBuilder, x: f32, y: f32, w: f32, opts: SelectContentOptions) !void {
    const theme = opts.theme;
    _ = try icon.render_icon_centered_y(b, x + TRIGGER_PAD_X, y, SEARCH_H, .search, .{
        .point_size = CHECK_PT,
        .color = theme.muted_foreground,
    });
    // Only the placeholder; the caller's native field draws the live query, so
    // drawing it here too would double it.
    if (opts.query.len == 0) {
        const sty = label.Style{
            .font_size = theme.font_size - ROW_FONT_DELTA,
            .weight = .normal,
            .color = theme.muted_foreground,
        };
        const m = label.measure(b, "Search...", sty);
        const sy = label.centered_top(y, SEARCH_H, m);
        _ = try label.render(b, x + ROW_LABEL_X, sy, "Search...", sty);
    }
    var sep = Quad.init(x, y + SEARCH_H - 1, w, 1);
    _ = sep.set_background(theme.border);
    try b.append_quad(sep);
}

fn selected_top(opts: SelectContentOptions) f32 {
    var top: f32 = PAD_V;
    for (opts.groups) |grp| {
        if (grp.label.len > 0) top += GROUP_H;
        for (grp.items) |it| {
            if (std.mem.eql(u8, it.id, opts.selected_id)) return top;
            top += ROW_H;
        }
    }
    return PAD_V;
}

fn row_visible(ry: f32, rh: f32, panel_y: f32, panel_h: f32) bool {
    return ry + rh > panel_y and ry < panel_y + panel_h;
}

fn draw_row(
    b: *RenderBuilder,
    x: f32,
    ry: f32,
    w: f32,
    it: SelectItem,
    state: *SelectState,
    opts: SelectContentOptions,
    area: [4]f32,
) !void {
    const theme = opts.theme;
    const selected = std.mem.eql(u8, it.id, opts.selected_id);
    var hovered = false;
    if (opts.paint != null and !it.disabled and ry >= area[1] and ry + ROW_H <= area[1] + area[3]) {
        const p = opts.paint.?;
        hovered = p.is_hovered(x + ROW_INSET, ry, w - ROW_INSET * 2, ROW_H);
        std.debug.assert(state.shim_len < state.shims.len);
        state.shims[state.shim_len] = .{
            .on_select = opts.on_select,
            .ctx = opts.ctx,
            .id = it.id,
        };
        try p.add_hitbox(.{
            .x = x + ROW_INSET,
            .y = ry,
            .w = w - ROW_INSET * 2,
            .h = ROW_H,
            .on_click = shim_select,
            .ctx = @ptrCast(&state.shims[state.shim_len]),
        });
        state.shim_len += 1;
    }
    if (hovered) {
        var hl = Quad.init(x + ROW_INSET, ry, w - ROW_INSET * 2, ROW_H);
        _ = hl.set_background(tr.elevate(theme, ELEV_HOVER))
            .set_corner_radius(theme.radius - 3)
            .set_clip_bounds(area);
        try b.append_quad(hl);
    }
    const fg = if (it.disabled)
        theme.muted_foreground
    else if (hovered)
        theme.accent_foreground
    else
        theme.popover_foreground;
    const sty = label.Style{
        .font_size = theme.font_size - ROW_FONT_DELTA,
        .weight = .normal,
        .color = fg,
    };
    const m = label.measure(b, it.label, sty);
    _ = try label.render(b, x + ROW_LABEL_X, label.centered_top(ry, ROW_H, m), it.label, sty);
    if (selected) _ = try icon.render_icon_centered_y(b, x + ROW_CHECK_X, ry, ROW_H, .check, .{
        .point_size = CHECK_PT,
        .weight = .semi_bold,
        .color = fg,
    });
}

fn scroll_band(
    b: *RenderBuilder,
    x: f32,
    y: f32,
    w: f32,
    up: bool,
    state: *SelectState,
    opts: SelectContentOptions,
) !void {
    const theme = opts.theme;
    var band = Quad.init(x + 1, y, w - 2, CHEVRON_H);
    _ = band.set_background(tr.elevate(theme, ELEV_PANEL)).set_corner_radius(0);
    try b.append_quad(band);
    const step: f32 = ROW_H * 3;
    if (opts.paint) |p| {
        const sh: *ScrollShim = if (up) &state.up else &state.down;
        sh.* = .{ .on_scroll = opts.on_scroll, .ctx = opts.ctx, .delta = if (up) -step else step };
        try p.add_hitbox(.{
            .x = x,
            .y = y,
            .w = w,
            .h = CHEVRON_H,
            .on_click = shim_scroll,
            .ctx = @ptrCast(sh),
        });
    }
    const chev: icon.Icon = if (up) .chevron_up else .chevron_down;
    const chev_x = x + (w - SCROLL_CHEV_W) / 2;
    _ = try icon.render_icon_centered_y(b, chev_x, y, CHEVRON_H, chev, .{
        .point_size = CHEVRON_PT,
        .weight = .semi_bold,
        .color = theme.muted_foreground,
    });
}
