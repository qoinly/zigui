// The UIKit surface vocabulary, reached through the shared Objective-C runtime
// (../macos/objc.zig - iOS and macOS share it). IOSWindow is the per-window state
// the renderer's backend accessors read: the iOS analogue of the AndroidWindow
// slab the NativeActivity backend keeps. The UIWindow + view are built by the app
// delegate (app.zig), not handed over by the framework, so this records both.

const std = @import("std");
const objc = @import("../macos/objc.zig");

pub const Id = objc.Id;
pub const CGRect = objc.NSRect;
pub const CGSize = objc.NSSize;
pub const CGPoint = objc.NSPoint;

pub const MAX_WINDOWS: u32 = 1; // one fullscreen UIWindow per app

pub const IOSWindow = struct {
    in_use: bool = false,
    window: ?Id = null, // UIWindow; the strong reference that keeps the tree alive
    view: ?Id = null, // the surface UIView whose layer the renderer draws into
    layer: ?Id = null, // CAMetalLayer, set once the metal view lands
    width_pt: i32 = 0,
    height_pt: i32 = 0,
    scale: i32 = 1,
    renderer_owned: bool = false,
    surface_ctx: ?*anyopaque = null,

    // Refresh the cached point extent from the live view. UIView bounds are
    // already in points (the layer's drawableSize carries the pixel scale), so
    // unlike Android there is no pixel-to-point division here.
    pub fn sync_extent(self: *IOSWindow) void {
        const v = self.view orelse return;
        std.debug.assert(self.scale >= 1);
        const b = objc.msg_send(CGRect, v, "bounds", .{});
        self.width_pt = @max(@as(i32, @intFromFloat(b.size.width)), 1);
        self.height_pt = @max(@as(i32, @intFromFloat(b.size.height)), 1);
    }
};
