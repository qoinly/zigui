// The NDK surface vocabulary, hand-declared (the house pattern; @cImport
// chokes on bionic nullability attributes). ANativeWindow is the surface the
// framework hands a NativeActivity; AndroidWindow is the per-window state the
// renderer's backend accessors read - the Android analogue of the wayland/x11
// ShellWindow slab entry.

const std = @import("std");

pub const ANativeWindow = opaque {};

pub extern fn ANativeWindow_getWidth(*ANativeWindow) c_int;
pub extern fn ANativeWindow_getHeight(*ANativeWindow) c_int;

// The framework calls the exported ANativeActivity_onCreate, then drives the
// activity through these callbacks; we overwrite the slots we handle. Layout
// mirrors android/native_activity.h exactly - the loader fills it.
pub const ARect = extern struct { left: i32, top: i32, right: i32, bottom: i32 };

const ActivityFn = ?*const fn (*ANativeActivity) callconv(.c) void;
const WindowFn = ?*const fn (*ANativeActivity, *ANativeWindow) callconv(.c) void;

pub const ANativeActivityCallbacks = extern struct {
    onStart: ActivityFn = null,
    onResume: ActivityFn = null,
    onSaveInstanceState: ?*const fn (*ANativeActivity, *usize) callconv(.c) ?*anyopaque = null,
    onPause: ActivityFn = null,
    onStop: ActivityFn = null,
    onDestroy: ActivityFn = null,
    onWindowFocusChanged: ?*const fn (*ANativeActivity, c_int) callconv(.c) void = null,
    onNativeWindowCreated: WindowFn = null,
    onNativeWindowResized: WindowFn = null,
    onNativeWindowRedrawNeeded: WindowFn = null,
    onNativeWindowDestroyed: WindowFn = null,
    onInputQueueCreated: ?*const fn (*ANativeActivity, *anyopaque) callconv(.c) void = null,
    onInputQueueDestroyed: ?*const fn (*ANativeActivity, *anyopaque) callconv(.c) void = null,
    onContentRectChanged: ?*const fn (*ANativeActivity, *const ARect) callconv(.c) void = null,
    onConfigurationChanged: ActivityFn = null,
    onLowMemory: ActivityFn = null,
};

pub const ANativeActivity = extern struct {
    callbacks: *ANativeActivityCallbacks,
    vm: ?*anyopaque,
    env: ?*anyopaque,
    clazz: ?*anyopaque,
    internal_data_path: ?[*:0]const u8,
    external_data_path: ?[*:0]const u8,
    sdk_version: i32,
    instance: ?*anyopaque,
    asset_manager: ?*anyopaque,
    obb_path: ?[*:0]const u8,
};

pub const MAX_WINDOWS: u32 = 1; // one fullscreen surface per Activity

pub const AndroidWindow = struct {
    in_use: bool = false,
    native: ?*ANativeWindow = null,
    width_pt: i32 = 0,
    height_pt: i32 = 0,
    scale: i32 = 1,
    renderer_owned: bool = false,
    surface_ctx: ?*anyopaque = null,

    // Refresh the cached point extent from the live surface. Android has no
    // buffer-scale negotiation - the surface simply IS its pixel size - so
    // points equal pixels until the density scale lands with input.
    pub fn sync_extent(self: *AndroidWindow) void {
        const native = self.native orelse return;
        std.debug.assert(self.scale >= 1);
        const w = ANativeWindow_getWidth(native);
        const h = ANativeWindow_getHeight(native);
        self.width_pt = @max(@divTrunc(w, self.scale), 1);
        self.height_pt = @max(@divTrunc(h, self.scale), 1);
    }
};
