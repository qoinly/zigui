const zigui = @import("zigui");
const Node = zigui.Node;
const Frame = zigui.Frame;
const App = @import("../app.zig").App;
const titlebar = @import("titlebar.zig");
const select_page = @import("../pages/select.zig");
const menu_page = @import("../pages/menu.zig");
const popover_page = @import("../pages/popover.zig");
const sheet_page = @import("../pages/sheet.zig");

fn close(app: *App) void {
    app.dialog_open = false;
}
fn confirm(app: *App) void {
    app.dialog_open = false;
    app.toast("Account deleted", .destructive);
}

// The modal/anchored floating layer. Anchored panels (select/menu/popover) and
// the modal sheet own it when open; otherwise the dialog frosts the backdrop and
// blocks the body. An outside click dismisses. (Toasts/tooltips ride the hud.)
pub fn view(f: *Frame, app: *App) ?*Node {
    if (titlebar.overlay(f, app)) |panel| return panel;
    if (select_page.overlay(f, app)) |panel| return panel;
    if (menu_page.overlay(f, app)) |panel| return panel;
    if (popover_page.overlay(f, app)) |panel| return panel;
    if (sheet_page.overlay(f, app)) |panel| return panel;
    if (!app.dialog_open) return null;
    return zigui.dialog(.{
        .title = "Are you absolutely sure?",
        .description = "This permanently deletes your account and all of its data.",
        .actions = &.{
            .{ .label = "Cancel", .variant = .outline, .on_click = zigui.on(App, close) },
            .{ .label = "Delete", .variant = .destructive, .on_click = zigui.on(App, confirm) },
        },
        .on_dismiss = zigui.on(App, close),
    });
}
