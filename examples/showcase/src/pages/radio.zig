const zigui = @import("zigui");
const Node = zigui.Node;
const Frame = zigui.Frame;
const App = @import("../app.zig").App;
const page = @import("../scaffold/page.zig");

fn pick0(app: *App) void {
    app.forms.radio = 0;
}
fn pick1(app: *App) void {
    app.forms.radio = 1;
}
fn pick2(app: *App) void {
    app.forms.radio = 2;
}

pub fn view(f: *Frame, app: *App) *Node {
    const sel = app.forms.radio;
    return page.page(&.{
        page.header("Radio Group", "Pick one option from a set."),
        page.section(f.theme, "Group", &.{
            zigui.col(.{ .gap = .sm }, &.{
                zigui.radio(sel == 0, "Default", .{ .on_change = zigui.on(App, pick0) }),
                zigui.radio(sel == 1, "Comfortable", .{ .on_change = zigui.on(App, pick1) }),
                zigui.radio(sel == 2, "Compact", .{ .on_change = zigui.on(App, pick2) }),
            }),
        }),
    });
}
