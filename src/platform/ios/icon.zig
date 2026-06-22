// iOS has no native icon set zigui maps to: the kit's bundled icon source
// supplies the glyphs, so this native resolver is a no-op - name_for returns empty
// and rasterize returns null, which the IconSystem treats as "no native glyph" and
// falls back to the bundled set.

const std = @import("std");
const icon_system = @import("../../icon.zig");
const text_system = @import("../../text_system.zig");

const Allocator = std.mem.Allocator;
const Icon = icon_system.Icon;
const IconParams = icon_system.IconParams;
const PlatformIconSystem = icon_system.PlatformIconSystem;
const GlyphBitmap = text_system.GlyphBitmap;

pub const IOSIconSystem = struct {
    allocator: Allocator,

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn platform_icon_system(self: *Self) PlatformIconSystem {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn name_for(self: *Self, ic: Icon) []const u8 {
        _ = self;
        _ = ic;
        return "";
    }

    const vtable = PlatformIconSystem.VTable{ .rasterize = rasterize_impl };

    fn rasterize_impl(ptr: *anyopaque, params: IconParams) ?GlyphBitmap {
        _ = ptr;
        _ = params;
        return null;
    }
};
