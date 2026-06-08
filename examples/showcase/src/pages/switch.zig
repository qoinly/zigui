const zigui = @import("zigui");
const Node = zigui.Node;
const Frame = zigui.Frame;
const App = @import("../app.zig").App;
const page = @import("../scaffold/page.zig");

fn toggle_airplane(app: *App) void {
    app.forms.sw_airplane = !app.forms.sw_airplane;
}
fn toggle_wifi(app: *App) void {
    app.forms.sw_wifi = !app.forms.sw_wifi;
}

pub fn view(f: *Frame, app: *App) *Node {
    const d = &app.forms;
    return page.page(&.{
        page.header("Switch", "Toggle a setting on or off."),
        page.section(f.theme, "States", &.{
            zigui.toggle(d.sw_airplane, "Airplane mode", .{
                .on_change = zigui.on(App, toggle_airplane),
            }),
            zigui.toggle(d.sw_wifi, "Wi-Fi", .{
                .on_change = zigui.on(App, toggle_wifi),
            }),
        }),
    });
}
