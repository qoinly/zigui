const zigui = @import("zigui");
const Node = zigui.Node;
const Frame = zigui.Frame;
const App = @import("../app.zig").App;
const page = @import("../scaffold/page.zig");

pub fn open(app: *App) void {
    app.nav.push("kit", "Kit UI");
}

// The dialog + sheet live in the overlay region, the toast in the hud region; these
// just flip the state the scaffold reads.
fn open_dialog(app: *App) void {
    app.dialog_open = true;
}
fn open_sheet(app: *App) void {
    app.sheet_open = true;
}
fn show_toast(app: *App) void {
    app.toast("Saved (kit toast, not native)", .default);
}

// The kit-widget surface: a card (a styled surface), and triggers for the modal
// dialog + edge sheet (overlay region) and the in-app toast stack (hud region) - all
// kit-rendered through the same GPU renderer as desktop, not native Android views.
pub fn view(f: *Frame, app: *App) *Node {
    _ = app;
    const t = f.theme;
    return page.screen(&.{
        page.header("Kit widgets."),
        zigui.col(.{
            .gap = .sm,
            .pad = .lg,
            .bg = t.card,
            .border = t.border,
            .radius = t.radius,
        }, &.{
            zigui.text("Card", .{ .size = 16, .weight = .semi_bold }),
            zigui.text("A surface grouping content.", .{ .size = 13, .muted = true }),
            zigui.separator(.horizontal),
            zigui.text("Same renderer as desktop.", .{ .size = 13 }),
        }),
        zigui.button("Open dialog", .{ .on_click = zigui.on(App, open_dialog) }),
        zigui.button("Open sheet", .{ .on_click = zigui.on(App, open_sheet) }),
        zigui.button("Show toast", .{ .on_click = zigui.on(App, show_toast) }),
    });
}
