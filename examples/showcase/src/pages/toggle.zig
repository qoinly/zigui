const zigui = @import("zigui");
const Node = zigui.Node;
const Frame = zigui.Frame;
const App = @import("../app.zig").App;
const page = @import("../scaffold/page.zig");

fn t_bold(app: *App) void {
    app.forms.tg_bold = !app.forms.tg_bold;
}
fn t_italic(app: *App) void {
    app.forms.tg_italic = !app.forms.tg_italic;
}
fn t_b(app: *App) void {
    app.forms.tg_b = !app.forms.tg_b;
}
fn t_i(app: *App) void {
    app.forms.tg_i = !app.forms.tg_i;
}
fn t_u(app: *App) void {
    app.forms.tg_u = !app.forms.tg_u;
}

pub fn view(f: *Frame, app: *App) *Node {
    const d = &app.forms;
    return page.page(&.{
        page.header("Toggle", "A two-state on/off button."),
        page.section(f.theme, "States", &.{
            zigui.toggle_button("Bold", .{
                .on = d.tg_bold,
                .on_toggle = zigui.on(App, t_bold),
            }),
            zigui.toggle_button("Italic", .{
                .on = d.tg_italic,
                .on_toggle = zigui.on(App, t_italic),
            }),
        }),
        page.section(f.theme, "Icon", &.{
            zigui.toggle_button("", .{
                .on = d.tg_b,
                .size = .icon,
                .icon = .bold,
                .on_toggle = zigui.on(App, t_b),
            }),
            zigui.toggle_button("", .{
                .on = d.tg_i,
                .size = .icon,
                .icon = .italic,
                .on_toggle = zigui.on(App, t_i),
            }),
            zigui.toggle_button("", .{
                .on = d.tg_u,
                .size = .icon,
                .icon = .underline,
                .on_toggle = zigui.on(App, t_u),
            }),
        }),
    });
}
