// iOS has no cross-process app-icon lookup (a desktop window-switcher concept),
// so this resolver is a no-op: rasterize returns null and the caller falls back.

const std = @import("std");
const app_icon = @import("../../app_icon.zig");
const text_system = @import("../../text_system.zig");

const Allocator = std.mem.Allocator;
const AppIconParams = app_icon.AppIconParams;
const PlatformAppIcons = app_icon.PlatformAppIcons;
const GlyphBitmap = text_system.GlyphBitmap;

pub const IOSAppIcons = struct {
    allocator: Allocator,

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn platform_app_icons(self: *Self) PlatformAppIcons {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = PlatformAppIcons.VTable{ .rasterize = rasterize_impl };

    fn rasterize_impl(ptr: *anyopaque, params: AppIconParams) ?GlyphBitmap {
        _ = ptr;
        _ = params;
        return null;
    }
};
