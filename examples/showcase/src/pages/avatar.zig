const zigui = @import("zigui");
const Node = zigui.Node;
const Frame = zigui.Frame;
const App = @import("../app.zig").App;
const page = @import("../scaffold/page.zig");

pub fn view(f: *Frame, app: *App) *Node {
    _ = app;
    const t = f.theme;
    return page.page(&.{
        page.header("Avatar", "A user image with a text fallback."),
        page.section(t, "Sizes", &.{
            zigui.avatar("OM", 28),
            zigui.avatar("JL", 36),
            zigui.avatar("IN", 48),
            zigui.avatar("WK", 64),
        }),
        page.section(t, "Fallback", &.{
            zigui.avatar("AB", 40),
            zigui.avatar("CD", 40),
            zigui.avatar("Q", 40),
        }),
    });
}
