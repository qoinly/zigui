const std = @import("std");
const zigui = @import("zigui");
const Node = zigui.Node;
const Frame = zigui.Frame;
const App = @import("../app.zig").App;
const page = @import("../scaffold/page.zig");

fn on_h(app: *App, x: f32, _: f32) void {
    const rs = &app.resizable;
    rs.h = std.math.clamp((x - rs.snap.h_x) / rs.snap.h_w, 0.18, 0.82);
}
fn on_v(app: *App, _: f32, y: f32) void {
    const rs = &app.resizable;
    rs.v = std.math.clamp((y - rs.snap.v_y) / rs.snap.v_h, 0.2, 0.8);
}

pub fn view(f: *Frame, app: *App) *Node {
    _ = f;
    return page.page(&.{
        page.header("Resizable", "Drag the dividers to resize the panels."),
        zigui.resizable_demo(.{
            .h = &app.resizable.h,
            .v = &app.resizable.v,
            .snap = &app.resizable.snap,
            .on_resize_h = zigui.on_drag(App, on_h),
            .on_resize_v = zigui.on_drag(App, on_v),
        }),
    });
}
