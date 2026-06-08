const std = @import("std");
const text_system = @import("text_system.zig");
const icon = @import("icon.zig");

const Allocator = std.mem.Allocator;
const GlyphBitmap = text_system.GlyphBitmap;
const Icon = icon.Icon;
const IconParams = icon.IconParams;

// Lucide source space: a 24-unit viewBox, 2-unit stroke, round cap + round
// join. The rasterizer reproduces that look with a signed-distance field: a
// pixel's coverage is its distance to the path polyline, so round caps and
// joins fall out for free (distance to a segment endpoint IS a round cap).
const VIEWBOX: f32 = 24.0;
const STROKE: f32 = 2.0;
// Chords per cubic. Fixed (not px-adaptive): 16 is visually smooth across the
// icon sizes drawn here; a 60deg circle arc this finely sampled is sub-pixel.
const CUBIC_STEPS: usize = 16;

pub const Cmd = union(enum) {
    move: [2]f32,
    line: [2]f32,
    cubic: [6]f32, // c1x, c1y, c2x, c2y, x, y
    close,
};

const Seg = struct { ax: f32, ay: f32, bx: f32, by: f32 };

const SegList = std.ArrayListUnmanaged(Seg);

fn dist_to_seg(px: f32, py: f32, s: Seg) f32 {
    const dx = s.bx - s.ax;
    const dy = s.by - s.ay;
    const len2 = dx * dx + dy * dy;
    if (len2 <= 1e-6) return @sqrt((px - s.ax) * (px - s.ax) + (py - s.ay) * (py - s.ay));
    var t = ((px - s.ax) * dx + (py - s.ay) * dy) / len2;
    t = std.math.clamp(t, 0, 1);
    const cx = s.ax + t * dx;
    const cy = s.ay + t * dy;
    return @sqrt((px - cx) * (px - cx) + (py - cy) * (py - cy));
}

// segs is caller-owned + cleared by the caller; grows to fit because complex
// icons reach a few hundred segments and a fixed cap would silently clip them.
fn flatten(cmds: []const Cmd, alloc: Allocator, segs: *SegList) !void {
    std.debug.assert(cmds.len > 0);
    var start_x: f32 = 0;
    var start_y: f32 = 0;
    var cur_x: f32 = 0;
    var cur_y: f32 = 0;
    for (cmds) |cmd| switch (cmd) {
        .move => |p| {
            start_x = p[0];
            start_y = p[1];
            cur_x = p[0];
            cur_y = p[1];
        },
        .line => |p| {
            try segs.append(alloc, .{ .ax = cur_x, .ay = cur_y, .bx = p[0], .by = p[1] });
            cur_x = p[0];
            cur_y = p[1];
        },
        .cubic => |c| {
            // P0 is the cubic start and must stay fixed across the sweep; track
            // the previous sample separately so each chord links sample to sample.
            const p0x = cur_x;
            const p0y = cur_y;
            var prev_x = cur_x;
            var prev_y = cur_y;
            var i: usize = 1;
            while (i <= CUBIC_STEPS) : (i += 1) {
                const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(CUBIC_STEPS));
                const mt = 1 - t;
                const x = mt * mt * mt * p0x + 3 * mt * mt * t * c[0] +
                    3 * mt * t * t * c[2] + t * t * t * c[4];
                const y = mt * mt * mt * p0y + 3 * mt * mt * t * c[1] +
                    3 * mt * t * t * c[3] + t * t * t * c[5];
                try segs.append(alloc, .{ .ax = prev_x, .ay = prev_y, .bx = x, .by = y });
                prev_x = x;
                prev_y = y;
            }
            cur_x = prev_x;
            cur_y = prev_y;
        },
        .close => {
            try segs.append(alloc, .{ .ax = cur_x, .ay = cur_y, .bx = start_x, .by = start_y });
            cur_x = start_x;
            cur_y = start_y;
        },
    };
}

// Coords are in the 24-unit viewBox; everything scales by px/24. The buffer is
// caller-owned + reused.
fn raster(
    buf: *std.ArrayListUnmanaged(u8),
    segs: *SegList,
    allocator: Allocator,
    cmds: []const Cmd,
    px: u32,
) ?GlyphBitmap {
    std.debug.assert(px > 0);
    std.debug.assert(px <= 1024); // caller clamps point_size * scale
    segs.clearRetainingCapacity();
    flatten(cmds, allocator, segs) catch return null;
    if (segs.items.len == 0) return null;

    const n: usize = @as(usize, px) * @as(usize, px);
    std.debug.assert(n > 0);
    buf.clearRetainingCapacity();
    buf.resize(allocator, n) catch return null;

    const scale = @as(f32, @floatFromInt(px)) / VIEWBOX;
    const half = (STROKE * 0.5) * scale; // stroke half-width, in pixels
    const aa: f32 = 0.7; // edge softness, in pixels

    var y: u32 = 0;
    while (y < px) : (y += 1) {
        var x: u32 = 0;
        while (x < px) : (x += 1) {
            const fx = (@as(f32, @floatFromInt(x)) + 0.5) / scale;
            const fy = (@as(f32, @floatFromInt(y)) + 0.5) / scale;
            var d: f32 = 1e9;
            for (segs.items) |s| {
                const dd = dist_to_seg(fx, fy, s) * scale; // distance in pixels
                if (dd < d) d = dd;
            }
            // coverage: 1 inside the stroke, smooth to 0 across the AA band.
            const cov = std.math.clamp((half + aa - d) / (2 * aa), 0, 1);
            buf.items[@as(usize, y) * px + x] = @intFromFloat(cov * 255.0 + 0.5);
        }
    }
    return .{ .width = px, .height = px, .data = buf.items, .is_colored = false };
}

// The bundled icon provider: same role as the native one, but resolves an Icon
// to embedded Lucide path data + strokes it. Portable - identical on every OS.
pub const BundledIcons = struct {
    allocator: Allocator,
    buf: std.ArrayListUnmanaged(u8) = .empty, // bitmap scratch, reused per call
    segs: SegList = .empty, // flattened stroke segments, reused per call

    pub fn init(allocator: Allocator) BundledIcons {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *BundledIcons) void {
        self.buf.deinit(self.allocator);
        self.segs.deinit(self.allocator);
    }

    pub fn rasterize_icon(self: *BundledIcons, ic: Icon, params: IconParams) ?GlyphBitmap {
        return self.rasterize_cmds(lucide.for_icon(ic) orelse return null, params);
    }

    fn rasterize_cmds(self: *BundledIcons, cmds: []const Cmd, params: IconParams) ?GlyphBitmap {
        const px_f = @ceil(params.point_size * params.scale_factor);
        if (px_f <= 0 or px_f > 1024) return null;
        return raster(&self.buf, &self.segs, self.allocator, cmds, @intFromFloat(px_f));
    }
};

// Embedded Lucide path data, generated by tools/icongen.zig: for_icon maps each
// Icon enum member to its path. null = no clean Lucide match (e.g. the *_fill
// members - Lucide is stroke-only), so the caller falls back or skips.
const lucide = @import("icon_lucide_data.zig");

test "raster produces non-empty coverage" {
    var prov = BundledIcons.init(std.testing.allocator);
    defer prov.deinit();
    const bmp = prov.rasterize_icon(
        .chevron_down,
        .{ .name = "", .point_size = 24, .scale_factor = 2 },
    ) orelse return error.NoBitmap;
    try std.testing.expect(bmp.width == 48 and bmp.height == 48);
    var any: bool = false;
    for (bmp.data) |a| {
        if (a > 0) any = true;
    }
    try std.testing.expect(any);
}
