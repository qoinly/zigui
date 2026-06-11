// Opens the custom shell over Wayland, hands its surface to the Vulkan
// renderer, and composes a card through the cross-platform label layer -
// word-wrapped body text inside symmetric padding - then blocks until the
// window closes.

const std = @import("std");
const zigui = @import("zigui");

const CARD_X: f32 = 200;
const CARD_Y: f32 = 150;
const CARD_W: f32 = 400;
const CARD_H: f32 = 300;
const PAD: f32 = 24;
const GAP: f32 = 12;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

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

    var ts = zigui.text_system.TextSystem.init(allocator, renderer.get_device());
    defer ts.deinit();

    var prims: std.ArrayListUnmanaged(zigui.Primitive) = .empty;
    defer prims.deinit(allocator);
    var sprites: std.ArrayListUnmanaged(zigui.MonochromeSprite) = .empty;
    defer sprites.deinit(allocator);
    var color_sprites: std.ArrayListUnmanaged(zigui.PolychromeSprite) = .empty;
    defer color_sprites.deinit(allocator);
    var b = zigui.RenderBuilder{
        .prims = &prims,
        .sprites = &sprites,
        .color_sprites = &color_sprites,
        .text_system = &ts,
        .allocator = allocator,
        .scale_factor = 1.0,
    };

    try compose_card(&b, window.theme);

    const bg = window.theme.background;
    const clear = zigui.ClearColor.init(bg.r, bg.g, bg.b, 1);
    renderer.draw_frame(clear, prims.items, sprites.items, ts.mono_atlas_texture(), &.{}, null);

    app.run_forever();
}

// The same label layer macOS/Windows draw through: the body word-wraps into
// the content width (card minus symmetric padding) instead of overflowing.
fn compose_card(b: *zigui.RenderBuilder, theme: zigui.Theme) !void {
    const content_x = CARD_X + PAD;
    const content_w = CARD_W - PAD * 2;

    var card = zigui.Quad.init(CARD_X, CARD_Y, CARD_W, CARD_H);
    _ = card.set_background(.{ .r = 0.10, .g = 0.10, .b = 0.12, .a = 1 });
    _ = card.set_corner_radius(16);
    _ = card.set_border_color(.{ .r = 0.35, .g = 0.35, .b = 0.40, .a = 1 });
    _ = card.set_border_widths(2, 2, 2, 2);
    try b.append_quad(card);

    var y = CARD_Y + PAD;
    const title_style = zigui.render.LabelStyle{ .font_size = 22, .color = theme.foreground };
    const title = zigui.render.label.measure(b, "zigui on Wayland", title_style);
    _ = try zigui.render.label.render(b, content_x, y, "zigui on Wayland", title_style);
    y += title.ascent + title.descent + GAP;

    const body = "The quick brown fox jumps over the lazy dog 0123456789";
    const body_style = zigui.render.LabelStyle{ .font_size = 15, .color = theme.muted_foreground };
    const body_height = try zigui.render.label.render_wrapped(
        b,
        content_x,
        y,
        body,
        body_style,
        content_w,
    );
    y += body_height + GAP;

    const accents = [_][4]f32{
        .{ 0.93, 0.27, 0.27, 1 },
        .{ 0.30, 0.69, 0.31, 1 },
        .{ 0.25, 0.55, 0.96, 1 },
    };
    for (accents, 0..) |rgba, index| {
        const x = content_x + @as(f32, @floatFromInt(index)) * 80;
        var quad = zigui.Quad.init(x, y, 60, 60);
        _ = quad.set_background(.{ .r = rgba[0], .g = rgba[1], .b = rgba[2], .a = rgba[3] });
        _ = quad.set_corner_radius(12);
        try b.append_quad(quad);
    }
}
