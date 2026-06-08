const std = @import("std");
const types = @import("../window/types.zig");
const color = @import("../color.zig");

pub const Theme = types.Theme;
pub const Variant = types.Variant;
pub const Size = types.Size;
pub const Rgba = color.Rgba;

pub const Palette = struct {
    bg: Rgba,
    fg: Rgba,
    border: Rgba,
};

pub fn palette_for(variant: Variant, theme: *const Theme) Palette {
    return switch (variant) {
        .default => .{
            .bg = theme.primary,
            .fg = theme.primary_foreground,
            .border = theme.primary,
        },
        .secondary => .{
            .bg = theme.secondary,
            .fg = theme.secondary_foreground,
            .border = theme.secondary,
        },
        .destructive => .{
            .bg = theme.destructive,
            .fg = theme.destructive_foreground,
            .border = theme.destructive,
        },
        .outline => .{ .bg = theme.background, .fg = theme.foreground, .border = theme.border },
        .ghost => .{ .bg = transparent(), .fg = theme.foreground, .border = transparent() },
        .link => .{ .bg = transparent(), .fg = theme.primary, .border = transparent() },
    };
}

pub const ButtonGeom = struct {
    height: f32,
    font_size: f32,
    pad_x: f32, // horizontal hug-sizing inset
};

pub fn button_geom_for(size: Size, theme: *const Theme) ButtonGeom {
    return switch (size) {
        .sm => .{ .height = 32, .font_size = theme.font_size - 1, .pad_x = 12 },
        .default => .{ .height = 36, .font_size = theme.font_size, .pad_x = 16 },
        .lg => .{ .height = 40, .font_size = theme.font_size + 1, .pad_x = 20 },
        .icon => .{ .height = 36, .font_size = theme.font_size, .pad_x = 0 },
        .icon_sm => .{ .height = 28, .font_size = theme.font_size, .pad_x = 0 },
    };
}

pub fn transparent() Rgba {
    return .{ .r = 0, .g = 0, .b = 0, .a = 0 };
}

// One value kit-wide so every control reads disabled the same.
pub const DISABLED_ALPHA: f32 = 0.5;

pub fn fade(c: Rgba, t: f32) Rgba {
    return .{ .r = c.r, .g = c.g, .b = c.b, .a = c.a * t };
}

// Empty result (w/h <= 0) means nothing shows.
pub fn clip_intersect(a: [4]f32, b: [4]f32) [4]f32 {
    const x0 = @max(a[0], b[0]);
    const y0 = @max(a[1], b[1]);
    const x1 = @min(a[0] + a[2], b[0] + b[2]);
    const y1 = @min(a[1] + a[3], b[1] + b[3]);
    return .{ x0, y0, @max(0, x1 - x0), @max(0, y1 - y0) };
}

// Keeps a's alpha so a tint of an opaque token can't go translucent via b's alpha.
pub fn mix(a: Rgba, b: Rgba, t: f32) Rgba {
    std.debug.assert(t >= 0 and t <= 1);
    return .{
        .r = a.r * (1 - t) + b.r * t,
        .g = a.g * (1 - t) + b.g * t,
        .b = a.b * (1 - t) + b.b * t,
        .a = a.a,
    };
}

// Lift toward foreground so an overlay reads as elevated even when popover ==
// background (shipped dark theme). Alpha forced opaque so it can't bleed through.
pub fn elevate(theme: *const Theme, t: f32) Rgba {
    var c = mix(theme.popover, theme.popover_foreground, t);
    c.a = 1;
    return c;
}

pub fn ascii_contains(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var k: usize = 0;
        while (k < needle.len) : (k += 1) {
            const a = haystack[i + k];
            const bb = needle[k];
            const al = if (a >= 'A' and a <= 'Z') a + 32 else a;
            const bl = if (bb >= 'A' and bb <= 'Z') bb + 32 else bb;
            if (al != bl) break;
        }
        if (k == needle.len) return true;
    }
    return false;
}
