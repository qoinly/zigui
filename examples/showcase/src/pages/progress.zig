const zigui = @import("zigui");
const Node = zigui.Node;
const Frame = zigui.Frame;
const App = @import("../app.zig").App;
const page = @import("../scaffold/page.zig");

pub fn view(f: *Frame, app: *App) *Node {
    _ = app;
    const t = f.theme;
    return page.page(&.{
        page.header("Progress", "Shows completion progress."),
        page.section(t, "Values", &.{
            zigui.col(.{ .gap = .md, .grow = 1, .max_width = 360 }, &.{
                zigui.progress(0.25, 8),
                zigui.progress(0.6, 8),
                zigui.progress(0.9, 8),
            }),
        }),
        page.section(t, "Sizes", &.{
            zigui.col(.{ .gap = .md, .grow = 1, .max_width = 360 }, &.{
                zigui.progress(0.5, 4),
                zigui.progress(0.5, 8),
                zigui.progress(0.5, 14),
            }),
        }),
        page.section(t, "Indeterminate", &.{
            zigui.col(.{ .grow = 1, .max_width = 360 }, &.{
                zigui.progress_indeterminate(8),
            }),
        }),
        page.section(t, "Download", &.{
            zigui.col(.{ .gap = .xs, .grow = 1, .max_width = 360 }, &.{
                zigui.row(.{ .cross = .center }, &.{
                    zigui.text("Downloading...", .{ .size = 12, .muted = true }),
                    zigui.spacer(),
                    zigui.text("65%", .{ .size = 12, .muted = true }),
                }),
                zigui.progress(0.65, 8),
            }),
        }),
    });
}
