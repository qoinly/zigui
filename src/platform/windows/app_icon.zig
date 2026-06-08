// Windows running-app icon source. rasterize returns null (no platform lookup),
// so the cross-platform AppIconResolver stays inert here but still compiles.

const std = @import("std");
const aicon = @import("../../app_icon.zig");
const ts = @import("../../text_system.zig");

pub const WinAppIcons = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) WinAppIcons {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *WinAppIcons) void {
        _ = self;
    }

    pub fn platform_app_icons(self: *WinAppIcons) aicon.PlatformAppIcons {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = aicon.PlatformAppIcons.VTable{ .rasterize = rasterize_impl };

    fn rasterize_impl(ptr: *anyopaque, params: aicon.AppIconParams) ?ts.GlyphBitmap {
        _ = ptr;
        _ = params;
        return null;
    }
};
