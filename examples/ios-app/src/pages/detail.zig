const zigui = @import("zigui");
const Node = zigui.Node;
const Frame = zigui.Frame;
const App = @import("../app.zig").App;
const page = @import("../scaffold/page.zig");

pub fn open(app: *App) void {
    app.nav.push("detail", "Detail");
}

// A pushed page to show navigation: the app bar gains a back chevron that pops it.
pub fn view(f: *Frame, app: *App) *Node {
    _ = f;
    _ = app;
    return page.screen(&.{
        zigui.text("A pushed page. The app-bar chevron (or a swipe) pops back.", .{ .size = 16 }),
    });
}
