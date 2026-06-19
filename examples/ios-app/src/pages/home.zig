const zigui = @import("zigui");
const Node = zigui.Node;
const Frame = zigui.Frame;
const App = @import("../app.zig").App;
const page = @import("../scaffold/page.zig");
const controls = @import("controls.zig");
const list = @import("list.zig");
const detail = @import("detail.zig");

// The root menu: each button pushes a demo page (the app bar shows its title and a
// back chevron).
pub fn view(f: *Frame, app: *App) *Node {
    _ = f;
    _ = app;
    return page.screen(&.{
        zigui.button("Controls", .{ .on_click = zigui.on(App, controls.open) }),
        zigui.button("Scrolling list", .{ .on_click = zigui.on(App, list.open) }),
        zigui.button("Detail", .{ .on_click = zigui.on(App, detail.open) }),
    });
}
