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
const callbacks = @import("../callbacks.zig");
const resizable = @import("resizable.zig");

pub const RenderBuilder = builder.RenderBuilder;
pub const Theme = types.Theme;
pub const SidebarEntry = types.SidebarEntry;
pub const SidebarKind = types.SidebarKind;
pub const SizeF = @import("../geometry.zig").SizeF;
pub const Quad = primitives.Quad;

// Caller-owned, one per sidebar instance, persistent across frames. A hitbox's
// ctx is read on a later input event, so each per-frame payload slab must
// outlive render. Self-referential: a ClickShim/RowShim points back here, so
// keep it in stable storage, never move or copy it after the first render.
pub const SidebarState = struct {
    selected_id: []const u8 = "",
    search_text: []const u8 = "",
    shims: [MAX_ITEMS]ClickShim = undefined,
    shim_len: usize = 0,
    rows: [MAX_ITEMS]RowInfo = undefined,
    rows_len: usize = 0,
    row_shims: [MAX_ITEMS]RowShim = undefined,
    row_shims_len: usize = 0,
    on_select: ?callbacks.SelectIdFn = null,
    on_disclose: ?callbacks.DiscloseFn = null,
    on_action: ?callbacks.SelectIdFn = null,
    on_move: ?MoveFn = null,
    cb_ctx: ?*anyopaque = null,
    row_h: f32 = 0,
    drag_pending: bool = false,
    drag_active: bool = false,
    drag_id: []const u8 = "",
    drag_label: []const u8 = "",
    drag_is_parent: bool = false,
    drag_expanded: bool = false,
    press_y: f32 = 0,
    drag_y: f32 = 0,
    drop_id: []const u8 = "",
    drop_pos: DropPos = .after,
    has_drop: bool = false,
};

// Sticky top region: a workspace / brand switcher.
pub const Header = struct {
    title: []const u8,
    subtitle: []const u8 = "",
    icon: ?icon.Icon = null,
    color: ?color.Rgba = null,
    use_border: bool = true, // separator below; off = flat into content
    on_click: ?callbacks.ClickFn = null,
};

// Sticky bottom region: the user menu.
pub const Footer = struct {
    name: []const u8,
    detail: []const u8 = "",
    initials: []const u8 = "",
    use_border: bool = true, // separator above; off = flat into content
    on_click: ?callbacks.ClickFn = null,
};

// How a collapsed sidebar presents: a mini icon-only rail, or fully hidden.
pub const CollapseMode = enum { mini, hide };

// Where a dragged item lands relative to the drop target row: as the previous
// sibling, the next sibling, or nested inside it (a folder/parent).
pub const DropPos = enum { before, after, inside };

// Reorder/move report: kit owns the gesture + ghost + drop indicator, caller
// mutates its own tree. No callbacks.* equivalent (DropPos is sidebar-specific).
pub const MoveFn = *const fn (
    ctx: ?*anyopaque,
    from_id: []const u8,
    target_id: []const u8,
    pos: DropPos,
) void;

pub const SidebarOptions = struct {
    items: []const SidebarEntry,
    theme: *const Theme,
    paint: ?*custom_paint.PaintContext = null,
    on_select: ?callbacks.SelectIdFn = null,
    on_disclose: ?callbacks.DiscloseFn = null, // parent expand/collapse; open = target state
    on_action: ?callbacks.SelectIdFn = null, // hover action button
    // Drag on the right-edge resize handle reports the raw cursor x; the caller
    // maps it to a width and decides the below-min auto-collapse.
    on_resize: ?callbacks.DragFn = null,
    // Set this to make item rows drag-to-reorder/move. Null = rows are click-only.
    on_move: ?MoveFn = null,
    ctx: ?*anyopaque = null,
    collapsed: bool = false,
    collapse_mode: CollapseMode = .mini,
    header: ?Header = null,
    footer: ?Footer = null,
    scroll_y: f32 = 0,
    top_pad: f32 = 12,
    side_pad: f32 = 10,
    row_height: f32 = 28,
    group_height: f32 = 18,
    group_top_gap: f32 = 12,
    group_bottom_gap: f32 = 2,
    icon_size: f32 = 22,
    icon_pad_x: f32 = 8,
    label_gap_x: f32 = 10,
};

pub const HEADER_H: f32 = 52;
pub const FOOTER_H: f32 = 56;
pub const COLLAPSED_W: f32 = 56; // mini icon-rail width (collapse target)

pub const MAX_ITEMS = 64;
pub const MAX_DEPTH = 4;

const MINI_TILE: f32 = 32; // active tile / icon slot in the mini rail
const MINI_ROW_H: f32 = 40;

// Click-shim payload; ctx points here. kind routes one slab to the three keyed
// callbacks; open carries the disclose target state.
const ClickKind = enum { select, action, disclose };
const ClickShim = struct { state: *SidebarState, id: []const u8, kind: ClickKind, open: bool };

fn shim_click(ctx: ?*anyopaque) void {
    const s: *const ClickShim = @ptrCast(@alignCast(ctx orelse return));
    const st = s.state;
    switch (s.kind) {
        .select => if (st.on_select) |cb| cb(st.cb_ctx, s.id),
        .action => if (st.on_action) |cb| cb(st.cb_ctx, s.id),
        .disclose => if (st.on_disclose) |cb| cb(st.cb_ctx, s.id, s.open),
    }
}

// ---- Drag to reorder / move (active only when opts.on_move is set) ----

const DRAG_THRESHOLD: f32 = 4; // pointer travel before a press becomes a drag
const DROP_INSIDE_BAND: f32 = 0.30; // middle fraction of a folder row = "inside"
const DROP_LINE_H: f32 = 2;
const GHOST_OPACITY: f32 = 0.85;

// Per-frame layout of each drawn item row, so a drop target can be resolved
// from the pointer y after the walk.
const RowInfo = struct { id: []const u8, y: f32, depth: usize, is_parent: bool };

// Draggable-row hitbox payload; ctx points here. Fields are captured into the
// shared drag state on press, read back on the later release event.
const RowShim = struct {
    state: *SidebarState,
    id: []const u8,
    label: []const u8,
    is_parent: bool,
    expanded: bool,
};

fn row_point(ctx: ?*anyopaque, x: f32, y: f32) void {
    _ = x;
    const s: *const RowShim = @ptrCast(@alignCast(ctx orelse return));
    const st = s.state;
    if (!st.drag_pending and !st.drag_active) {
        st.drag_pending = true;
        st.drag_active = false;
        st.drag_id = s.id;
        st.drag_label = s.label;
        st.drag_is_parent = s.is_parent;
        st.drag_expanded = s.expanded;
        st.press_y = y;
        st.drag_y = y;
        return;
    }
    st.drag_y = y;
    if (@abs(y - st.press_y) > DRAG_THRESHOLD) st.drag_active = true;
}

fn row_drop(ctx: ?*anyopaque) void {
    const s: *const RowShim = @ptrCast(@alignCast(ctx orelse return));
    const st = s.state;
    if (st.drag_active) {
        if (st.has_drop and !std.mem.eql(u8, st.drop_id, st.drag_id)) {
            if (st.on_move) |cb| cb(st.cb_ctx, st.drag_id, st.drop_id, st.drop_pos);
        }
    } else if (st.drag_pending) {
        // A press with no drag is a click: disclose a parent (open = the toggled
        // target), select a leaf.
        if (st.drag_is_parent) {
            if (st.on_disclose) |cb| cb(st.cb_ctx, st.drag_id, !st.drag_expanded);
        } else if (st.on_select) |cb| cb(st.cb_ctx, st.drag_id);
    }
    st.drag_pending = false;
    st.drag_active = false;
    st.has_drop = false;
}

// Resolve the drop target from the pointer y over the row table. Discrete
// zones (the tactile snap): a folder's middle band = inside, otherwise the
// row's top/bottom half = before/after.
fn compute_drop(state: *SidebarState) void {
    state.has_drop = false;
    var i: usize = 0;
    while (i < state.rows_len) : (i += 1) {
        const r = state.rows[i];
        if (state.drag_y < r.y or state.drag_y >= r.y + state.row_h) continue;
        if (std.mem.eql(u8, r.id, state.drag_id)) return; // never onto itself
        const rel = (state.drag_y - r.y) / state.row_h;
        state.drop_id = r.id;
        if (r.is_parent and rel >= DROP_INSIDE_BAND and rel <= 1 - DROP_INSIDE_BAND) {
            state.drop_pos = .inside;
        } else {
            state.drop_pos = if (rel < 0.5) .before else .after;
        }
        state.has_drop = true;
        return;
    }
}

// Drop indicator (line between rows / folder highlight) + a ghost row trailing
// the cursor. Quads overflow is covered by the opaque header/footer; the ghost
// label sprite is clipped to the content band by the caller.
fn render_drag_visuals(
    b: *RenderBuilder,
    state: *SidebarState,
    opts: *const SidebarOptions,
    x: f32,
    w: f32,
) !void {
    const theme = opts.theme;
    const row_x = x + opts.side_pad;
    const row_w = w - opts.side_pad * 2;
    const step = opts.icon_size + opts.label_gap_x;
    const row_h = state.row_h;

    if (state.has_drop) {
        var found = false;
        var ty: f32 = 0;
        var tdepth: usize = 0;
        var i: usize = 0;
        while (i < state.rows_len) : (i += 1) {
            if (std.mem.eql(u8, state.rows[i].id, state.drop_id)) {
                ty = state.rows[i].y;
                tdepth = state.rows[i].depth;
                found = true;
                break;
            }
        }
        if (found) {
            if (state.drop_pos == .inside) {
                var hl = Quad.init(row_x, ty, row_w, row_h);
                _ = hl.set_background(theme.accent)
                    .set_corner_radius(theme.radius - 2)
                    .set_border_color(theme.ring)
                    .set_border_width(1);
                try b.append_quad(hl);
            } else {
                const ind_x = row_x + opts.icon_pad_x + step * @as(f32, @floatFromInt(tdepth));
                const ly = if (state.drop_pos == .before) ty else ty + row_h;
                const line_w = (row_x + row_w) - ind_x;
                var line = Quad.init(ind_x, ly - DROP_LINE_H / 2, line_w, DROP_LINE_H);
                _ = line.set_background(theme.primary).set_corner_radius(DROP_LINE_H / 2);
                try b.append_quad(line);
            }
        }
    }

    const gy = state.drag_y - row_h / 2;
    var ghost_bg = theme.accent;
    ghost_bg.a *= GHOST_OPACITY;
    var gbg = Quad.init(row_x, gy, row_w, row_h);
    _ = gbg.set_background(ghost_bg).set_corner_radius(theme.radius - 2);
    try b.append_quad(gbg);
    const sty = label.Style{
        .font_size = theme.font_size,
        .weight = .medium,
        .color = theme.accent_foreground,
    };
    const m = label.measure(b, state.drag_label, sty);
    _ = try label.render(
        b,
        row_x + opts.icon_pad_x + step,
        label.centered_top(gy, row_h, m),
        state.drag_label,
        sty,
    );
}

const ICON_RATIO: f32 = 0.8; // glyph point size as a fraction of icon slot
const BACKPLATE_RADIUS: f32 = 5;
const GROUP_FONT_DELTA: f32 = 2; // group header sits two below the base font
const GROUP_LABEL_DY: f32 = 4;
const BADGE_FONT_DELTA: f32 = 3;
const BADGE_PAD: f32 = 7;
const BADGE_PILL_H: f32 = 16;
const BADGE_RIGHT_GAP: f32 = 10;
const SUB_HL_LEFTPAD: f32 = 6; // child highlight inset left of its text
const CHEVRON_PT: f32 = 10;
const CHEVRON_GUTTER: f32 = 22; // right inset for the parent chevron
const ACTION_SIZE: f32 = 20;
const ACTION_PT: f32 = 12;
const SUB_GUIDE_W: f32 = 1; // left guide line down the submenu indent

// Threaded render state so the recursive walk doesn't pass a dozen args.
const Walk = struct {
    b: *RenderBuilder,
    state: *SidebarState,
    opts: *const SidebarOptions,
    x: f32,
    w: f32,
    y_off: f32,
};

pub fn render(
    b: *RenderBuilder,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    state: *SidebarState,
    opts: SidebarOptions,
) RenderError!SizeF {
    // The shim slab takes one entry per visible item row + at most one hovered
    // action per frame; assert that real total up front (groups push nothing).
    std.debug.assert(visible_rows(&opts) + 1 <= state.shims.len);
    if (opts.collapsed and opts.collapse_mode == .hide) return SizeF.init(0, h);
    var bg_q = Quad.init(x, y, w, h);
    _ = bg_q.set_background(opts.theme.card);
    try b.append_quad(bg_q);

    state.shim_len = 0;
    state.row_shims_len = 0;
    state.rows_len = 0;
    state.on_select = opts.on_select;
    state.on_disclose = opts.on_disclose;
    state.on_action = opts.on_action;
    state.on_move = opts.on_move;
    state.cb_ctx = opts.ctx;
    state.row_h = opts.row_height;
    if (opts.collapsed) {
        try render_mini(b, state, &opts, x, y, w, h);
        try render_resize(b, &opts, x, y, w, h);
        return SizeF.init(w, h);
    }
    const head_h: f32 = if (opts.header != null) HEADER_H else 0;
    const foot_h: f32 = if (opts.footer != null) FOOTER_H else 0;
    const content_top = y + head_h;
    const view_h = h - head_h - foot_h;
    const scroll = std.math.clamp(opts.scroll_y, 0, @max(0, measure(&opts) - view_h));

    const spr0 = b.sprites.items.len;
    var walk = Walk{
        .b = b,
        .state = state,
        .opts = &opts,
        .x = x,
        .w = w,
        .y_off = content_top + opts.top_pad - scroll,
    };
    var first = true;
    var group_open = true;
    for (opts.items) |entry| {
        if (entry.kind == .group) {
            if (!first) walk.y_off += opts.group_top_gap;
            const sty = label.Style{
                .font_size = opts.theme.font_size - GROUP_FONT_DELTA,
                .weight = .semi_bold,
                .color = opts.theme.muted_foreground,
            };
            _ = try label.render(
                b,
                x + opts.side_pad + opts.icon_pad_x,
                walk.y_off + GROUP_LABEL_DY,
                entry.label,
                sty,
            );
            walk.y_off += opts.group_height + opts.group_bottom_gap;
            group_open = if (entry.collapsible) entry.expanded else true;
            first = false;
            continue;
        }
        first = false;
        if (!group_open) continue;
        try walk_item(&walk, entry, 0);
    }
    // Drag ghost + drop indicator on top of the rows (its label sprite is
    // included in the clip range below so it can't spill into header/footer).
    if (opts.on_move != null and state.drag_active) {
        compute_drop(state);
        try render_drag_visuals(b, state, &opts, x, w);
    }

    // Clip content glyphs to the scroll band; overflowing backplate/guide quads
    // are covered by the opaque sticky header/footer drawn on top.
    const area: [4]f32 = .{ x, content_top, w, view_h };
    for (b.sprites.items[spr0..]) |*sp| sp.clip_bounds = area;

    if (opts.header) |hd| try render_header(b, &opts, x, y, w, hd);
    if (opts.footer) |ft| try render_footer(b, &opts, x, y + h - foot_h, w, ft);
    try render_resize(b, &opts, x, y, w, h);
    return SizeF.init(w, h);
}

// Right-edge resize divider: the same affordance as the resizable demo - a thin
// line with a centered hover glow + the col-resize cursor. Reports the raw cursor
// x through on_resize (the kit's on_point), which the caller maps to a width.
fn render_resize(
    b: *RenderBuilder,
    opts: *const SidebarOptions,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
) !void {
    if (opts.on_resize == null) return;
    if (opts.paint == null) return; // no interaction context -> no divider
    std.debug.assert(w >= 0);
    std.debug.assert(h > 0);
    _ = try resizable.render(b, x + w, y, h, .{
        .orientation = .horizontal,
        .kind = .line,
        .theme = opts.theme,
        .paint = opts.paint,
        .on_drag = opts.on_resize,
        .ctx = opts.ctx,
    });
}

// Icon-only collapsed rail: brand tile, top-level item icons (active = filled
// primary tile), user avatar. No labels / groups / submenus / badges.
fn render_mini(
    b: *RenderBuilder,
    state: *SidebarState,
    opts: *const SidebarOptions,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
) !void {
    const theme = opts.theme;
    if (opts.header) |hd| {
        const tx = x + (w - MINI_TILE) / 2;
        const ty = y + (HEADER_H - MINI_TILE) / 2;
        var tile = Quad.init(tx, ty, MINI_TILE, MINI_TILE);
        _ = tile.set_background(hd.color orelse theme.secondary)
            .set_corner_radius(BACKPLATE_RADIUS + 1);
        try b.append_quad(tile);
        if (hd.icon != null) {
            const c = if (hd.color != null) theme.primary_foreground else theme.foreground;
            const st = icon.Style{ .point_size = MINI_TILE * ICON_RATIO * 0.6, .color = c };
            _ = try icon.render_icon_centered_xy(
                b,
                tx,
                ty,
                MINI_TILE,
                MINI_TILE,
                hd.icon.?,
                st,
            );
        }
    }

    var ry = y + (if (opts.header != null) HEADER_H else opts.top_pad);
    const foot_top = y + h - (if (opts.footer != null) FOOTER_H else 0);
    for (opts.items) |e| {
        if (e.kind == .group or e.id.len == 0) continue;
        if (ry + MINI_ROW_H > foot_top) break;
        const selected = subtree_selected(e, state.selected_id, 0);
        const tx = x + (w - MINI_TILE) / 2;
        const ty = ry + (MINI_ROW_H - MINI_TILE) / 2;
        if (opts.paint) |p| {
            if (p.is_hovered(tx, ty, MINI_TILE, MINI_TILE) and !selected) {
                var hl = Quad.init(tx, ty, MINI_TILE, MINI_TILE);
                _ = hl.set_background(theme.muted).set_corner_radius(BACKPLATE_RADIUS + 1);
                try b.append_quad(hl);
            }
            const is_parent = e.children.len > 0;
            const kind: ClickKind = if (is_parent) .disclose else .select;
            try push_shim(
                state,
                p,
                tx,
                ty,
                MINI_TILE,
                MINI_TILE,
                kind,
                e.id,
                is_parent and !e.expanded,
            );
        }
        if (selected) {
            var tile = Quad.init(tx, ty, MINI_TILE, MINI_TILE);
            _ = tile.set_background(theme.primary).set_corner_radius(BACKPLATE_RADIUS + 1);
            try b.append_quad(tile);
        }
        if (e.icon != null) {
            const fg = if (selected) theme.primary_foreground else theme.foreground;
            const st = icon.Style{ .point_size = MINI_TILE * ICON_RATIO * 0.6, .color = fg };
            _ = try icon.render_icon_centered_xy(
                b,
                tx,
                ty,
                MINI_TILE,
                MINI_TILE,
                e.icon.?,
                st,
            );
        }
        ry += MINI_ROW_H;
    }

    if (opts.footer) |ft| {
        const ax = x + (w - MINI_TILE) / 2;
        const ay = foot_top + (FOOTER_H - MINI_TILE) / 2;
        var av = Quad.init(ax, ay, MINI_TILE, MINI_TILE);
        _ = av.set_background(theme.secondary).set_corner_radius(MINI_TILE / 2);
        try b.append_quad(av);
        if (ft.initials.len > 0) {
            const isty = label.Style{
                .font_size = theme.font_size - 3,
                .weight = .medium,
                .color = theme.secondary_foreground,
            };
            const m = label.measure(b, ft.initials, isty);
            _ = try label.render(
                b,
                ax + (MINI_TILE - m.width) / 2,
                label.centered_top(ay, MINI_TILE, m),
                ft.initials,
                isty,
            );
        }
    }
}

// Total laid-out content height; max_scroll clamps the caller's offset to
// max(0, this - view_h).
fn measure(opts: *const SidebarOptions) f32 {
    var hh: f32 = opts.top_pad;
    var first = true;
    var group_open = true;
    for (opts.items) |e| {
        if (e.kind == .group) {
            if (!first) hh += opts.group_top_gap;
            hh += opts.group_height + opts.group_bottom_gap;
            group_open = if (e.collapsible) e.expanded else true;
            first = false;
            continue;
        }
        first = false;
        if (!group_open) continue;
        hh += measure_item(e, opts, 0);
    }
    return hh;
}

fn measure_item(e: SidebarEntry, opts: *const SidebarOptions, depth: usize) f32 {
    std.debug.assert(depth <= MAX_DEPTH);
    var hh: f32 = opts.row_height;
    if (e.children.len > 0 and e.expanded) {
        for (e.children) |c| hh += measure_item(c, opts, depth + 1);
    }
    return hh;
}

// Count of item rows that will be drawn (groups don't push shims). Used to
// assert the per-frame shim slab can't overflow before any row is laid out.
fn visible_rows(opts: *const SidebarOptions) usize {
    var n: usize = 0;
    var group_open = true;
    for (opts.items) |e| {
        if (e.kind == .group) {
            group_open = if (e.collapsible) e.expanded else true;
            continue;
        }
        if (!group_open) continue;
        n += visible_item_rows(e, 0);
    }
    return n;
}

fn visible_item_rows(e: SidebarEntry, depth: usize) usize {
    std.debug.assert(depth <= MAX_DEPTH);
    var n: usize = 1;
    if (e.children.len > 0 and e.expanded) {
        for (e.children) |c| n += visible_item_rows(c, depth + 1);
    }
    return n;
}

// True if this entry or any descendant is the selected id; the mini rail uses
// it so a collapsed parent reads active when one of its sub-items is current.
fn subtree_selected(e: SidebarEntry, sel: []const u8, depth: usize) bool {
    std.debug.assert(depth <= MAX_DEPTH);
    if (e.id.len > 0 and std.mem.eql(u8, e.id, sel)) return true;
    for (e.children) |c| {
        if (subtree_selected(c, sel, depth + 1)) return true;
    }
    return false;
}

// Caller clamps its stored scroll to [0, this]. view_h excludes header/footer.
pub fn max_scroll(opts: SidebarOptions, sidebar_h: f32) f32 {
    const head_h: f32 = if (opts.header != null) HEADER_H else 0;
    const foot_h: f32 = if (opts.footer != null) FOOTER_H else 0;
    return @max(0, measure(&opts) - (sidebar_h - head_h - foot_h));
}

fn walk_item(s: *Walk, entry: SidebarEntry, depth: usize) !void {
    std.debug.assert(depth <= MAX_DEPTH);
    const opts = s.opts;
    const filtered_out = s.state.search_text.len > 0 and entry.children.len == 0 and
        !tr.ascii_contains(entry.label, s.state.search_text);
    if (filtered_out) return;

    try render_row(s, entry, depth);
    s.y_off += opts.row_height;

    if (entry.children.len > 0 and entry.expanded) {
        // Guide line under this parent's icon-center column, down its children.
        const row_x = s.x + opts.side_pad;
        const step = opts.icon_size + opts.label_gap_x;
        const guide_indent = step * @as(f32, @floatFromInt(depth));
        const guide_x = row_x + opts.icon_pad_x + guide_indent + opts.icon_size / 2;
        const guide_y0 = s.y_off;
        for (entry.children) |child| try walk_item(s, child, depth + 1);
        var guide = Quad.init(guide_x, guide_y0, SUB_GUIDE_W, s.y_off - guide_y0);
        _ = guide.set_background(opts.theme.border);
        try s.b.append_quad(guide);
    }
}

fn render_row(s: *Walk, entry: SidebarEntry, depth: usize) !void {
    const b = s.b;
    const opts = s.opts;
    const theme = opts.theme;
    const row_x = s.x + opts.side_pad;
    const row_w = s.w - opts.side_pad * 2;
    const row_h = opts.row_height;
    const y_off = s.y_off;
    const is_parent = entry.children.len > 0;
    const selected = entry.id.len > 0 and std.mem.eql(u8, entry.id, s.state.selected_id);
    const df: f32 = @floatFromInt(depth);

    // Top level shows an icon; submenu rows are text-only and align their text
    // under the parent's text (a step per depth = icon slot + gap).
    const step = opts.icon_size + opts.label_gap_x;
    const icon_x = row_x + opts.icon_pad_x;
    const text_x = if (depth == 0) icon_x + step else icon_x + step * df;

    std.debug.assert(s.state.rows_len < s.state.rows.len);
    s.state.rows[s.state.rows_len] = .{
        .id = entry.id,
        .y = y_off,
        .depth = depth,
        .is_parent = is_parent,
    };
    s.state.rows_len += 1;

    var hovered = false;
    if (opts.paint) |p| {
        hovered = p.is_hovered(row_x, y_off, row_w, row_h);
        if (opts.on_move != null) {
            // Draggable: press-or-drag decided on release in row_drop.
            std.debug.assert(s.state.row_shims_len < s.state.row_shims.len);
            s.state.row_shims[s.state.row_shims_len] = .{
                .state = s.state,
                .id = entry.id,
                .label = entry.label,
                .is_parent = is_parent,
                .expanded = entry.expanded,
            };
            try p.add_hitbox(.{
                .x = row_x,
                .y = y_off,
                .w = row_w,
                .h = row_h,
                .on_point = row_point,
                .on_drag_end = row_drop,
                .ctx = @ptrCast(&s.state.row_shims[s.state.row_shims_len]),
            });
            s.state.row_shims_len += 1;
        } else {
            const kind: ClickKind = if (is_parent) .disclose else .select;
            try push_shim(
                s.state,
                p,
                row_x,
                y_off,
                row_w,
                row_h,
                kind,
                entry.id,
                is_parent and !entry.expanded,
            );
        }
    }
    const is_src = s.state.drag_active and entry.id.len > 0 and
        std.mem.eql(u8, entry.id, s.state.drag_id);

    // Active = bg only (no prefix indicator). The highlight spans the full row
    // at top level; submenu rows inset their highlight to the indented text.
    const hl_x = if (depth == 0) row_x else text_x - SUB_HL_LEFTPAD;
    const hl_w = (row_x + row_w) - hl_x;
    if (is_src) {
        // Faint placeholder slot where the lifted item was.
        var slot = Quad.init(hl_x, y_off, hl_w, row_h);
        _ = slot.set_background(theme.muted).set_corner_radius(theme.radius - 2);
        try b.append_quad(slot);
    } else if (selected or hovered) {
        var bp = Quad.init(hl_x, y_off, hl_w, row_h);
        _ = bp.set_background(if (selected) theme.accent else theme.muted)
            .set_corner_radius(theme.radius - 2);
        try b.append_quad(bp);
    }

    // Menu items read bright; only the group label is muted (lifted source dims).
    const fg = if (is_src)
        theme.muted_foreground
    else if (selected)
        theme.accent_foreground
    else
        theme.foreground;

    if (depth == 0) {
        const icon_y = y_off + (row_h - opts.icon_size) / 2;
        if (entry.color) |c| {
            var cbp = Quad.init(icon_x, icon_y, opts.icon_size, opts.icon_size);
            _ = cbp.set_background(c).set_corner_radius(BACKPLATE_RADIUS);
            try b.append_quad(cbp);
        }
        if (entry.icon != null) {
            const isty = icon.Style{
                .point_size = opts.icon_size * ICON_RATIO,
                .color = if (entry.color != null) theme.primary_foreground else fg,
            };
            _ = try icon.render_icon_centered_xy(
                b,
                icon_x,
                icon_y,
                opts.icon_size,
                opts.icon_size,
                entry.icon.?,
                isty,
            );
        }
    }

    const label_sty = label.Style{
        .font_size = opts.theme.font_size,
        .weight = if (selected) .medium else .normal,
        .color = fg,
    };
    // Optically center the glyph ink (x-height band) in the row backplate.
    const lm = label.measure(b, entry.label, label_sty);
    _ = try label.render(
        b,
        text_x,
        label.centered_top(y_off, row_h, lm),
        entry.label,
        label_sty,
    );

    // Right edge, in priority order: parent chevron, else hover action, else badge.
    if (is_parent) {
        const chev: icon.Icon = if (entry.expanded) .chevron_down else .chevron_right;
        const chev_x = row_x + row_w - CHEVRON_GUTTER;
        _ = try icon.render_icon_centered_y(b, chev_x, y_off, row_h, chev, .{
            .point_size = CHEVRON_PT,
            .weight = .medium,
            .color = fg,
        });
    } else if (hovered and entry.action_icon != null) {
        const action_x = row_x + row_w - ACTION_SIZE - 6;
        const action_y = y_off + (row_h - ACTION_SIZE) / 2;
        try render_action(s, entry, action_x, action_y, fg);
    } else if (entry.badge.len > 0) {
        try render_badge(s, entry, row_x + row_w);
    }
}

fn render_action(s: *Walk, entry: SidebarEntry, ax: f32, ay: f32, fg: color.Rgba) !void {
    const b = s.b;
    const opts = s.opts;
    if (opts.paint) |p| {
        const ph = p.is_hovered(ax, ay, ACTION_SIZE, ACTION_SIZE);
        if (ph) {
            var hl = Quad.init(ax, ay, ACTION_SIZE, ACTION_SIZE);
            _ = hl.set_background(opts.theme.accent).set_corner_radius(opts.theme.radius - 3);
            try b.append_quad(hl);
        }
        try push_shim(s.state, p, ax, ay, ACTION_SIZE, ACTION_SIZE, .action, entry.id, false);
    }
    if (entry.action_icon) |ac| {
        _ = try icon.render_icon_centered_xy(b, ax, ay, ACTION_SIZE, ACTION_SIZE, ac, .{
            .point_size = ACTION_PT,
            .color = fg,
        });
    }
}

fn render_badge(s: *Walk, entry: SidebarEntry, right_edge: f32) !void {
    const b = s.b;
    const theme = s.opts.theme;
    const badge_sty = label.Style{
        .font_size = theme.font_size - BADGE_FONT_DELTA,
        .weight = .semi_bold,
        .color = theme.success_foreground,
    };
    const bm = label.measure(b, entry.badge, badge_sty);
    const pill_w: f32 = @max(bm.width + BADGE_PAD * 2, BADGE_PILL_H);
    const pill_x = right_edge - pill_w - BADGE_RIGHT_GAP;
    const pill_y = s.y_off + (s.opts.row_height - BADGE_PILL_H) / 2;
    var pill = Quad.init(pill_x, pill_y, pill_w, BADGE_PILL_H);
    _ = pill.set_background(theme.success).set_corner_radius(BADGE_PILL_H / 2);
    try b.append_quad(pill);
    _ = try label.render(
        b,
        pill_x + (pill_w - bm.width) / 2,
        label.centered_top(pill_y, BADGE_PILL_H, bm),
        entry.badge,
        badge_sty,
    );
}

const REGION_PAD: f32 = 8;
const TILE: f32 = 36; // header brand tile / footer avatar
const REGION_GAP: f32 = 8; // tile to text
const SUBTITLE_DELTA: f32 = 3; // subtitle/detail below base font
const SWITCH_GUTTER: f32 = 24; // up/down switcher chevron right inset

fn render_header(
    b: *RenderBuilder,
    opts: *const SidebarOptions,
    x: f32,
    y: f32,
    w: f32,
    hd: Header,
) !void {
    const theme = opts.theme;
    if (opts.paint) |p| {
        if (hd.on_click != null) try p.add_hitbox(.{
            .x = x,
            .y = y,
            .w = w,
            .h = HEADER_H,
            .on_click = hd.on_click,
            .ctx = opts.ctx,
        });
    }
    // Opaque fill so a scrolled content quad (guide line / backplate) can't
    // bleed into the sticky region; sprites are already clipped out.
    var hbg = Quad.init(x, y, w, HEADER_H);
    _ = hbg.set_background(theme.card);
    try b.append_quad(hbg);
    const tile_x = x + REGION_PAD;
    const tile_y = y + (HEADER_H - TILE) / 2;
    var tile = Quad.init(tile_x, tile_y, TILE, TILE);
    _ = tile.set_background(hd.color orelse theme.secondary)
        .set_corner_radius(BACKPLATE_RADIUS + 1);
    try b.append_quad(tile);
    if (hd.icon != null) {
        const c = if (hd.color != null) theme.primary_foreground else theme.foreground;
        const st = icon.Style{ .point_size = TILE * ICON_RATIO * 0.6, .color = c };
        _ = try icon.render_icon_centered_xy(
            b,
            tile_x,
            tile_y,
            TILE,
            TILE,
            hd.icon.?,
            st,
        );
    }
    const text_x = tile_x + TILE + REGION_GAP;
    try two_line(b, theme, text_x, y, HEADER_H, hd.title, hd.subtitle);
    _ = try icon.render_icon_centered_y(b, x + w - SWITCH_GUTTER, y, HEADER_H, .chevron_up_down, .{
        .point_size = CHEVRON_PT + 1,
        .color = theme.muted_foreground,
    });
    if (hd.use_border) {
        var sep = Quad.init(x, y + HEADER_H, w, SUB_GUIDE_W);
        _ = sep.set_background(theme.border);
        try b.append_quad(sep);
    }
}

fn render_footer(
    b: *RenderBuilder,
    opts: *const SidebarOptions,
    x: f32,
    y: f32,
    w: f32,
    ft: Footer,
) !void {
    const theme = opts.theme;
    if (opts.paint) |p| {
        if (ft.on_click != null) try p.add_hitbox(.{
            .x = x,
            .y = y,
            .w = w,
            .h = FOOTER_H,
            .on_click = ft.on_click,
            .ctx = opts.ctx,
        });
    }
    // Opaque fill so a scrolled content quad (guide line / backplate) can't
    // bleed into the sticky region; sprites are already clipped out.
    var fbg = Quad.init(x, y, w, FOOTER_H);
    _ = fbg.set_background(theme.card);
    try b.append_quad(fbg);
    if (ft.use_border) {
        var sep = Quad.init(x, y, w, SUB_GUIDE_W);
        _ = sep.set_background(theme.border);
        try b.append_quad(sep);
    }
    const av_x = x + REGION_PAD;
    const av_y = y + (FOOTER_H - TILE) / 2;
    var av = Quad.init(av_x, av_y, TILE, TILE);
    _ = av.set_background(theme.secondary).set_corner_radius(TILE / 2);
    try b.append_quad(av);
    if (ft.initials.len > 0) {
        const isty = label.Style{
            .font_size = theme.font_size - 2,
            .weight = .medium,
            .color = theme.secondary_foreground,
        };
        const m = label.measure(b, ft.initials, isty);
        _ = try label.render(
            b,
            av_x + (TILE - m.width) / 2,
            label.centered_top(av_y, TILE, m),
            ft.initials,
            isty,
        );
    }
    const text_x = av_x + TILE + REGION_GAP;
    try two_line(b, theme, text_x, y, FOOTER_H, ft.name, ft.detail);
    _ = try icon.render_icon_centered_y(b, x + w - SWITCH_GUTTER, y, FOOTER_H, .chevron_up_down, .{
        .point_size = CHEVRON_PT + 1,
        .color = theme.muted_foreground,
    });
}

// Two-line offsets are fixed pixels, not measured: matching baseline-to-baseline
// gap visually beats centering each line independently.
fn two_line(
    b: *RenderBuilder,
    theme: *const Theme,
    tx: f32,
    region_y: f32,
    region_h: f32,
    title: []const u8,
    subtitle: []const u8,
) !void {
    const t_sty = label.Style{
        .font_size = theme.font_size,
        .weight = .semi_bold,
        .color = theme.foreground,
    };
    if (subtitle.len > 0) {
        const s_sty = label.Style{
            .font_size = theme.font_size - SUBTITLE_DELTA,
            .weight = .normal,
            .color = theme.muted_foreground,
        };
        _ = try label.render(b, tx, region_y + region_h / 2 - 15, title, t_sty);
        _ = try label.render(b, tx, region_y + region_h / 2 + 1, subtitle, s_sty);
    } else {
        const tm = label.measure(b, title, t_sty);
        const ty = region_y + (region_h - (tm.ascent + tm.descent)) / 2;
        _ = try label.render(b, tx, ty, title, t_sty);
    }
}

fn push_shim(
    state: *SidebarState,
    p: *custom_paint.PaintContext,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    kind: ClickKind,
    id: []const u8,
    open: bool,
) !void {
    std.debug.assert(state.shim_len < state.shims.len);
    state.shims[state.shim_len] = .{ .state = state, .id = id, .kind = kind, .open = open };
    try p.add_hitbox(.{
        .x = x,
        .y = y,
        .w = w,
        .h = h,
        .on_click = shim_click,
        .ctx = @ptrCast(&state.shims[state.shim_len]),
    });
    state.shim_len += 1;
}
