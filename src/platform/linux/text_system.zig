// Text-system surface for the text facade, the windows/window.zig precedent:
// the types exist so root and the test build compile on Linux. Nothing shapes
// or rasterizes through this file: font_id is always 0, layouts are empty, and
// rasterize returns null so callers take their skip paths.

const std = @import("std");
const ts = @import("../../text_system.zig");
const geometry = @import("../../geometry.zig");

const Allocator = std.mem.Allocator;

pub const LinuxTextSystem = struct {
    allocator: Allocator,

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn platform_text_system(self: *Self) ts.PlatformTextSystem {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = ts.PlatformTextSystem.VTable{
        .font_id = font_id_impl,
        .font_metrics = font_metrics_impl,
        .layout_line = layout_line_impl,
        .rasterize_glyph = rasterize_glyph_impl,
        .glyph_raster_bounds = glyph_raster_bounds_impl,
    };

    fn font_id_impl(ptr: *anyopaque, family: []const u8, weight: ts.FontWeight) ts.FontId {
        _ = ptr;
        _ = family;
        _ = weight;
        return 0;
    }

    fn font_metrics_impl(ptr: *anyopaque, font_id: ts.FontId, font_size: f32) ts.FontMetrics {
        _ = ptr;
        std.debug.assert(font_id == 0);
        std.debug.assert(font_size >= 0);
        // units_per_em 1 keeps any em-scale division finite.
        return .{
            .units_per_em = 1,
            .ascent = 0,
            .descent = 0,
            .line_gap = 0,
            .cap_height = 0,
            .x_height = 0,
        };
    }

    fn layout_line_impl(
        ptr: *anyopaque,
        text: []const u8,
        font_size: f32,
        font_id: ts.FontId,
    ) ts.LineLayout {
        _ = ptr;
        _ = text;
        std.debug.assert(font_size >= 0);
        std.debug.assert(font_id == 0);
        return .{
            .width = 0,
            .ascent = 0,
            .descent = 0,
            .ink_ascent = 0,
            .ink_descent = 0,
            .runs = &.{},
        };
    }

    fn rasterize_glyph_impl(ptr: *anyopaque, params: ts.RenderGlyphParams) ?ts.GlyphBitmap {
        _ = ptr;
        _ = params;
        return null;
    }

    fn glyph_raster_bounds_impl(
        ptr: *anyopaque,
        params: ts.RenderGlyphParams,
    ) geometry.Bounds(i32) {
        _ = ptr;
        std.debug.assert(params.font_size >= 0);
        std.debug.assert(params.scale_factor > 0);
        return geometry.Bounds(i32).init(0, 0, 0, 0);
    }
};
