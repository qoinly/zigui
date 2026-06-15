const zigui = @import("zigui");
const Node = zigui.Node;
const Frame = zigui.Frame;
const App = @import("../app.zig").App;
const page = @import("../scaffold/page.zig");

// startActivity with extras: push this page carrying a payload it reads back.
pub fn open(app: *App) void {
    app.nav.push_with("detail", "Details", "hello from home");
}

// setResult + finish: stage a result, then pop so the home page receives it.
fn save_and_back(app: *App) void {
    app.nav.set_result("saved at 42");
    app.nav.pop();
}

// The pushed page reads the payload it was opened with (current_args) and can stage a
// result for home; the chevron / Back / Esc pop back (Save returns the result).
pub fn view(f: *Frame, app: *App) *Node {
    _ = f;
    return page.screen(&.{
        page.header("Detail page."),
        zigui.text("Got args:", .{ .size = 14 }),
        page.status(app.nav.current_args()),
        zigui.button("Save & back", .{ .on_click = zigui.on(App, save_and_back) }),
        zigui.text("(or Back to return with no result)", .{ .size = 14 }),
    });
}
