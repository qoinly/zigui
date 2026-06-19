// A zigui app driven through the public App.init/run, the same API the desktop
// and Android examples use. zigui's iOS backend hands control to UIApplicationMain
// from App.run and builds the surface; touches route through the shared paint loop,
// so the button below responds and the counter updates.
//
// As on Android, App.run does not return - UIApplicationMain owns the loop - so
// the state outlives main() as a container-scoped var, not a stack local, and
// there is no defer app.deinit().
const std = @import("std");
const zigui = @import("zigui");

const App = struct {
    clicks: u32 = 0,
};

var state: App = .{};

pub fn main() !void {
    var app = try zigui.App.init(.{ .title = "zigui", .size = .{ 390, 844 } });
    try app.run(&state, .{ .body = render });
}

fn render(f: *zigui.Frame, app: *App) *zigui.Node {
    const count = std.fmt.allocPrint(f.arena, "tapped {d}", .{app.clicks}) catch "tapped";
    return zigui.col(.{ .pad = .lg, .gap = .md }, &.{
        zigui.text("zigui on iOS", .{ .size = 28 }),
        zigui.text(count, .{ .size = 18 }),
        zigui.button("Tap me", .{ .on_click = zigui.on(App, on_tap) }),
    });
}

fn on_tap(app: *App) void {
    app.clicks += 1;
}
