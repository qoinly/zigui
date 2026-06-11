// Atlas surface for the text/icon facades, the windows/window.zig precedent:
// the types exist so root and the test build compile on Linux. No texture
// backs this file - get/get_or_insert return null so callers skip the sprite.

const std = @import("std");
const ts = @import("../../text_system.zig");
const geometry = @import("../../geometry.zig");

const Allocator = std.mem.Allocator;
const GlyphBitmap = ts.GlyphBitmap;
const AtlasTile = ts.AtlasTile;

pub fn LinuxAtlas(comptime bpp: u32) type {
    return struct {
        allocator: Allocator,

        pub const INITIAL_SIZE: u32 = 1024;
        pub const BYTES_PER_PIXEL: u32 = bpp;

        const Self = @This();

        pub fn init(allocator: Allocator, device: *anyopaque) Self {
            std.debug.assert(@intFromPtr(device) != 0);
            comptime std.debug.assert(bpp == 1 or bpp == 4);
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            _ = self;
        }

        pub fn get(self: *Self, key: u64) ?AtlasTile {
            _ = self;
            _ = key;
            return null;
        }

        pub fn get_or_insert(
            self: *Self,
            key: u64,
            bitmap: ?GlyphBitmap,
            raster_origin: geometry.Point(i32),
        ) ?AtlasTile {
            _ = self;
            _ = key;
            _ = bitmap;
            _ = raster_origin;
            return null;
        }

        pub fn get_texture(self: *Self) ?*anyopaque {
            _ = self;
            return null;
        }

        // Non-zero so the sprite UV math it feeds stays a finite division.
        pub fn get_texture_size(self: *Self) u32 {
            _ = self;
            return INITIAL_SIZE;
        }
    };
}

pub const LinuxMonoAtlas = LinuxAtlas(1);
pub const LinuxColorAtlas = LinuxAtlas(4);
