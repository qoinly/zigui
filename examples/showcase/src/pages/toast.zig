const zigui = @import("zigui");
const Node = zigui.Node;
const Frame = zigui.Frame;
const App = @import("../app.zig").App;
const page = @import("../scaffold/page.zig");

fn show_default(app: *App) void {
    app.toast("Event has been created", .default);
}
fn show_success(app: *App) void {
    app.toast("Your changes were saved", .success);
}
fn show_error(app: *App) void {
    app.toast("Something went wrong", .destructive);
}

pub fn view(f: *Frame, app: *App) *Node {
    _ = app;
    const t = f.theme;
    return page.page(&.{
        page.header("Toast", "A brief, auto-dismissing notification."),
        page.section(t, "Trigger", &.{
            zigui.button("Show toast", .{
                .variant = .default,
                .on_click = zigui.on(App, show_default),
            }),
            zigui.button("Success", .{
                .variant = .outline,
                .on_click = zigui.on(App, show_success),
            }),
            zigui.button("Error", .{
                .variant = .outline,
                .on_click = zigui.on(App, show_error),
            }),
        }),
    });
}
