const std = @import("std");
const zigui = @import("zigui");
const Node = zigui.Node;
const Frame = zigui.Frame;
const App = @import("../app.zig").App;
const page = @import("../scaffold/page.zig");

fn on_open(app: *App) void {
    app.menu.open = !app.menu.open;
    if (app.menu.open) app.menu.state.reset(); // collapse stale flyouts
}
fn on_dismiss(app: *App) void {
    app.menu.open = false;
}
fn on_select(app: *App, id: []const u8) void {
    if (std.mem.eql(u8, id, "notify")) {
        app.menu.notify = !app.menu.notify; // checkbox keeps the menu open
        return;
    }
    app.menu.open = false;
    app.toast("Menu action", .default);
}

pub fn view(f: *Frame, app: *App) *Node {
    const t = f.theme;
    return page.page(&.{
        page.header("Menu", "A dropdown of actions anchored to a trigger."),
        page.section(t, "Trigger", &.{
            zigui.button("Open menu", .{
                .variant = .outline,
                .on_click = zigui.on(App, on_open),
                .rect_out = &app.menu.rect,
            }),
        }),
    });
}

// The open dropdown, rendered in the overlay region anchored to the trigger.
pub fn overlay(f: *Frame, app: *App) ?*Node {
    if (!app.menu.open) return null;
    const items = [_]zigui.MenuEntry{
        .{
            .kind = .item,
            .id = "profile",
            .label = "Profile",
            .icon = .person,
            .shortcut = zigui.key_command ++ " P",
        },
        .{ .kind = .item, .id = "settings", .label = "Settings", .icon = .gear },
        .{ .kind = .separator },
        .{
            .kind = .checkbox,
            .id = "notify",
            .label = "Notifications",
            .checked = app.menu.notify,
        },
        .{ .kind = .separator },
        .{ .kind = .item, .id = "logout", .label = "Log out", .destructive = true },
    };
    return zigui.menu_overlay(.{
        .items = &items,
        .state = &app.menu.state,
        .trigger = &app.menu.rect,
        .view_y = f.body.origin.y,
        .view_h = f.body.size.height,
        .on_select = zigui.on_id(App, on_select),
        .on_dismiss = zigui.on(App, on_dismiss),
    });
}
