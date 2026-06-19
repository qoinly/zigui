// A zigui app driven through the public App.init/run, the same API the desktop
// and Android examples use. zigui's iOS backend hands control to UIApplicationMain
// from App.run and builds the surface; touches route through the shared paint loop,
// so the button responds, the counter updates, and the long list drag-scrolls.
//
// As on Android, App.run does not return - UIApplicationMain owns the loop - so
// the state outlives main() as a container-scoped var, not a stack local, and
// there is no defer app.deinit().
const std = @import("std");
const zigui = @import("zigui");

const App = struct {
    clicks: u32 = 0,
    list: zigui.ScrollState = .{},
};

var state: App = .{};

pub fn main() !void {
    var app = try zigui.App.init(.{ .title = "zigui", .size = .{ 390, 844 } });
    try app.run(&state, .{ .body = render });
}

fn render(f: *zigui.Frame, app: *App) *zigui.Node {
    const head = 3;
    const list_len = 40;
    const rows = f.arena.alloc(*zigui.Node, head + list_len) catch return zigui.text("oom", .{});
    const count = std.fmt.allocPrint(f.arena, "tapped {d}", .{app.clicks}) catch "tapped";
    rows[0] = zigui.text("zigui on iOS", .{ .size = 28 });
    rows[1] = zigui.text(count, .{ .size = 18 });
    rows[2] = zigui.button("Tap me", .{ .on_click = zigui.on(App, on_tap) });
    for (rows[head..], 0..) |*r, i| {
        const label = std.fmt.allocPrint(f.arena, "row {d}", .{i}) catch "row";
        r.* = zigui.text(label, .{ .size = 22 });
    }
    const body = zigui.col(.{ .pad = .lg, .gap = .md }, rows);
    return zigui.scroll(&app.list, .{ .height = f.body.size.height }, body);
}

fn on_tap(app: *App) void {
    app.clicks += 1;
}
