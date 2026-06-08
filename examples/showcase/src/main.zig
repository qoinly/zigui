const zigui = @import("zigui");
const App = @import("app.zig").App;
const titlebar = @import("scaffold/titlebar.zig");
const overlay = @import("scaffold/overlay.zig");
const hud = @import("scaffold/hud.zig");

pub fn main() !void {
    var state: App = .{};
    var app = try zigui.App.init(.{
        .title = "zigui showcase",
        .size = .{ 1100, 720 },
        .min_size = .{ 560, 200 },
    });
    defer app.deinit();
    try app.run(&state, .{
        .body = App.view,
        .titlebar = titlebar.view,
        .overlay = overlay.view,
        .hud = hud.view,
    });
}
