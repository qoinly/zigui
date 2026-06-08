const zigui = @import("zigui");
const Node = zigui.Node;
const Frame = zigui.Frame;
const App = @import("../app.zig").App;
const page = @import("../scaffold/page.zig");

pub fn view(f: *Frame, app: *App) *Node {
    _ = app;
    const t = f.theme;
    return page.page(&.{
        page.header("Separator", "Divides content into sections."),
        page.section(t, "Horizontal", &.{
            page.sized(320, zigui.col(.{ .gap = .sm }, &.{
                zigui.text("Acme Inc", .{ .size = 13, .weight = .semi_bold }),
                zigui.text("An open-source UI kit.", .{ .size = 12, .muted = true }),
                zigui.separator(.horizontal),
                zigui.row(.{ .gap = .md }, &.{
                    zigui.text("Blog", .{ .size = 12, .muted = true }),
                    zigui.text("Docs", .{ .size = 12, .muted = true }),
                    zigui.text("Source", .{ .size = 12, .muted = true }),
                }),
            })),
        }),
    });
}
