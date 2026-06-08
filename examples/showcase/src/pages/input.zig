const zigui = @import("zigui");
const Node = zigui.Node;
const Frame = zigui.Frame;
const App = @import("../app.zig").App;
const page = @import("../scaffold/page.zig");

fn focus1(app: *App) void {
    app.forms.in_focus = 1;
}
fn focus2(app: *App) void {
    app.forms.in_focus = 2;
}
fn focus3(app: *App) void {
    app.forms.in_focus = 3;
}
fn focus_edit(app: *App) void {
    app.forms.in_focus = 4;
}
fn blur(app: *App) void {
    app.forms.in_focus = 0;
}

fn inp(app: *App, id: u32, ph: []const u8, size: zigui.kit.Size, on_focus: zigui.ClickFn) *Node {
    return page.sized(240, zigui.text_input(&app.forms.inputs[id - 1], .{
        .placeholder = ph,
        .size = size,
        .focused = app.forms.in_focus == id,
        .id = id,
        .on_focus = on_focus,
    }));
}

pub fn view(f: *Frame, app: *App) *Node {
    const t = f.theme;
    if (!app.forms.editable_seeded) {
        app.forms.editable.set("Project Phoenix");
        app.forms.editable_seeded = true;
    }
    // A click that misses every field blurs the shared native editor.
    return zigui.col(.{ .grow = 1, .on_click = zigui.on(App, blur) }, &.{
        page.page(&.{
            page.header("Input", "A single-line text field. Click one and type."),
            page.section(t, "Sizes", &.{
                inp(app, 1, "Small", .sm, zigui.on(App, focus1)),
                inp(app, 2, "Default", .default, zigui.on(App, focus2)),
                inp(app, 3, "Large", .lg, zigui.on(App, focus3)),
            }),
            page.section(t, "Editable text (click to edit)", &.{
                page.sized(240, zigui.text_editable(&app.forms.editable, .{
                    .placeholder = "Click to edit",
                    .focused = app.forms.in_focus == 4,
                    .id = 4,
                    .on_focus = zigui.on(App, focus_edit),
                })),
            }),
            page.section(t, "Disabled", &.{
                page.sized(240, zigui.input(
                    "Cannot edit this",
                    "",
                    .default,
                    .{ .disabled = true },
                )),
            }),
            page.section(t, "Invalid", &.{
                zigui.col(.{ .gap = .xs }, &.{
                    page.sized(240, zigui.input(
                        "not-an-email",
                        "",
                        .default,
                        .{ .invalid = true },
                    )),
                    zigui.text("Enter a valid email address.", .{
                        .size = 12,
                        .color = t.destructive,
                    }),
                }),
            }),
        }),
    });
}
