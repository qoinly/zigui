const std = @import("std");

pub const Rgba = extern struct {
    r: f32 = 0,
    g: f32 = 0,
    b: f32 = 0,
    a: f32 = 1,

    pub fn init(r: f32, g: f32, b: f32, a: f32) Rgba {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }

    pub fn from_u8(r: u8, g: u8, b: u8, a: u8) Rgba {
        const inv: f32 = 1.0 / 255.0;
        return .{
            .r = @as(f32, @floatFromInt(r)) * inv,
            .g = @as(f32, @floatFromInt(g)) * inv,
            .b = @as(f32, @floatFromInt(b)) * inv,
            .a = @as(f32, @floatFromInt(a)) * inv,
        };
    }

    // hex > 0xFFFFFF means RRGGBBAA; otherwise RRGGBB with alpha=255.
    pub fn from_hex(hex: u32) Rgba {
        if (hex > 0xFFFFFF) {
            return from_u8(
                @truncate(hex >> 24),
                @truncate(hex >> 16),
                @truncate(hex >> 8),
                @truncate(hex),
            );
        }
        return from_u8(
            @truncate(hex >> 16),
            @truncate(hex >> 8),
            @truncate(hex),
            255,
        );
    }

    pub const white = Rgba.init(1, 1, 1, 1);
    pub const black = Rgba.init(0, 0, 0, 1);
    pub const red = Rgba.init(1, 0, 0, 1);
    pub const green = Rgba.init(0, 1, 0, 1);
    pub const blue = Rgba.init(0, 0, 1, 1);
    pub const transparent = Rgba.init(0, 0, 0, 0);
};

pub const Hsla = extern struct {
    h: f32 = 0,
    s: f32 = 0,
    l: f32 = 0,
    a: f32 = 1,

    pub fn init(h: f32, s: f32, l: f32, a: f32) Hsla {
        return .{ .h = h, .s = s, .l = l, .a = a };
    }

    pub fn to_rgba(self: Hsla) Rgba {
        if (self.s == 0) return Rgba.init(self.l, self.l, self.l, self.a);

        const h = self.h / 360.0;
        const q = if (self.l < 0.5)
            self.l * (1 + self.s)
        else
            self.l + self.s - self.l * self.s;
        const p = 2 * self.l - q;

        return Rgba.init(
            hue_to_rgb(p, q, h + 1.0 / 3.0),
            hue_to_rgb(p, q, h),
            hue_to_rgb(p, q, h - 1.0 / 3.0),
            self.a,
        );
    }

    fn hue_to_rgb(p: f32, q: f32, t_in: f32) f32 {
        std.debug.assert(t_in >= -1); // the single +1/-1 wrap below only normalizes this range
        std.debug.assert(t_in <= 2);
        var t = t_in;
        if (t < 0) t += 1;
        if (t > 1) t -= 1;
        if (t < 1.0 / 6.0) return p + (q - p) * 6 * t;
        if (t < 1.0 / 2.0) return q;
        if (t < 2.0 / 3.0) return p + (q - p) * (2.0 / 3.0 - t) * 6;
        return p;
    }
};

pub const Background = union(enum) {
    solid: Rgba,
    linear_gradient: LinearGradient,

    pub fn from_rgba(c: Rgba) Background {
        return .{ .solid = c };
    }

    pub fn from_hex(hex: u32) Background {
        return .{ .solid = Rgba.from_hex(hex) };
    }
};

pub const LinearGradient = struct {
    angle: f32 = 0,
    start: Rgba,
    end: Rgba,
};

test "Rgba fromHex 6-digit and 8-digit" {
    const a = Rgba.from_hex(0xFF0000);
    try std.testing.expect(a.r == 1 and a.g == 0 and a.b == 0 and a.a == 1);

    const b = Rgba.from_hex(0xFF000080);
    try std.testing.expect(b.r == 1 and b.g == 0 and b.b == 0);
    try std.testing.expect(@abs(b.a - 128.0 / 255.0) < 1e-6);
}

test "Hsla toRgba" {
    const red_rgb = Hsla.init(0, 1, 0.5, 1).to_rgba();
    try std.testing.expect(@abs(red_rgb.r - 1) < 1e-6);
    try std.testing.expect(@abs(red_rgb.g - 0) < 1e-6);
    try std.testing.expect(@abs(red_rgb.b - 0) < 1e-6);
}
