// The iOS example: main holds the container-scoped state and app.zig owns the view (a
// bottom tab bar, a collapsing top nav bar, and a pushed detail page). zigui's iOS
// backend hands control to UIApplicationMain from App.run, which never returns, so the
// state lives as a container-scoped var (not a stack local) and there is no defer
// app.deinit().
const zigui = @import("zigui");
const app = @import("app.zig");

var state: app.App = .{};

pub fn main() !void {
    var window = try zigui.App.init(.{ .title = "zigui", .size = .{ 390, 844 } });
    try window.run(&state, .{ .body = app.App.render });
}
