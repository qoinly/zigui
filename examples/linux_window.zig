// Opens the custom shell over Wayland, hands its surface to the Vulkan
// renderer, draws a quad scene, and blocks until the window closes.

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

    var renderer = try zigui.Renderer.init(window.metal_layer);
    defer renderer.deinit();

    const bg = window.theme.background;
    const clear = zigui.ClearColor.init(bg.r, bg.g, bg.b, 1);
    const prims = [_]zigui.Primitive{
        .{ .quad = card(200, 150, 400, 300) },
        .{ .quad = accent(230, 180, .{ 0.93, 0.27, 0.27, 1 }) },
        .{ .quad = accent(310, 180, .{ 0.30, 0.69, 0.31, 1 }) },
        .{ .quad = accent(390, 180, .{ 0.25, 0.55, 0.96, 1 }) },
    };
    renderer.draw_frame(clear, &prims, &.{}, null, &.{}, null);

    app.run_forever();
}

fn card(x: f32, y: f32, w: f32, h: f32) zigui.Quad {
    return .{
        .bounds = .{ x, y, w, h },
        .background = .{ 0.10, 0.10, 0.12, 1 },
        .corner_radii = .{ 16, 16, 16, 16 },
        .border_color = .{ 0.35, 0.35, 0.40, 1 },
        .border_widths = .{ 2, 2, 2, 2 },
    };
}

fn accent(x: f32, y: f32, rgba: [4]f32) zigui.Quad {
    return .{
        .bounds = .{ x, y, 60, 60 },
        .background = rgba,
        .corner_radii = .{ 12, 12, 12, 12 },
    };
}
