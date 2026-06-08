const std = @import("std");
const zigui = @import("zigui");
const Node = zigui.Node;
const Frame = zigui.Frame;
const App = @import("../app.zig").App;
const page = @import("../scaffold/page.zig");

fn open_side(app: *App, side: zigui.kit.sheet.SheetSide) void {
    app.sheet.side = side;
    app.sheet.open = true;
}
fn on_top(app: *App) void {
    open_side(app, .top);
}
fn on_right(app: *App) void {
    open_side(app, .right);
}
fn on_bottom(app: *App) void {
    open_side(app, .bottom);
}
fn on_left(app: *App) void {
    open_side(app, .left);
}
fn on_close(app: *App) void {
    app.sheet.open = false; // t eases to 0 over the next frames, sliding it out
}

pub fn view(f: *Frame, app: *App) *Node {
    _ = app;
    return page.page(&.{
        page.header("Sheet", "A panel that slides in from an edge of the screen."),
        page.section(f.theme, "Open from", &.{
            zigui.button("Top", .{ .variant = .outline, .on_click = zigui.on(App, on_top) }),
            zigui.button("Right", .{ .variant = .outline, .on_click = zigui.on(App, on_right) }),
            zigui.button("Bottom", .{ .variant = .outline, .on_click = zigui.on(App, on_bottom) }),
            zigui.button("Left", .{ .variant = .outline, .on_click = zigui.on(App, on_left) }),
        }),
    });
}

// The eased open_t lives here (the only per-frame hook): it slides toward the
// target each frame, keeps sliding out after close, and force-closes off-page.
pub fn overlay(f: *Frame, app: *App) ?*Node {
    const s = &app.sheet;
    const on_page = std.mem.eql(u8, app.nav.selected_id, "sheet");
    const target: f32 = if (s.open and on_page) 1 else 0;
    s.t += (target - s.t) * 0.25;
    if (@abs(target - s.t) < 0.005) s.t = target;
    if (s.t != target) zigui.animate(); // keep the loop alive while sliding
    if (s.t <= 0.001) {
        s.open = false; // fully closed; re-entry starts shut
        return null;
    }
    return zigui.sheet(.{
        .side = s.side,
        .open_t = s.t,
        .top_inset = f.body.origin.y,
        .title = "Edit profile",
        .description = "Make changes to your profile, then save.",
        .dismiss = s.open and on_page,
        .on_close = zigui.on(App, on_close),
    });
}
