// Opens the custom shell over Wayland and blocks until the window closes.

const zigui = @import("zigui");

pub fn main() !void {
    var app = try zigui.app.App.init();
    defer app.deinit();

    const window = try zigui.Window.open_custom_shell(.{
        .title = "zigui on Wayland",
        .width = 800,
        .height = 600,
        .min_width = 640,
        .min_height = 360,
        .chrome = .custom,
    });
    defer window.deinit();

    app.run_forever();
}
