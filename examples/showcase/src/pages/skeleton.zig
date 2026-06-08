const zigui = @import("zigui");
const Node = zigui.Node;
const Frame = zigui.Frame;
const App = @import("../app.zig").App;
const page = @import("../scaffold/page.zig");

pub fn view(f: *Frame, app: *App) *Node {
    _ = app;
    const t = f.theme;
    return page.page(&.{
        page.header("Skeleton", "A loading placeholder."),
        page.section(t, "Shapes", &.{
            zigui.row(.{ .gap = .sm, .cross = .center }, &.{
                zigui.skeleton(40, 40, 20),
                zigui.col(.{ .gap = .xs }, &.{
                    zigui.skeleton(180, 12, 4),
                    zigui.skeleton(120, 12, 4),
                }),
            }),
        }),
    });
}
