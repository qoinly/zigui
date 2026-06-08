const std = @import("std");
const zigui = @import("zigui");
const Node = zigui.Node;
const Frame = zigui.Frame;
const Theme = zigui.Theme;
const App = @import("../app.zig").App;

const SEARCH_W: f32 = 220;
const SEARCH_H: f32 = 26;
const SEARCH_RADIUS_INSET: f32 = 2; // tighter corner than the theme card radius
// Below this the centered search would collide with the workspace label; hide it.
const SEARCH_MIN_WIN: f32 = 860;

fn on_collapse(app: *App) void {
    app.sidebar_collapsed = !app.sidebar_collapsed; // the hide IS the feedback
}
fn on_settings(app: *App) void {
    app.toast("Settings", .default);
}
fn on_update(app: *App) void {
    app.toast("Checking for updates", .success);
}
fn on_avatar(app: *App) void {
    app.toast("Account", .default);
}
// One source of truth for the id -> {label, icon} map, shared by the chip label
// and the dropdown items so they can't drift. [0] is the default selection.
const Ws = struct { id: []const u8, label: []const u8, icon: zigui.Icon };
const WORKSPACES = [_]Ws{
    .{ .id = "community", .label = "Qoinly Community", .icon = .people },
    .{ .id = "team", .label = "Qoinly Team", .icon = .people },
    .{ .id = "personal", .label = "Personal", .icon = .person },
};

fn workspace_label(id: []const u8) []const u8 {
    for (WORKSPACES) |w| {
        if (std.mem.eql(u8, id, w.id)) return w.label;
    }
    return WORKSPACES[0].label;
}
fn on_workspace(app: *App) void {
    app.workspace.open = !app.workspace.open;
    if (app.workspace.open) app.workspace.state.reset(); // collapse stale flyouts
}
fn on_workspace_dismiss(app: *App) void {
    app.workspace.open = false;
}
fn on_workspace_select(app: *App, id: []const u8) void {
    app.workspace.open = false;
    if (std.mem.eql(u8, id, "new") or std.mem.eql(u8, id, "settings")) {
        app.toast("Workspace action", .default);
        return;
    }
    app.workspace.selected = id; // id is a static literal from the items array
    app.toast("Switched workspace", .default);
}

// A composed look, not the input kit: search glyph + placeholder + the shortcut.
fn search_box(t: *const Theme) *Node {
    return zigui.row(.{
        .width = SEARCH_W,
        .height = SEARCH_H,
        .gap = .xs,
        .pad = .sm,
        .cross = .center,
        .bg = t.background,
        .border = t.border,
        .radius = t.radius - SEARCH_RADIUS_INSET,
    }, &.{
        zigui.icon(.search, .{ .size = 14, .color = t.muted_foreground }),
        zigui.text("Search", .{ .size = 13, .muted = true }),
        zigui.spacer(),
        zigui.kbd(&.{ zigui.key_command, "K" }),
    });
}

// Composed icon+text (not a button) so every inter-item gap stays uniform.
fn update_pill(t: *const Theme) *Node {
    return zigui.row(.{
        .gap = .sm,
        .cross = .center,
        .pad = .sm,
        .radius = t.radius - SEARCH_RADIUS_INSET,
        .hover_bg = t.accent,
        .on_click = zigui.on(App, on_update),
    }, &.{
        zigui.icon(.arrow_down_to_line, .{ .size = 15, .color = t.success }),
        zigui.text("Update available", .{ .size = 13, .weight = .medium, .color = t.success }),
    });
}

// A fixed width (search shown) left-aligns the content and pads its right so the
// search lands at true window-centre; null = grow to share the band.
fn left_group(width: ?f32, t: *const Theme, app: *App) *Node {
    const mut = t.muted_foreground;
    return zigui.row(.{
        .width = width,
        .grow = if (width == null) 1 else 0,
        .gap = .md,
        .cross = .center,
    }, &.{
        zigui.button("", .{
            .variant = .ghost,
            .size = .icon_sm,
            .icon = .sidebar,
            .on_click = zigui.on(App, on_collapse),
        }),
        zigui.row(.{
            .gap = .sm,
            .cross = .center,
            .pad = .sm,
            .radius = t.radius - SEARCH_RADIUS_INSET,
            .hover_bg = t.accent,
            .on_click = zigui.on(App, on_workspace),
            .rect_out = &app.workspace.rect,
        }, &.{
            zigui.icon(.layout_grid, .{ .size = 15, .color = mut }),
            zigui.text(
                workspace_label(app.workspace.selected),
                .{ .size = 13, .weight = .semi_bold },
            ),
            zigui.icon(.chevron_down, .{ .size = 11, .color = mut }),
        }),
    });
}

fn right_group(t: *const Theme) *Node {
    return zigui.row(.{ .grow = 1, .gap = .md, .cross = .center, .justify = .flex_end }, &.{
        update_pill(t),
        zigui.button("", .{
            .variant = .ghost,
            .size = .icon_sm,
            .icon = .gear,
            .on_click = zigui.on(App, on_settings),
        }),
        zigui.col(.{
            .width = 26,
            .height = 26,
            .radius = 13,
            .bg = t.secondary,
            .hover_bg = zigui.mix(t.secondary, t.foreground, 0.12),
            .cross = .center,
            .justify = .center,
            .on_click = zigui.on(App, on_avatar),
        }, &.{
            zigui.icon(.person, .{ .size = 15, .color = t.secondary_foreground }),
        }),
        zigui.col(.{ .width = 6 }, &.{}), // right gutter off the window edge
    });
}

// Fills the band past the traffic-light gutter. The fixed-width left group pins the
// search to true window-centre; narrow
// windows drop the search and let both groups share the band.
pub fn view(f: *Frame, app: *App) *Node {
    const t = f.theme;
    if (f.size.width >= SEARCH_MIN_WIN) {
        const lw = @max(0, f.size.width / 2 - SEARCH_W / 2 - f.titlebar.origin.x);
        return zigui.row(.{ .grow = 1, .cross = .center }, &.{
            left_group(lw, t, app),
            search_box(t),
            right_group(t),
        });
    }
    return zigui.row(.{ .grow = 1, .cross = .center, .gap = .md }, &.{
        left_group(null, t, app),
        right_group(t),
    });
}

// The workspace switcher dropdown, anchored under the chip in the overlay region.
pub fn overlay(f: *Frame, app: *App) ?*Node {
    if (!app.workspace.open) return null;
    const sel = app.workspace.selected;
    // checkbox kind shows a leading checkmark when checked, else the item's icon
    // (mutually exclusive) - so the active workspace reads as selected. Built from
    // WORKSPACES; menu_overlay dupes the slice into the arena before this returns.
    var items: [WORKSPACES.len + 3]zigui.MenuEntry = undefined;
    for (WORKSPACES, 0..) |w, i| {
        items[i] = .{
            .kind = .checkbox,
            .id = w.id,
            .label = w.label,
            .icon = w.icon,
            .checked = std.mem.eql(u8, sel, w.id),
        };
    }
    const n = WORKSPACES.len;
    items[n] = .{ .kind = .separator };
    items[n + 1] = .{ .kind = .item, .id = "new", .label = "New workspace", .icon = .plus };
    items[n + 2] = .{
        .kind = .item,
        .id = "settings",
        .label = "Workspace settings",
        .icon = .gear,
    };
    return zigui.menu_overlay(.{
        .items = &items,
        .state = &app.workspace.state,
        .trigger = &app.workspace.rect,
        .view_y = f.body.origin.y,
        .view_h = f.body.size.height,
        .on_select = zigui.on_id(App, on_workspace_select),
        .on_dismiss = zigui.on(App, on_workspace_dismiss),
    });
}
