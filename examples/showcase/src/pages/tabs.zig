const zigui = @import("zigui");
const Node = zigui.Node;
const Frame = zigui.Frame;
const App = @import("../app.zig").App;
const page = @import("../scaffold/page.zig");

const COMP_TABS = [_][]const u8{ "Account", "Password", "Team", "Billing" };

fn on_select(app: *App, idx: usize) void {
    app.tabs.sel = idx;
}

pub fn view(f: *Frame, app: *App) *Node {
    const t = f.theme;
    const body = switch (app.tabs.sel) {
        0 => "Make changes to your account.",
        1 => "Change your password here.",
        2 => "Manage your team members.",
        else => "Manage billing and plan.",
    };
    return page.page(&.{
        page.header("Tabs", "Switch between related views."),
        zigui.col(.{ .gap = .md, .max_width = 520 }, &.{
            zigui.tabs(&COMP_TABS, &app.tabs.state, .{
                .selected = app.tabs.sel,
                .on_select = zigui.on_index(App, on_select),
            }),
            zigui.col(.{
                .pad = .lg,
                .bg = t.card,
                .border = t.border,
                .radius = t.radius,
            }, &.{
                zigui.text(body, .{ .size = 13 }),
            }),
        }),
    });
}
