const zigui = @import("zigui");
const Node = zigui.Node;
const Frame = zigui.Frame;
const App = @import("../app.zig").App;
const page = @import("../scaffold/page.zig");

fn on_toggle(app: *App) void {
    app.popover.open = !app.popover.open;
}
fn on_dismiss(app: *App) void {
    app.popover.open = false;
}

pub fn view(f: *Frame, app: *App) *Node {
    return page.page(&.{
        page.header("Popover", "Floating content anchored to a trigger."),
        page.section(f.theme, "Trigger", &.{
            zigui.button("Open popover", .{
                .variant = .outline,
                .on_click = zigui.on(App, on_toggle),
                .rect_out = &app.popover.rect,
            }),
        }),
    });
}

// The floating panel, rendered in the overlay region anchored to the trigger.
pub fn overlay(f: *Frame, app: *App) ?*Node {
    if (!app.popover.open) return null;
    return zigui.popover_overlay(.{
        .title = "Dimensions",
        .description = "Set the layout for this view.",
        .trigger = &app.popover.rect,
        .view_y = f.body.origin.y,
        .view_h = f.body.size.height,
        .on_dismiss = zigui.on(App, on_dismiss),
    });
}
