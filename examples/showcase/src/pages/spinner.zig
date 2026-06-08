const zigui = @import("zigui");
const Node = zigui.Node;
const Frame = zigui.Frame;
const App = @import("../app.zig").App;
const page = @import("../scaffold/page.zig");

pub fn view(f: *Frame, app: *App) *Node {
    _ = app;
    const t = f.theme;
    return page.page(&.{
        page.header("Spinner", "An indeterminate loading indicator."),
        page.section(t, "Sizes", &.{
            zigui.spinner(8, t.primary),
            zigui.spinner(12, t.primary),
            zigui.spinner(16, t.muted_foreground),
        }),
    });
}
