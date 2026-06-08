const zigui = @import("zigui");
const Node = zigui.Node;
const Frame = zigui.Frame;
const Theme = zigui.Theme;
const App = @import("../app.zig").App;
const page = @import("../scaffold/page.zig");

fn card_box(t: *const Theme, kids: []const *Node) *Node {
    return zigui.col(.{
        .gap = .sm,
        .pad = .lg,
        .min_width = 260,
        .max_width = 360,
        .grow = 1,
        .bg = t.card,
        .border = t.border,
        .radius = t.radius,
    }, kids);
}

pub fn view(f: *Frame, app: *App) *Node {
    _ = app;
    const t = f.theme;
    return page.page(&.{
        page.header("Card", "A surface that groups related content."),
        zigui.row(.{ .gap = .md, .wrap = true }, &.{
            card_box(t, &.{
                zigui.text("Create project", .{ .size = 16, .weight = .semi_bold }),
                zigui.text("Deploy your new project in one click.", .{ .size = 13, .muted = true }),
                zigui.separator(.horizontal),
                zigui.text("Name your project and pick a framework.", .{ .size = 13 }),
                zigui.row(.{ .gap = .sm }, &.{
                    zigui.button("Cancel", .{ .variant = .outline }),
                    zigui.button("Deploy", .{ .variant = .default }),
                }),
            }),
            card_box(t, &.{
                zigui.text("Total Revenue", .{ .size = 13, .muted = true }),
                zigui.text("$15,231.89", .{ .size = 26, .weight = .semi_bold }),
                zigui.text("+20.1% from last month", .{ .size = 12, .color = t.success }),
            }),
        }),
    });
}
