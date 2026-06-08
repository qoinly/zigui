const zigui = @import("zigui");
const Node = zigui.Node;
const Frame = zigui.Frame;
const App = @import("../app.zig").App;
const page = @import("../scaffold/page.zig");

pub fn view(f: *Frame, app: *App) *Node {
    _ = app;
    const t = f.theme;
    return page.page(&.{
        page.header("Badge", "A small status or count label."),
        page.section(t, "Variants", &.{
            zigui.badge("Default", .default),
            zigui.badge("Secondary", .secondary),
            zigui.badge("Destructive", .destructive),
            zigui.badge("Outline", .outline),
        }),
        page.section(t, "Counts", &.{
            zigui.badge("1", .default),
            zigui.badge("8", .secondary),
            zigui.badge("99+", .destructive),
        }),
    });
}
