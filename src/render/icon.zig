const std = @import("std");
const color = @import("../color.zig");
const icon_system = @import("../icon.zig");
const builder = @import("builder.zig");

const RenderBuilder = builder.RenderBuilder;
const RenderError = builder.RenderError;
const IconParams = icon_system.IconParams;
const IconWeight = icon_system.IconWeight;
const IconScale = icon_system.IconScale;
pub const Icon = icon_system.Icon;
pub const IconSource = icon_system.IconSource;

pub const Style = struct {
    point_size: f32 = 14,
    weight: IconWeight = .regular,
    scale: IconScale = .medium,
    color: color.Rgba = .{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 },
    source: ?IconSource = null, // null = the engine default source (see set_source)
};

pub const Size = struct { width: f32, height: f32 };

// Portable Icon: resolve the enum member through the active provider (native OS
// symbol or the embedded Lucide set). null folds both failure causes - glyph
// missing / atlas exhausted - so the caller skips.
pub fn render_icon(b: *RenderBuilder, x: f32, y: f32, ic: Icon, style: Style) RenderError!?Size {
    const icons = b.icon_system orelse return null;
    const source = style.source orelse icons.default_source;
    const params = IconParams{
        .name = "",
        .point_size = style.point_size,
        .weight = style.weight,
        .scale = style.scale,
        .scale_factor = b.scale_factor,
    };
    const sprite = icons.sprite_icon(ic, source, params, x, y, style.color) orelse return null;
    try b.sprites.append(b.allocator, sprite);
    return .{ .width = sprite.size[0], .height = sprite.size[1] };
}

// point_size is not the rendered glyph height, so recenter using the laid-out
// sprite's real height. h = 0 centers on top.
pub fn render_icon_centered_y(
    b: *RenderBuilder,
    x: f32,
    top: f32,
    h: f32,
    ic: Icon,
    style: Style,
) RenderError!?Size {
    const idx = b.sprites.items.len;
    const sz = (try render_icon(b, x, top, ic, style)) orelse return null;
    if (idx < b.sprites.items.len) b.sprites.items[idx].position[1] = top + (h - sz.height) / 2;
    return sz;
}

pub fn render_icon_centered_xy(
    b: *RenderBuilder,
    left: f32,
    top: f32,
    w: f32,
    h: f32,
    ic: Icon,
    style: Style,
) RenderError!?Size {
    std.debug.assert(w >= 0);
    std.debug.assert(h >= 0);
    const idx = b.sprites.items.len;
    const sz = (try render_icon(b, left, top, ic, style)) orelse return null;
    if (idx < b.sprites.items.len) {
        b.sprites.items[idx].position[0] = left + (w - sz.width) / 2;
        b.sprites.items[idx].position[1] = top + (h - sz.height) / 2;
    }
    return sz;
}
