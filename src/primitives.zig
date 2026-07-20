const std = @import("std");
const geometry = @import("geometry.zig");
const color = @import("color.zig");

const no_clip: [4]f32 = .{ -1e9, -1e9, 2e9, 2e9 };

// extern struct layouts mirror Metal shader inputs; field order + size matter.
pub const Quad = extern struct {
    bounds: [4]f32 = .{ 0, 0, 0, 0 },
    background: [4]f32 = .{ 0, 0, 0, 0 },
    corner_radii: [4]f32 = .{ 0, 0, 0, 0 },
    border_color: [4]f32 = .{ 0, 0, 0, 0 },
    border_widths: [4]f32 = .{ 0, 0, 0, 0 },
    // rotation_angle (radians), scale_x, scale_y, _pad.
    transform: [4]f32 = .{ 0, 1, 1, 0 },
    clip_bounds: [4]f32 = no_clip,
    // dash px, gap px, _pad, _pad. Both 0 = a solid border (the default).
    border_dash: [4]f32 = .{ 0, 0, 0, 0 },

    const Self = @This();

    pub fn init(x: f32, y: f32, width: f32, height: f32) Self {
        std.debug.assert(width >= 0);
        std.debug.assert(height >= 0);
        return .{ .bounds = .{ x, y, width, height } };
    }

    pub fn set_background(self: *Self, rgba: color.Rgba) *Self {
        self.background = .{ rgba.r, rgba.g, rgba.b, rgba.a };
        return self;
    }

    pub fn set_background_hex(self: *Self, hex: u32) *Self {
        return self.set_background(color.Rgba.from_hex(hex));
    }

    pub fn set_corner_radius(self: *Self, radius: f32) *Self {
        self.corner_radii = .{ radius, radius, radius, radius };
        return self;
    }

    pub fn set_corner_radii(self: *Self, tl: f32, tr: f32, bl: f32, br: f32) *Self {
        self.corner_radii = .{ tl, tr, bl, br };
        return self;
    }

    pub fn set_border_color(self: *Self, rgba: color.Rgba) *Self {
        self.border_color = .{ rgba.r, rgba.g, rgba.b, rgba.a };
        return self;
    }

    pub fn set_border_widths(self: *Self, top: f32, right: f32, bottom: f32, left: f32) *Self {
        self.border_widths = .{ top, right, bottom, left };
        return self;
    }

    pub fn set_border_width(self: *Self, width: f32) *Self {
        self.border_widths = .{ width, width, width, width };
        return self;
    }

    // Dash the border: `dash` px painted, `gap` px skipped, repeating. (0,0) = solid.
    pub fn set_border_dash(self: *Self, dash: f32, gap: f32) *Self {
        self.border_dash = .{ dash, gap, 0, 0 };
        return self;
    }

    pub fn set_clip_bounds(self: *Self, clip: [4]f32) *Self {
        self.clip_bounds = clip;
        return self;
    }

    pub fn set_rotation(self: *Self, angle_rad: f32) *Self {
        self.transform[0] = angle_rad;
        return self;
    }

    pub fn set_scale(self: *Self, scale_x: f32, scale_y: f32) *Self {
        self.transform[1] = scale_x;
        self.transform[2] = scale_y;
        return self;
    }

    pub fn set_uniform_scale(self: *Self, scale: f32) *Self {
        self.transform[1] = scale;
        self.transform[2] = scale;
        return self;
    }

    pub fn set_transform(self: *Self, angle_rad: f32, scale_x: f32, scale_y: f32) *Self {
        self.transform = .{ angle_rad, scale_x, scale_y, 0 };
        return self;
    }
};

pub const MonochromeSprite = extern struct {
    position: [2]f32,
    size: [2]f32,
    uv_origin: [2]f32,
    uv_size: [2]f32,
    sprite_color: [4]f32,
    clip_bounds: [4]f32 = no_clip,

    pub fn init(
        pos_x: f32,
        pos_y: f32,
        width: f32,
        height: f32,
        atlas_x: f32,
        atlas_y: f32,
        atlas_w: f32,
        atlas_h: f32,
        rgba: color.Rgba,
    ) MonochromeSprite {
        return .{
            .position = .{ pos_x, pos_y },
            .size = .{ width, height },
            .uv_origin = .{ atlas_x, atlas_y },
            .uv_size = .{ atlas_w, atlas_h },
            .sprite_color = .{ rgba.r, rgba.g, rgba.b, rgba.a },
        };
    }

    pub fn set_clip_bounds(self: *MonochromeSprite, clip: [4]f32) *MonochromeSprite {
        self.clip_bounds = clip;
        return self;
    }
};

pub const PolychromeSprite = extern struct {
    position: [2]f32,
    size: [2]f32,
    uv_origin: [2]f32,
    uv_size: [2]f32,
    clip_bounds: [4]f32 = no_clip,

    pub fn init(
        pos_x: f32,
        pos_y: f32,
        width: f32,
        height: f32,
        atlas_x: f32,
        atlas_y: f32,
        atlas_w: f32,
        atlas_h: f32,
    ) PolychromeSprite {
        return .{
            .position = .{ pos_x, pos_y },
            .size = .{ width, height },
            .uv_origin = .{ atlas_x, atlas_y },
            .uv_size = .{ atlas_w, atlas_h },
        };
    }

    pub fn set_clip_bounds(self: *PolychromeSprite, clip: [4]f32) *PolychromeSprite {
        self.clip_bounds = clip;
        return self;
    }
};

// 64-byte stride, float4s on 16-byte boundaries: Metal's per-instance
// read stride must match Zig @sizeOf.
pub const Polyline = extern struct {
    pos_a: [2]f32, // 0..8
    pos_b: [2]f32, // 8..16
    fill_color: [4]f32, // 16..32 (float4 aligned)
    clip_bounds: [4]f32 = no_clip, // 32..48
    baseline_y: f32, // 48..52
    gradient: f32 = 0, // 52..56 (0 = solid; 1 = fade alpha to 0 at the baseline)
    _pad: [2]f32 = .{ 0, 0 }, // 56..64
    pub fn init(ax: f32, ay: f32, bx: f32, by: f32, baseline: f32, rgba: color.Rgba) Polyline {
        return .{
            .pos_a = .{ ax, ay },
            .pos_b = .{ bx, by },
            .baseline_y = baseline,
            .fill_color = .{ rgba.r, rgba.g, rgba.b, rgba.a },
        };
    }

    pub fn set_gradient(self: *Polyline, g: f32) *Polyline {
        self.gradient = g;
        return self;
    }
};

// Vertex shader expands the segment into a quad perpendicular to
// (pos_b - pos_a). 64-byte stride; same ABI rule as Polyline.
pub const LineSegment = extern struct {
    pos_a: [2]f32, // 0..8
    pos_b: [2]f32, // 8..16
    color: [4]f32, // 16..32
    clip_bounds: [4]f32 = no_clip, // 32..48
    thickness: f32, // 48..52
    _pad: [3]f32 = .{ 0, 0, 0 }, // 52..64

    pub fn init(ax: f32, ay: f32, bx: f32, by: f32, thickness: f32, rgba: color.Rgba) LineSegment {
        return .{
            .pos_a = .{ ax, ay },
            .pos_b = .{ bx, by },
            .color = .{ rgba.r, rgba.g, rgba.b, rgba.a },
            .thickness = thickness,
        };
    }
};

// SDF annulus + arc sweep in the fragment shader. 80-byte stride,
// float4s on 16-byte boundaries to keep Zig @sizeOf == Metal stride.
pub const RingChart = extern struct {
    fill_color: [4]f32, // 0..16
    track_color: [4]f32, // 16..32
    clip_bounds: [4]f32 = no_clip, // 32..48
    bounds: [4]f32, // 48..64 (x, y, w, h)
    progress: f32, // 64..68 (0..1)
    inner_ratio: f32, // 68..72 (inner_r / outer_r, 0..1)
    start_angle_deg: f32 = -90.0, // 72..76 (-90 = 12 o'clock)
    _pad: f32 = 0, // 76..80

    pub fn init(
        x: f32,
        y: f32,
        size: f32,
        progress: f32,
        inner_ratio: f32,
        fill: color.Rgba,
        track: color.Rgba,
    ) RingChart {
        std.debug.assert(progress >= 0);
        std.debug.assert(progress <= 1);
        std.debug.assert(inner_ratio >= 0);
        std.debug.assert(inner_ratio <= 1);
        return .{
            .fill_color = .{ fill.r, fill.g, fill.b, fill.a },
            .track_color = .{ track.r, track.g, track.b, track.a },
            .bounds = .{ x, y, size, size },
            .progress = progress,
            .inner_ratio = inner_ratio,
        };
    }
};

// A live external frame (remote screen / video): a textured quad sampling a
// caller-owned GPU texture, not the glyph atlas. tex is the platform texture
// handle (Metal id / D3D11 SRV) the backend casts + binds. Plain (not extern):
// it carries a pointer and is CPU-side dispatch, never a GPU instance buffer.
// tex_cbcr set means NV12: tex is the luma plane, tex_cbcr the chroma plane, and
// csc the YUV->RGB matrix. Null tex_cbcr means tex is a ready BGRA image.
pub const Frame = struct {
    bounds: [4]f32 = .{ 0, 0, 0, 0 }, // x, y, w, h in points
    clip_bounds: [4]f32 = no_clip,
    tex: ?*anyopaque = null,
    tex_cbcr: ?*anyopaque = null,
    csc: [3][4]f32 = .{.{ 0, 0, 0, 0 }} ** 3,
    opacity: f32 = 1.0,
};

pub const Primitive = union(enum) {
    quad: Quad,
    polyline: Polyline,
    line_segment: LineSegment,
    ring_chart: RingChart,
    frame: Frame,
};

// Unit square (two triangles); instanced by the Metal shader.
pub const quad_vertices = [_]f32{
    0.0, 0.0,
    1.0, 0.0,
    0.0, 1.0,
    0.0, 1.0,
    1.0, 0.0,
    1.0, 1.0,
};

test "Quad init + chained setters" {
    var q = Quad.init(10, 20, 100, 50);
    _ = q.set_background_hex(0xFF0000).set_corner_radius(8).set_border_width(2);
    try std.testing.expect(q.bounds[0] == 10 and q.bounds[2] == 100);
    try std.testing.expect(q.background[0] == 1 and q.background[3] == 1);
    try std.testing.expect(q.corner_radii[0] == 8 and q.corner_radii[3] == 8);
    try std.testing.expect(q.border_widths[1] == 2);
}
