const std = @import("std");
const types = @import("../window/types.zig");
const color = @import("../color.zig");
const builder = @import("../render/builder.zig");
const RenderError = builder.RenderError;
const label = @import("../render/label.zig");
const icon = @import("../render/icon.zig");
const primitives = @import("../primitives.zig");
const custom_paint = @import("../window/paint.zig");
const tr = @import("theme_resolve.zig");

pub const RenderBuilder = builder.RenderBuilder;
pub const Theme = types.Theme;
pub const Rgba = color.Rgba;
pub const Quad = primitives.Quad;
pub const SizeF = @import("../geometry.zig").SizeF;

// One open page = one closeable tab (browser / API-client strip).
pub const TabItem = struct {
    id: []const u8,
    title: []const u8,
    icon: ?icon.Icon = null,
    // Always shown; only the title ellipsizes when space is tight.
    prefix: []const u8 = "",
    prefix_color: ?Rgba = null, // null = muted_foreground
    dirty: bool = false, // unsaved -> a dot that swaps to the close x on hover
    // A pin glyph replaces the close x so a pinned tab can't be closed by
    // accident; clicking it fires on_pin. Caller keeps pinned tabs at the
    // front and clamps reorder so they stay grouped.
    pinned: bool = false,
};

pub const TabSelectFn = *const fn (ctx: ?*anyopaque, index: usize) void;
pub const TabCloseFn = *const fn (ctx: ?*anyopaque, index: usize) void;
pub const TabNewFn = *const fn (ctx: ?*anyopaque) void;
pub const TabMoveFn = *const fn (ctx: ?*anyopaque, from: usize, to: usize) void;
pub const TabPinFn = *const fn (ctx: ?*anyopaque, index: usize) void;
// Right-click on a tab body, with the pointer position so the caller can
// anchor a context menu at the cursor (close others / close right, etc).
pub const TabContextFn = *const fn (ctx: ?*anyopaque, index: usize, x: f32, y: f32) void;

pub const TabBarOptions = struct {
    tabs: []const TabItem,
    active: usize = 0,
    theme: *const Theme,
    paint: ?*custom_paint.PaintContext = null,
    on_select: ?TabSelectFn = null,
    on_close: ?TabCloseFn = null,
    on_new: ?TabNewFn = null, // null = no trailing + button
    // Set to enable drag-to-reorder. Kit owns the gesture + ghost + drop line
    // and reports the proposed index move; caller reorders its own list.
    on_move: ?TabMoveFn = null,
    on_pin: ?TabPinFn = null,
    on_context: ?TabContextFn = null,
    ctx: ?*anyopaque = null,
    height: f32 = 36,
    scroll_x: f32 = 0, // caller-owned horizontal pan; clamped on render
    min_tab_w: f32 = 120, // shrink floor; past it the strip scrolls
    max_tab_w: f32 = 220, // grow ceiling so few tabs don't stretch edge-to-edge
    // Title point size; 0 = the theme's font_size. The prefix chip renders 2pt
    // smaller and bold, matching a sidebar's method-label look.
    label_size: f32 = 0,
};

fn title_size(opts: *const TabBarOptions) f32 {
    return if (opts.label_size > 0) opts.label_size else opts.theme.font_size;
}

pub const NEW_BTN_W: f32 = 36;
pub const MAX_TABS = 32;

const PAD_X: f32 = 10; // tab content inset
const ICON_SZ: f32 = 16;
const CLOSE_SZ: f32 = 18; // close hit slot (square)
const GAP: f32 = 6;
const ACTIVE_LINE_H: f32 = 2; // bottom accent under the active tab
const ACTIVE_ELEV: f32 = 0.06; // active-tab surface lift over the strip track
const DOT_SZ: f32 = 7; // dirty indicator
const DRAG_THRESHOLD: f32 = 4;
const GHOST_OPACITY: f32 = 0.85;

// A hitbox's ctx points at a slab Shim that back-points to its owning state,
// and the slabs live inside that state. So the state must never be moved or
// copied after the first render or every back-pointer dangles: keep it in
// stable storage (a fixed var), never returned by value.
const Shim = struct { state: *TabBarState, index: usize, title: []const u8 };
const Slot = struct { x: f32, w: f32 };

// Caller-owned so two tab strips never clobber each other. The slabs, slot
// table, and title buffers are per-frame scratch, but their contents must
// outlive render: a hitbox's ctx and the slots are read on a later input
// event. Drag state persists across frames (one drag at a time). Slabs
// bounded by MAX_TABS (asserted).
pub const TabBarState = struct {
    tab_shims: [MAX_TABS]Shim = undefined,
    close_shims: [MAX_TABS]Shim = undefined,
    shim_len: usize = 0,
    slots: [MAX_TABS]Slot = undefined,
    slot_len: usize = 0,
    title_bufs: [MAX_TABS][96]u8 = undefined,
    on_select: ?TabSelectFn = null,
    on_close: ?TabCloseFn = null,
    on_new: ?TabNewFn = null,
    on_move: ?TabMoveFn = null,
    on_pin: ?TabPinFn = null,
    on_context: ?TabContextFn = null,
    ctx: ?*anyopaque = null,
    drag_pending: bool = false,
    drag_active: bool = false,
    drag_idx: usize = 0,
    drag_title: []const u8 = "",
    press_x: f32 = 0,
    drag_x: f32 = 0,
    drop_idx: usize = 0, // insertion index (0..n)
    has_drop: bool = false,
};

fn select_click(ctx: ?*anyopaque) void {
    const s: *const Shim = @ptrCast(@alignCast(ctx orelse return));
    if (s.state.on_select) |cb| cb(s.state.ctx, s.index);
}

fn close_click(ctx: ?*anyopaque) void {
    const s: *const Shim = @ptrCast(@alignCast(ctx orelse return));
    if (s.state.on_close) |cb| cb(s.state.ctx, s.index);
}

fn new_click(ctx: ?*anyopaque) void {
    const st: *TabBarState = @ptrCast(@alignCast(ctx orelse return));
    if (st.on_new) |cb| cb(st.ctx);
}

fn pin_click(ctx: ?*anyopaque) void {
    const s: *const Shim = @ptrCast(@alignCast(ctx orelse return));
    if (s.state.on_pin) |cb| cb(s.state.ctx, s.index);
}

fn tab_context(ctx: ?*anyopaque, x: f32, y: f32) void {
    const s: *const Shim = @ptrCast(@alignCast(ctx orelse return));
    if (s.state.on_context) |cb| cb(s.state.ctx, s.index, x, y);
}

// Middle-click a tab closes it, routed through the same on_close as the X button.
fn tab_middle(ctx: ?*anyopaque) void {
    const s: *const Shim = @ptrCast(@alignCast(ctx orelse return));
    if (s.state.on_close) |cb| cb(s.state.ctx, s.index);
}

fn tab_point(ctx: ?*anyopaque, x: f32, y: f32) void {
    _ = y;
    const s: *const Shim = @ptrCast(@alignCast(ctx orelse return));
    const st = s.state;
    if (!st.drag_pending and !st.drag_active) {
        st.drag_pending = true;
        st.drag_active = false;
        st.drag_idx = s.index;
        st.drag_title = s.title;
        st.press_x = x;
        st.drag_x = x;
        return;
    }
    st.drag_x = x;
    if (@abs(x - st.press_x) > DRAG_THRESHOLD) st.drag_active = true;
}

fn tab_drop(ctx: ?*anyopaque) void {
    const s: *const Shim = @ptrCast(@alignCast(ctx orelse return));
    const st = s.state;
    if (st.drag_active) {
        if (st.has_drop) {
            // insertion index past the source collapses to a no-op move
            const to = if (st.drop_idx > st.drag_idx) st.drop_idx - 1 else st.drop_idx;
            if (to != st.drag_idx) {
                if (st.on_move) |cb| cb(st.ctx, st.drag_idx, to);
            }
        }
    } else if (st.drag_pending) {
        if (st.on_select) |cb| cb(st.ctx, st.drag_idx);
    }
    st.drag_pending = false;
    st.drag_active = false;
    st.has_drop = false;
}

// Resolve the insertion index from the pointer x over the slot table: left
// half of a slot inserts before it, right half after.
fn compute_drop(state: *TabBarState) void {
    state.has_drop = false;
    var i: usize = 0;
    while (i < state.slot_len) : (i += 1) {
        const sl = state.slots[i];
        if (state.drag_x < sl.x or state.drag_x >= sl.x + sl.w) continue;
        const rel = (state.drag_x - sl.x) / sl.w;
        state.drop_idx = if (rel < 0.5) i else i + 1;
        state.has_drop = true;
        return;
    }
    if (state.slot_len > 0) {
        const last = state.slots[state.slot_len - 1];
        if (state.drag_x >= last.x + last.w) {
            state.drop_idx = state.slot_len;
            state.has_drop = true;
        }
    }
}

// Longest prefix of title that fits max_w with a trailing ellipsis; returns
// the title untouched when it already fits. Steps back over UTF-8 continuation
// bytes so a multibyte glyph is never split.
fn fit_title(
    b: *RenderBuilder,
    state: *TabBarState,
    idx: usize,
    title: []const u8,
    sty: label.Style,
    max_w: f32,
) []const u8 {
    if (max_w <= 0) return "";
    if (label.measure(b, title, sty).width <= max_w) return title;
    const ell = "\u{2026}";
    const buf = &state.title_bufs[idx];
    const maxn = @min(title.len, buf.len - ell.len);

    // Binary search the longest byte prefix whose prefix+ellipsis still fits, then
    // snap down to a codepoint boundary. O(log n) shapes, not O(n) - a tab title
    // re-fits every frame. lo always fits; the final snap can only narrow it, so
    // the result never overflows even if a probe split a codepoint.
    var lo: usize = 0;
    var hi: usize = maxn;
    while (lo < hi) {
        const mid = lo + (hi - lo + 1) / 2;
        @memcpy(buf[0..mid], title[0..mid]);
        @memcpy(buf[mid .. mid + ell.len], ell);
        if (label.measure(b, buf[0 .. mid + ell.len], sty).width <= max_w) {
            lo = mid;
        } else {
            hi = mid - 1;
        }
    }
    var n = lo;
    while (n > 0 and n < title.len and title[n] & 0xC0 == 0x80) n -= 1;
    if (n == 0) return ell;
    @memcpy(buf[0..n], title[0..n]);
    @memcpy(buf[n .. n + ell.len], ell);
    return buf[0 .. n + ell.len];
}

pub fn render(
    b: *RenderBuilder,
    x: f32,
    y: f32,
    w: f32,
    state: *TabBarState,
    opts: TabBarOptions,
) RenderError!SizeF {
    const theme = opts.theme;
    const h = opts.height;
    std.debug.assert(w > 0);
    std.debug.assert(opts.tabs.len <= MAX_TABS);

    state.shim_len = 0;
    state.slot_len = 0;
    state.on_select = opts.on_select;
    state.on_close = opts.on_close;
    state.on_new = opts.on_new;
    state.on_move = opts.on_move;
    state.on_pin = opts.on_pin;
    state.on_context = opts.on_context;
    state.ctx = opts.ctx;

    var track = Quad.init(x, y, w, h);
    _ = track.set_background(theme.card);
    try b.append_quad(track);
    var base = Quad.init(x, y + h - 1, w, 1);
    _ = base.set_background(theme.border);
    try b.append_quad(base);

    const new_w: f32 = if (opts.on_new != null) NEW_BTN_W else 0;
    const band = @max(0, w - new_w);
    const n = opts.tabs.len;
    if (n == 0) {
        try render_new(b, state, &opts, x + band, y, h);
        return SizeF.init(w, h);
    }

    const nf: f32 = @floatFromInt(n);
    const tab_w = std.math.clamp(band / nf, opts.min_tab_w, opts.max_tab_w);
    const content_w = tab_w * nf;
    const max_scroll = @max(0, content_w - band);
    const scroll = std.math.clamp(opts.scroll_x, 0, max_scroll);

    const spr0 = b.sprites.items.len;
    const prim0 = b.prims.items.len;
    for (opts.tabs, 0..) |tab, i| {
        const tx = x + @as(f32, @floatFromInt(i)) * tab_w - scroll;
        if (tx + tab_w <= x or tx >= x + band) continue; // fully scrolled out
        std.debug.assert(state.slot_len < state.slots.len);
        state.slots[state.slot_len] = .{ .x = tx, .w = tab_w };
        state.slot_len += 1;
        const is_src = opts.on_move != null and state.drag_active and i == state.drag_idx;
        try render_tab(b, state, &opts, tab, i, tx, y, tab_w, h, is_src);
    }

    if (opts.on_move != null and state.drag_active) {
        compute_drop(state);
        try render_drag_visuals(b, state, &opts, x, y, h, tab_w, scroll);
    }

    // Clip tab glyphs and quads to the band so a scrolled-out tab can't bleed
    // past the strip edges. Intersect so a per-tab title clip survives.
    // Track/base quads and the + button sit before prim0/spr0 so they stay crisp.
    const area: [4]f32 = .{ x, y, band, h };
    for (b.sprites.items[spr0..]) |*sp| sp.clip_bounds = tr.clip_intersect(sp.clip_bounds, area);
    for (b.prims.items[prim0..]) |*p| switch (p.*) {
        .quad => |*q| q.clip_bounds = tr.clip_intersect(q.clip_bounds, area),
        else => {},
    };

    try render_new(b, state, &opts, x + band, y, h);
    return SizeF.init(w, h);
}

fn render_tab(
    b: *RenderBuilder,
    state: *TabBarState,
    opts: *const TabBarOptions,
    tab: TabItem,
    i: usize,
    tx: f32,
    y: f32,
    tab_w: f32,
    h: f32,
    is_src: bool,
) !void {
    const theme = opts.theme;
    const active = i == opts.active;
    const p = opts.paint;
    const hovered = if (p) |pp| pp.is_hovered(tx, y, tab_w, h) else false;

    if (active) {
        // Elevated surface (the track shares the background colour in dark, so a
        // bare fill would be invisible and the underline would look detached).
        var fill = Quad.init(tx, y, tab_w, h);
        _ = fill.set_background(tr.elevate(theme, ACTIVE_ELEV));
        try b.append_quad(fill);
        var line = Quad.init(tx, y + h - ACTIVE_LINE_H, tab_w, ACTIVE_LINE_H);
        _ = line.set_background(theme.primary);
        try b.append_quad(line);
    } else if (hovered and !is_src) {
        var hl = Quad.init(tx, y, tab_w, h);
        _ = hl.set_background(theme.muted);
        try b.append_quad(hl);
    }
    if (!active) {
        // Full-height divider on the tab's right edge (flush with the strip's top
        // and bottom borders), so tabs read as adjacent cells rather than floating.
        var sep = Quad.init(tx + tab_w - 1, y, 1, h);
        _ = sep.set_background(theme.border);
        try b.append_quad(sep);
    }

    if (is_src) {
        // Skip glyphs so the source slot reads as the lifted tab while the
        // ghost trails the cursor.
        var ph = Quad.init(tx + 2, y + GAP, tab_w - 4, h - GAP * 2);
        _ = ph.set_background(theme.muted).set_corner_radius(theme.radius - 2);
        try b.append_quad(ph);
        try push_tab_hit(state, opts, tab, i, tx, y, tab_w, h);
        if (opts.paint != null) state.shim_len += 1;
        return;
    }

    var content_x = tx + PAD_X;
    if (tab.icon) |ic| {
        const iy = y + (h - ICON_SZ) / 2;
        const fg = if (active) theme.foreground else theme.muted_foreground;
        _ = try icon.render_icon_centered_xy(
            b,
            content_x,
            iy,
            ICON_SZ,
            ICON_SZ,
            ic,
            .{ .point_size = ICON_SZ, .color = fg },
        );
        content_x += ICON_SZ + GAP;
    }

    const close_x = tx + tab_w - PAD_X - CLOSE_SZ;
    const text_x0 = content_x;
    const text_right = close_x - GAP;
    const t0 = b.sprites.items.len;

    if (tab.prefix.len > 0) {
        const psty = label.Style{
            .font_size = title_size(opts) - 2,
            .weight = .bold,
            .color = tab.prefix_color orelse theme.muted_foreground,
        };
        const pm = label.measure(b, tab.prefix, psty);
        _ = try label.render(b, content_x, label.centered_top(y, h, pm), tab.prefix, psty);
        content_x += pm.width + GAP;
    }

    const sty = label.Style{
        .font_size = title_size(opts),
        .weight = if (active) .semi_bold else .medium,
        .color = if (active) theme.foreground else theme.muted_foreground,
    };
    // Reserve the close/dot slot, then ellipsize the title to what's left so a
    // long name never runs under it.
    const text_w = @max(0, text_right - content_x);
    const shown = fit_title(b, state, i, tab.title, sty, text_w);
    const m = label.measure(b, shown, sty);
    _ = try label.render(b, content_x, label.centered_top(y, h, m), shown, sty);
    // Clip prefix + title to the whole text column as a backstop against rounding.
    const tclip: [4]f32 = .{ text_x0, y, @max(0, text_right - text_x0), h };
    for (b.sprites.items[t0..]) |*sp| sp.clip_bounds = tclip;

    // Tab-body hitbox first so the close hitbox added below wins in its
    // sub-rect (hit-test walks newest-first). Both share one slab slot,
    // incremented once at the end.
    try push_tab_hit(state, opts, tab, i, tx, y, tab_w, h);

    const cy = y + (h - CLOSE_SZ) / 2;
    if (tab.pinned) {
        if (p) |pp| {
            if (pp.is_hovered(close_x, cy, CLOSE_SZ, CLOSE_SZ)) {
                var pbtn = Quad.init(close_x, cy, CLOSE_SZ, CLOSE_SZ);
                _ = pbtn.set_background(theme.muted).set_corner_radius(CLOSE_SZ / 2);
                try b.append_quad(pbtn);
            }
        }
        const pfg = if (active) theme.foreground else theme.muted_foreground;
        _ = try icon.render_icon_centered_xy(
            b,
            close_x,
            cy,
            CLOSE_SZ,
            CLOSE_SZ,
            .pin,
            .{ .point_size = 11, .color = pfg },
        );
        if (p) |pp| {
            std.debug.assert(state.shim_len < state.close_shims.len);
            state.close_shims[state.shim_len] = .{ .state = state, .index = i, .title = tab.title };
            try pp.add_hitbox(.{
                .x = close_x,
                .y = cy,
                .w = CLOSE_SZ,
                .h = CLOSE_SZ,
                .on_click = pin_click,
                .ctx = @ptrCast(&state.close_shims[state.shim_len]),
            });
        }
    } else if (active or hovered) {
        if (p) |pp| {
            if (pp.is_hovered(close_x, cy, CLOSE_SZ, CLOSE_SZ)) {
                var cbtn = Quad.init(close_x, cy, CLOSE_SZ, CLOSE_SZ);
                _ = cbtn.set_background(theme.muted).set_corner_radius(CLOSE_SZ / 2);
                try b.append_quad(cbtn);
            }
        }
        _ = try icon.render_icon_centered_xy(
            b,
            close_x,
            cy,
            CLOSE_SZ,
            CLOSE_SZ,
            .close,
            .{ .point_size = 10, .color = theme.foreground },
        );
        if (p) |pp| {
            std.debug.assert(state.shim_len < state.close_shims.len);
            state.close_shims[state.shim_len] = .{ .state = state, .index = i, .title = tab.title };
            try pp.add_hitbox(.{
                .x = close_x,
                .y = cy,
                .w = CLOSE_SZ,
                .h = CLOSE_SZ,
                .on_click = close_click,
                .ctx = @ptrCast(&state.close_shims[state.shim_len]),
            });
        }
    } else if (tab.dirty) {
        const dx = close_x + (CLOSE_SZ - DOT_SZ) / 2;
        const dy = y + (h - DOT_SZ) / 2;
        var dot = Quad.init(dx, dy, DOT_SZ, DOT_SZ);
        _ = dot.set_background(theme.muted_foreground).set_corner_radius(DOT_SZ / 2);
        try b.append_quad(dot);
    }
    if (p != null) state.shim_len += 1;
}

// Drag-capturing when reorder is on (click vs drag decided on release), plain
// click otherwise. Writes its slab slot but does NOT advance shim_len; the
// caller shares the slot with the close hitbox and bumps once.
fn push_tab_hit(
    state: *TabBarState,
    opts: *const TabBarOptions,
    tab: TabItem,
    i: usize,
    tx: f32,
    y: f32,
    tab_w: f32,
    h: f32,
) !void {
    const p = opts.paint orelse return;
    std.debug.assert(state.shim_len < state.tab_shims.len);
    state.tab_shims[state.shim_len] = .{ .state = state, .index = i, .title = tab.title };
    const ctx: ?*anyopaque = @ptrCast(&state.tab_shims[state.shim_len]);
    if (opts.on_move != null) {
        try p.add_hitbox(.{
            .x = tx,
            .y = y,
            .w = tab_w,
            .h = h,
            .on_point = tab_point,
            .on_drag_end = tab_drop,
            .on_context = tab_context,
            .on_middle = tab_middle,
            .ctx = ctx,
        });
    } else {
        try p.add_hitbox(.{
            .x = tx,
            .y = y,
            .w = tab_w,
            .h = h,
            .on_click = select_click,
            .on_context = tab_context,
            .on_middle = tab_middle,
            .ctx = ctx,
        });
    }
}

fn render_new(
    b: *RenderBuilder,
    state: *TabBarState,
    opts: *const TabBarOptions,
    nx: f32,
    y: f32,
    h: f32,
) !void {
    if (opts.on_new == null) return;
    const theme = opts.theme;
    const p = opts.paint;
    if (p) |pp| {
        if (pp.is_hovered(nx, y, NEW_BTN_W, h)) {
            const s = CLOSE_SZ + 4;
            var hl = Quad.init(nx + (NEW_BTN_W - s) / 2, y + (h - s) / 2, s, s);
            _ = hl.set_background(theme.muted).set_corner_radius(s / 2);
            try b.append_quad(hl);
        }
    }
    _ = try icon.render_icon_centered_xy(
        b,
        nx,
        y,
        NEW_BTN_W,
        h,
        .plus,
        .{ .point_size = 12, .color = theme.muted_foreground },
    );
    if (p) |pp| try pp.add_hitbox(.{
        .x = nx,
        .y = y,
        .w = NEW_BTN_W,
        .h = h,
        .on_click = new_click,
        .ctx = @ptrCast(state),
    });
}

// Drop indicator at the insertion gap plus a ghost tab trailing the cursor.
// The ghost label sits in the clipped sprite range so it can't spill past the
// band edges.
fn render_drag_visuals(
    b: *RenderBuilder,
    state: *TabBarState,
    opts: *const TabBarOptions,
    x: f32,
    y: f32,
    h: f32,
    tab_w: f32,
    scroll: f32,
) !void {
    const theme = opts.theme;
    if (state.has_drop) {
        const lx = x + @as(f32, @floatFromInt(state.drop_idx)) * tab_w - scroll;
        var line = Quad.init(lx - 1, y + GAP, ACTIVE_LINE_H, h - GAP * 2);
        _ = line.set_background(theme.primary).set_corner_radius(ACTIVE_LINE_H / 2);
        try b.append_quad(line);
    }
    const gx = state.drag_x - tab_w / 2;
    var ghost_bg = theme.accent;
    ghost_bg.a *= GHOST_OPACITY;
    var gbg = Quad.init(gx, y + GAP, tab_w, h - GAP * 2);
    _ = gbg.set_background(ghost_bg)
        .set_corner_radius(theme.radius - 2)
        .set_border_color(theme.ring)
        .set_border_width(1);
    try b.append_quad(gbg);
    const sty = label.Style{
        .font_size = title_size(opts),
        .weight = .medium,
        .color = theme.accent_foreground,
    };
    const m = label.measure(b, state.drag_title, sty);
    _ = try label.render(
        b,
        gx + PAD_X,
        label.centered_top(y + GAP, h - GAP * 2, m),
        state.drag_title,
        sty,
    );
}

// Caller clamps its own scroll_x pan to this.
pub fn max_scroll_x(opts: TabBarOptions, w: f32) f32 {
    const new_w: f32 = if (opts.on_new != null) NEW_BTN_W else 0;
    const band = @max(0, w - new_w);
    const n = opts.tabs.len;
    if (n == 0) return 0;
    const nf: f32 = @floatFromInt(n);
    const tab_w = std.math.clamp(band / nf, opts.min_tab_w, opts.max_tab_w);
    return @max(0, tab_w * nf - band);
}
