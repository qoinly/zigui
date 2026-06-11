// Icon surface for the icon facade, the windows/window.zig precedent: the
// types exist so root and the test build compile on Linux. name_for returns
// "" for every Icon, which routes the engine to the bundled Lucide set.

const std = @import("std");
const icon = @import("../../icon.zig");
const ts = @import("../../text_system.zig");

const Allocator = std.mem.Allocator;

pub const LinuxIconSystem = struct {
    allocator: Allocator,

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn platform_icon_system(self: *Self) icon.PlatformIconSystem {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = icon.PlatformIconSystem.VTable{
        .rasterize = rasterize_impl,
    };

    fn rasterize_impl(ptr: *anyopaque, params: icon.IconParams) ?ts.GlyphBitmap {
        _ = ptr;
        std.debug.assert(params.point_size > 0);
        std.debug.assert(params.scale_factor > 0);
        return null;
    }

    pub fn name_for(self: *Self, ic: icon.Icon) []const u8 {
        _ = self;
        _ = ic;
        return "";
    }
};
