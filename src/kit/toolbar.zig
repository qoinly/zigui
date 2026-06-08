const std = @import("std");
const types = @import("../window/types.zig");
const builder = @import("../render/builder.zig");
const RenderError = builder.RenderError;
const label = @import("../render/label.zig");
const icon = @import("../render/icon.zig");
const primitives = @import("../primitives.zig");
const custom_paint = @import("../window/paint.zig");
const callbacks = @import("../callbacks.zig");

pub const RenderBuilder = builder.RenderBuilder;
pub const Theme = types.Theme;
pub const ToolbarEntry = types.ToolbarEntry;
pub const ToolbarItemKind = types.ToolbarItemKind;
pub const Quad = primitives.Quad;
pub const SizeF = @import("../geometry.zig").SizeF;

pub const MAX_ITEMS = 32;

pub const TitleAlign = enum { left, center };

// Reports its anchor rect so the caller can place the dropdown; no callbacks.*
// equivalent, so it stays a toolbar type.
pub const ToolbarMenuFn = *const fn (
    ctx: ?*anyopaque,
    id: []const u8,
    x: f32,
    y: f32,
    w: f32,
) void;

const Shim = struct {
    kind: enum { select, menu },
    on_select: ?callbacks.SelectIdFn,
    on_menu: ?ToolbarMenuFn,
    ctx: ?*anyopaque,
    id: []const u8,
    x: f32,
    y: f32,
    w: f32,
};

// Caller-owned across frames: a hitbox's ctx is read on a later input event, so
// each item's payload must outlive render. Per-toolbar so two toolbars never
// clobber each other. Slab bounded by MAX_ITEMS (asserted).
pub const ToolbarState = struct {
    hovered_idx: ?usize = null,
    pressed_idx: ?usize = null,
    shims: [MAX_ITEMS]Shim = undefined,
    shim_len: usize = 0,
};

pub const ToolbarOptions = struct {
    items: []const ToolbarEntry,
    height: f32 = 56,
    side_pad: f32 = 16,
    item_gap: f32 = 8,
    button_size: f32 = 32,
    icon_size: f32 = 16,
    separator_height: f32 = 1,
    title: []const u8 = "",
    title_align: TitleAlign = .left,
    title_offset_x: f32 = 0,
    // Reserve the traffic-light cluster when the toolbar spans full window width.
    leading_inset: f32 = 0,
    theme: *const Theme,
    paint: ?*custom_paint.PaintContext = null,
    on_select: ?callbacks.SelectIdFn = null,
    on_menu: ?ToolbarMenuFn = null,
    ctx: ?*anyopaque = null,
};

const SEP_INSET_Y: f32 = 8;
const MENU_CHEVRON_W: f32 = 14;
const MENU_PAD_X: f32 = 10;
const MENU_CHEVRON_GAP: f32 = 3;
const CHEVRON_PT: f32 = 11;

fn shim_click(ctx: ?*anyopaque) void {
    const s: *const Shim = @ptrCast(@alignCast(ctx orelse return));
    switch (s.kind) {
        .select => if (s.on_select) |cb| cb(s.ctx, s.id),
        .menu => if (s.on_menu) |cb| cb(s.ctx, s.id, s.x, s.y, s.w),
    }
}

fn push_select(
    state: *ToolbarState,
    opts: *const ToolbarOptions,
    id: []const u8,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
) !void {
    const p = opts.paint orelse return;
    std.debug.assert(state.shim_len < state.shims.len);
    state.shims[state.shim_len] = .{
        .kind = .select,
        .on_select = opts.on_select,
        .on_menu = null,
        .ctx = opts.ctx,
        .id = id,
        .x = x,
        .y = y,
        .w = w,
    };
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

fn push_menu(
    state: *ToolbarState,
    opts: *const ToolbarOptions,
    id: []const u8,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    drop_y: f32,
) !void {
    const p = opts.paint orelse return;
    std.debug.assert(state.shim_len < state.shims.len);
    state.shims[state.shim_len] = .{
        .kind = .menu,
        .on_select = null,
        .on_menu = opts.on_menu,
        .ctx = opts.ctx,
        .id = id,
        .x = x,
        .y = drop_y,
        .w = w,
    };
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

pub fn render(
    b: *RenderBuilder,
    x: f32,
    y: f32,
    w: f32,
    state: *ToolbarState,
    opts: ToolbarOptions,
) RenderError!SizeF {
    std.debug.assert(opts.items.len <= MAX_ITEMS);
    var bg_q = Quad.init(x, y, w, opts.height);
    _ = bg_q.set_background(opts.theme.background);
    try b.append_quad(bg_q);

    var sep = Quad.init(x, y + opts.height - opts.separator_height, w, opts.separator_height);
    _ = sep.set_background(opts.theme.border);
    try b.append_quad(sep);

    if (opts.title.len > 0) {
        const tsty = label.Style{
            .font_size = opts.theme.font_size,
            .weight = .medium,
            .color = opts.theme.foreground,
        };
        const tm = label.measure(b, opts.title, tsty);
        const tx = switch (opts.title_align) {
            .left => x + opts.side_pad + opts.title_offset_x,
            .center => x + (w - tm.width) / 2,
        };
        const ty = y + (opts.height - (tm.ascent + tm.descent)) / 2;
        _ = try label.render(b, tx, ty, opts.title, tsty);
    }

    state.shim_len = 0;
    var cursor_left: f32 = x + opts.side_pad + opts.leading_inset;
    var cursor_right: f32 = x + w - opts.side_pad;
    var on_right: bool = false;

    for (opts.items, 0..) |entry, i| {
        const cy = y + (opts.height - opts.button_size) / 2;
        switch (entry.kind) {
            .flexible_space => {
                on_right = true;
            },
            .tracking_separator => {
                var div = Quad.init(cursor_left, y + SEP_INSET_Y, 1, opts.height - SEP_INSET_Y * 2);
                _ = div.set_background(opts.theme.border);
                try b.append_quad(div);
                cursor_left += opts.item_gap;
            },
            .menu => {
                const lsty = label.Style{
                    .font_size = opts.theme.font_size,
                    .weight = .medium,
                    .color = opts.theme.foreground,
                };
                const lm = label.measure(b, entry.label, lsty);
                const mw = lm.width + MENU_PAD_X * 2 + MENU_CHEVRON_W;
                const item_x = if (on_right) blk: {
                    cursor_right -= mw;
                    break :blk cursor_right;
                } else blk: {
                    const cx = cursor_left;
                    cursor_left += mw + opts.item_gap;
                    break :blk cx;
                };
                if (on_right) cursor_right -= opts.item_gap;

                const hovered = if (opts.paint) |p|
                    p.is_hovered(item_x, cy, mw, opts.button_size)
                else
                    false;
                if (hovered) {
                    var hov = Quad.init(item_x, cy, mw, opts.button_size);
                    _ = hov.set_background(opts.theme.accent)
                        .set_corner_radius(opts.theme.radius - 2);
                    try b.append_quad(hov);
                }
                const fg = if (hovered) opts.theme.accent_foreground else opts.theme.foreground;
                const label_y = y + (opts.height - (lm.ascent + lm.descent)) / 2;
                _ = try label.render(b, item_x + MENU_PAD_X, label_y, entry.label, .{
                    .font_size = opts.theme.font_size,
                    .weight = .medium,
                    .color = fg,
                });
                const chevron_x = item_x + MENU_PAD_X + lm.width + MENU_CHEVRON_GAP;
                _ = try icon.render_icon_centered_y(b, chevron_x, y, opts.height, .chevron_down, .{
                    .point_size = CHEVRON_PT,
                    .weight = .light,
                    .color = fg,
                });
                try push_menu(
                    state,
                    &opts,
                    entry.id,
                    item_x,
                    cy,
                    mw,
                    opts.button_size,
                    y + opts.height,
                );
            },
            .sidebar_toggle, .button => {
                const sz = opts.button_size;
                const item_x = if (on_right) blk: {
                    cursor_right -= sz;
                    break :blk cursor_right;
                } else blk: {
                    const cx = cursor_left;
                    cursor_left += sz + opts.item_gap;
                    break :blk cx;
                };
                if (on_right) cursor_right -= opts.item_gap;

                var hovered = if (state.hovered_idx) |h| h == i else false;
                const pressed = if (state.pressed_idx) |p| p == i else false;
                if (opts.paint) |p| {
                    if (p.is_hovered(item_x, cy, sz, sz)) hovered = true;
                }
                if (hovered or pressed) {
                    var hov = Quad.init(item_x, cy, sz, sz);
                    const hov_bg = if (pressed) opts.theme.muted else opts.theme.accent;
                    _ = hov.set_background(hov_bg).set_corner_radius(opts.theme.radius - 2);
                    try b.append_quad(hov);
                }

                const enabled = entry.enabled;
                const fg = if (enabled) opts.theme.foreground else opts.theme.muted_foreground;

                const ic: ?icon.Icon = if (entry.kind == .sidebar_toggle) .sidebar else entry.icon;
                if (ic) |gi| {
                    const isty = icon.Style{ .point_size = opts.icon_size, .color = fg };
                    const icon_x = item_x + (sz - opts.icon_size) / 2;
                    _ = try icon.render_icon_centered_y(b, icon_x, y, opts.height, gi, isty);
                }
                const id: []const u8 = if (entry.kind == .sidebar_toggle)
                    "sidebar_toggle"
                else
                    entry.id;
                if (enabled) try push_select(state, &opts, id, item_x, cy, sz, sz);
            },
            // Not yet drawn; reserve button-size space so layout stays stable.
            // No catch-all else, so a newly-added kind fails to compile here.
            .segmented_group, .search_field, .custom_view => {
                const sz = opts.button_size;
                if (on_right) {
                    cursor_right -= sz + opts.item_gap;
                } else {
                    cursor_left += sz + opts.item_gap;
                }
            },
        }
    }
    return SizeF.init(w, opts.height);
}
