const zigui = @import("zigui");
const Node = zigui.Node;
const Frame = zigui.Frame;
const App = @import("../app.zig").App;
const page = @import("../scaffold/page.zig");

fn open(app: *App) void {
    app.dialog_open = true;
}

pub fn view(f: *Frame, app: *App) *Node {
    _ = app;
    return page.page(&.{
        page.header("Dialog", "A modal window that interrupts for a decision."),
        page.section(f.theme, "Trigger", &.{
            zigui.button("Delete account", .{
                .variant = .destructive,
                .on_click = zigui.on(App, open),
            }),
        }),
    });
}
