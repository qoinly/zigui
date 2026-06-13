const std = @import("std");

// Hand-declared NDK binding, the house pattern (see src/platform/linux/xcb.zig):
// translate-c chokes on bionic's nullability attributes, and the Linux backend
// never used @cImport either. NativeActivity calls the exported
// ANativeActivity_onCreate; we set the lifecycle callbacks and fill the window
// with a solid colour on the window-created callback.

const ANativeWindow = opaque {};

const ARect = extern struct { left: i32, top: i32, right: i32, bottom: i32 };

const ANativeWindow_Buffer = extern struct {
    width: i32,
    height: i32,
    stride: i32,
    format: i32,
    bits: ?*anyopaque,
    reserved: [6]u32,
};

// android/native_window.h: RGBA_8888 = 1, RGBX_8888 = 2, RGB_565 = 4.
const WINDOW_FORMAT_RGBX_8888: i32 = 2;

const ActivityCallback = ?*const fn (*ANativeActivity) callconv(.c) void;
const WindowCallback = ?*const fn (*ANativeActivity, *ANativeWindow) callconv(.c) void;

// Layout mirrors android/native_activity.h ANativeActivityCallbacks exactly;
// the loader fills it, we overwrite the slots we care about.
const ANativeActivityCallbacks = extern struct {
    onStart: ActivityCallback = null,
    onResume: ActivityCallback = null,
    onSaveInstanceState: ?*const fn (*ANativeActivity, *usize) callconv(.c) ?*anyopaque = null,
    onPause: ActivityCallback = null,
    onStop: ActivityCallback = null,
    onDestroy: ActivityCallback = null,
    onWindowFocusChanged: ?*const fn (*ANativeActivity, c_int) callconv(.c) void = null,
    onNativeWindowCreated: WindowCallback = null,
    onNativeWindowResized: WindowCallback = null,
    onNativeWindowRedrawNeeded: WindowCallback = null,
    onNativeWindowDestroyed: WindowCallback = null,
    onInputQueueCreated: ?*const fn (*ANativeActivity, *anyopaque) callconv(.c) void = null,
    onInputQueueDestroyed: ?*const fn (*ANativeActivity, *anyopaque) callconv(.c) void = null,
    onContentRectChanged: ?*const fn (*ANativeActivity, *const ARect) callconv(.c) void = null,
    onConfigurationChanged: ActivityCallback = null,
    onLowMemory: ActivityCallback = null,
};

const ANativeActivity = extern struct {
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

extern fn ANativeWindow_setBuffersGeometry(*ANativeWindow, i32, i32, i32) c_int;
extern fn ANativeWindow_lock(*ANativeWindow, *ANativeWindow_Buffer, ?*ARect) c_int;
extern fn ANativeWindow_unlockAndPost(*ANativeWindow) c_int;

export fn ANativeActivity_onCreate(
    activity: *ANativeActivity,
    saved_state: ?*anyopaque,
    saved_state_size: usize,
) void {
    _ = saved_state;
    _ = saved_state_size;
    activity.callbacks.onNativeWindowCreated = on_window_created;
}

fn on_window_created(activity: *ANativeActivity, window: *ANativeWindow) callconv(.c) void {
    _ = activity;
    fill_window(window);
}

fn fill_window(window: *ANativeWindow) void {
    _ = ANativeWindow_setBuffersGeometry(window, 0, 0, WINDOW_FORMAT_RGBX_8888);
    var buffer: ANativeWindow_Buffer = undefined;
    if (ANativeWindow_lock(window, &buffer, null) != 0) return;
    const bits = buffer.bits orelse {
        _ = ANativeWindow_unlockAndPost(window);
        return;
    };
    const pixels: [*]u32 = @ptrCast(@alignCast(bits));
    // The dimensions cross the FFI boundary as i32; a negative value would wrap
    // to a huge usize and the fill would run past the locked buffer.
    std.debug.assert(buffer.width >= 0);
    std.debug.assert(buffer.height >= 0);
    std.debug.assert(buffer.stride >= 0);
    const stride: usize = @intCast(buffer.stride);
    const width: usize = @intCast(buffer.width);
    const height: usize = @intCast(buffer.height);
    std.debug.assert(stride >= width);
    // RGBX_8888 is little-endian in memory (R, G, B, X), so the u32 reads
    // 0xXXBBGGRR; zigui blue 0x3B82F6 -> 0xFFF6823B.
    const color: u32 = 0xFFF6823B;
    var y: usize = 0;
    while (y < height) : (y += 1) {
        var x: usize = 0;
        while (x < width) : (x += 1) {
            pixels[y * stride + x] = color;
        }
    }
    _ = ANativeWindow_unlockAndPost(window);
}
