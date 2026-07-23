const std = @import("std");
const primitives = @import("../primitives.zig");
const text_system = @import("../text_system.zig");
const icon_system = @import("../icon.zig");
const app_icon = @import("../app_icon.zig");

const Allocator = std.mem.Allocator;

// Named + exported so the whole library boundary stays RenderError!T, never an
// inferred or anyerror union.
pub const RenderError = error{OutOfMemory};

pub const RenderBuilder = struct {
    prims: *std.ArrayListUnmanaged(primitives.Primitive),
    sprites: *std.ArrayListUnmanaged(primitives.MonochromeSprite),
    color_sprites: *std.ArrayListUnmanaged(primitives.PolychromeSprite),
    color_atlas: *text_system.ColorAtlas,
    text_system: *text_system.TextSystem,
    icon_system: ?*icon_system.IconSystem = null,
    app_icon_resolver: ?*app_icon.AppIconResolver = null,
    allocator: Allocator,
    scale_factor: f32,

    pub fn append_quad(self: *RenderBuilder, q: primitives.Quad) !void {
        var qq = q;
        // Crisp 1px borders at 1x: a bordered box on a fractional pixel position
        // anti-aliases its 1px edges into a faint line (worst on the bottom edge).
        // Snap bordered quads to the device grid, the same way text sprites round
        // at 1x. Fills (no border) are left alone, and at 2x+ subpixel placement is
        // finer than the border so no snapping is needed.
        const bw = qq.border_widths;
        if (self.scale_factor == 1.0 and (bw[0] > 0 or bw[1] > 0 or bw[2] > 0 or bw[3] > 0)) {
            const x0 = @round(qq.bounds[0]);
            const y0 = @round(qq.bounds[1]);
            const x1 = @round(qq.bounds[0] + qq.bounds[2]);
            const y1 = @round(qq.bounds[1] + qq.bounds[3]);
            qq.bounds = .{ x0, y0, x1 - x0, y1 - y0 };
        }
        try self.prims.append(self.allocator, .{ .quad = qq });
    }

    pub fn append_polyline(self: *RenderBuilder, seg: primitives.Polyline) !void {
        try self.prims.append(self.allocator, .{ .polyline = seg });
    }

    pub fn append_line(self: *RenderBuilder, seg: primitives.LineSegment) !void {
        try self.prims.append(self.allocator, .{ .line_segment = seg });
    }

    pub fn append_ring(self: *RenderBuilder, ring: primitives.RingChart) !void {
        try self.prims.append(self.allocator, .{ .ring_chart = ring });
    }

    pub fn append_frame(self: *RenderBuilder, f: primitives.Frame) !void {
        try self.prims.append(self.allocator, .{ .frame = f });
    }

    pub fn clear_frame(self: *RenderBuilder) void {
        self.prims.clearRetainingCapacity();
        self.sprites.clearRetainingCapacity();
        self.color_sprites.clearRetainingCapacity();
    }
};
