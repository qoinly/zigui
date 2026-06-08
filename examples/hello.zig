const zigui = @import("zigui");

const App = struct {
    clicks: u32 = 0,
};

pub fn main() !void {
    var state: App = .{};
    var app = try zigui.App.init(.{ .title = "Hello", .size = .{ 800, 600 } });
    defer app.deinit();
    try app.run(&state, .{ .body = render });
}

fn render(f: *zigui.Frame, app: *App) *zigui.Node {
    _ = f;
    _ = app;
    return zigui.col(.{ .pad = .lg, .gap = .md }, &.{
        zigui.text("Hello, zigui.", .{ .size = 28 }),
        zigui.button("Click me", .{ .on_click = zigui.on(App, on_click) }),
    });
}

fn on_click(app: *App) void {
    app.clicks += 1;
}
