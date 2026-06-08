const zigui = @import("zigui");
const Node = zigui.Node;
const Frame = zigui.Frame;
const App = @import("../app.zig").App;
const page = @import("../scaffold/page.zig");
const Item = zigui.kit.toggle_group.ToggleGroupItem;

fn align0(app: *App) void {
    app.forms.tgg_align = 0;
}
fn align1(app: *App) void {
    app.forms.tgg_align = 1;
}
fn align2(app: *App) void {
    app.forms.tgg_align = 2;
}
fn fmt_bold(app: *App) void {
    app.forms.tgg_bold = !app.forms.tgg_bold;
}
fn fmt_italic(app: *App) void {
    app.forms.tgg_italic = !app.forms.tgg_italic;
}
fn fmt_underline(app: *App) void {
    app.forms.tgg_underline = !app.forms.tgg_underline;
}

fn item(ic: zigui.Icon, on: bool, cb: zigui.ClickFn, app: *App) Item {
    return .{ .icon = ic, .on = on, .on_toggle = cb, .ctx = app };
}

pub fn view(f: *Frame, app: *App) *Node {
    const d = &app.forms;
    return page.page(&.{
        page.header("Toggle Group", "A set of two-state buttons."),
        page.section(f.theme, "Single select (alignment)", &.{
            zigui.toggle_group(&.{
                item(.align_left, d.tgg_align == 0, zigui.on(App, align0), app),
                item(.align_center, d.tgg_align == 1, zigui.on(App, align1), app),
                item(.align_right, d.tgg_align == 2, zigui.on(App, align2), app),
            }, .{ .variant = .outline, .connected = true }),
        }),
        page.section(f.theme, "Multiple select (format)", &.{
            zigui.toggle_group(&.{
                item(.bold, d.tgg_bold, zigui.on(App, fmt_bold), app),
                item(.italic, d.tgg_italic, zigui.on(App, fmt_italic), app),
                item(.underline, d.tgg_underline, zigui.on(App, fmt_underline), app),
            }, .{ .variant = .outline }),
        }),
    });
}
