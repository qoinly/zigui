// The iOS example, structured like the android-app example: main holds the
// container-scoped state, app.zig owns the view (app bar + navigator), and
// router/pages split the screens - so it grows by adding pages, not by piling into
// main. zigui's iOS backend hands control to UIApplicationMain from App.run, which
// never returns, so the state lives as a container-scoped var (not a stack local)
// and there is no defer app.deinit().
const zigui = @import("zigui");
const app = @import("app.zig");

var state: app.App = .{};

pub fn main() !void {
    var window = try zigui.App.init(.{ .title = "zigui", .size = .{ 390, 844 } });
    try window.run(&state, .{ .body = app.App.render });
}
