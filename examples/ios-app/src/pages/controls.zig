const std = @import("std");
const zigui = @import("zigui");
const Node = zigui.Node;
const Frame = zigui.Frame;
const App = @import("../app.zig").App;

pub fn open(app: *App) void {
    app.nav.push("controls", "Controls");
}

fn tap(app: *App) void {
    app.clicks += 1;
}
fn focus_field(app: *App) void {
    app.focus = 1;
}
fn blur(app: *App) void {
    app.focus = 0;
}

// Touch + keyboard: tapping the field raises the software keyboard and the field
// shows what you type; tapping off it blurs (dismisses the keyboard); the button counts.
pub fn view(f: *Frame, app: *App) *Node {
    const count = std.fmt.allocPrint(f.arena, "tapped {d}", .{app.clicks}) catch "tapped";
    const shell = zigui.Config{
        .pad = .lg,
        .gap = .md,
        .grow = 1,
        .on_click = zigui.on(App, blur),
    };
    return zigui.col(shell, &.{
        zigui.text_input(&app.field, .{
            .placeholder = "type here",
            .focused = app.focus == 1,
            .id = 1,
            .on_focus = zigui.on(App, focus_field),
        }),
        zigui.button("Tap me", .{ .on_click = zigui.on(App, tap) }),
        zigui.text(count, .{ .size = 16 }),
    });
}
