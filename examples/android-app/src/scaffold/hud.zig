const zigui = @import("zigui");
const Node = zigui.Node;
const Frame = zigui.Frame;
const App = @import("../app.zig").App;

// The non-modal top layer: the in-app toast stack, fired from the Kit UI page. Never
// freezes the body; renders only while a slot is live.
pub fn view(f: *Frame, app: *App) ?*Node {
    _ = f;
    for (app.toasts) |s| {
        if (s.active) return zigui.toasts(.{ .slots = &app.toasts });
    }
    return null;
}
