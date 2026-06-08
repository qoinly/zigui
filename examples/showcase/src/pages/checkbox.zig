const zigui = @import("zigui");
const Node = zigui.Node;
const Frame = zigui.Frame;
const App = @import("../app.zig").App;
const page = @import("../scaffold/page.zig");

fn toggle_terms(app: *App) void {
    app.forms.cb_terms = !app.forms.cb_terms;
}
fn toggle_news(app: *App) void {
    app.forms.cb_news = !app.forms.cb_news;
}

pub fn view(f: *Frame, app: *App) *Node {
    const d = &app.forms;
    return page.page(&.{
        page.header("Checkbox", "Toggle an option on or off."),
        page.section(f.theme, "States", &.{
            zigui.checkbox(d.cb_terms, "Accept terms and conditions", .{
                .on_change = zigui.on(App, toggle_terms),
            }),
            zigui.checkbox(d.cb_news, "Subscribe to the newsletter", .{
                .on_change = zigui.on(App, toggle_news),
            }),
        }),
    });
}
