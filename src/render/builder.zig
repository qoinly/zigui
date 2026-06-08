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
    text_system: *text_system.TextSystem,
    icon_system: ?*icon_system.IconSystem = null,
    app_icon_resolver: ?*app_icon.AppIconResolver = null,
    allocator: Allocator,
    scale_factor: f32,

    pub fn append_quad(self: *RenderBuilder, q: primitives.Quad) !void {
        try self.prims.append(self.allocator, .{ .quad = q });
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

    pub fn clear_frame(self: *RenderBuilder) void {
        self.prims.clearRetainingCapacity();
        self.sprites.clearRetainingCapacity();
        self.color_sprites.clearRetainingCapacity();
    }
};
