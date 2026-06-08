const zigui = @import("zigui");
const Node = zigui.Node;
const Frame = zigui.Frame;
const App = @import("../app.zig").App;
const page = @import("../scaffold/page.zig");

pub fn view(f: *Frame, app: *App) *Node {
    _ = f;
    _ = app;
    return page.page(&.{
        page.header("Alert", "A callout for the user's attention."),
        zigui.col(.{ .gap = .md, .max_width = 520 }, &.{
            zigui.alert("Heads up!", .{
                .description = "Add components with the CLI.",
                .icon = .info,
            }),
            zigui.alert("Error", .{
                .description = "Your session has expired.",
                .variant = .destructive,
                .icon = .warning,
            }),
            zigui.alert("Update available", .{ .icon = .arrow_down_circle }),
        }),
    });
}
