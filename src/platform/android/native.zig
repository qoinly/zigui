// The NDK surface vocabulary, hand-declared (the house pattern; @cImport
// chokes on bionic nullability attributes). ANativeWindow is the surface the
// framework hands a NativeActivity; AndroidWindow is the per-window state the
// renderer's backend accessors read - the Android analogue of the wayland/x11
// ShellWindow slab entry.

const std = @import("std");

pub const ANativeWindow = opaque {};

pub extern fn ANativeWindow_getWidth(*ANativeWindow) c_int;
pub extern fn ANativeWindow_getHeight(*ANativeWindow) c_int;

// The frame clock (android/choreographer.h, API 24+): a posted callback fires
// once on the next vsync, so re-posting from inside it is the run loop. Lives on
// the thread's looper, which the NativeActivity main thread already has.
pub const AChoreographer = opaque {};
pub const FrameCallback = *const fn (frame_time_nanos: i64, data: ?*anyopaque) callconv(.c) void;

pub extern fn AChoreographer_getInstance() ?*AChoreographer;
pub extern fn AChoreographer_postFrameCallback(*AChoreographer, FrameCallback, ?*anyopaque) void;

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

// Input (android/input.h) plus the thread looper (android/looper.h). The
// framework hands an AInputQueue via onInputQueueCreated; attaching it to the
// main thread's ALooper with a callback drains touch/key events as they arrive,
// on the same thread the paint loop runs on (no cross-thread state).
pub const AInputQueue = opaque {};
pub const AInputEvent = opaque {};
pub const ALooper = opaque {};

pub const LooperCallback =
    *const fn (fd: c_int, events: c_int, data: ?*anyopaque) callconv(.c) c_int;

pub extern fn ALooper_forThread() ?*ALooper;
pub extern fn AInputQueue_attachLooper(
    *AInputQueue,
    *ALooper,
    ident: c_int,
    callback: LooperCallback,
    data: ?*anyopaque,
) void;
pub extern fn AInputQueue_detachLooper(*AInputQueue) void;
pub extern fn AInputQueue_getEvent(*AInputQueue, event: **AInputEvent) i32;
pub extern fn AInputQueue_preDispatchEvent(*AInputQueue, *AInputEvent) i32;
pub extern fn AInputQueue_finishEvent(*AInputQueue, *AInputEvent, handled: c_int) void;

pub extern fn AInputEvent_getType(*const AInputEvent) i32;
pub extern fn AMotionEvent_getAction(*const AInputEvent) i32;
pub extern fn AMotionEvent_getX(*const AInputEvent, pointer_index: usize) f32;
pub extern fn AMotionEvent_getY(*const AInputEvent, pointer_index: usize) f32;
pub extern fn AKeyEvent_getAction(*const AInputEvent) i32;
pub extern fn AKeyEvent_getKeyCode(*const AInputEvent) i32;

pub const AINPUT_EVENT_TYPE_KEY: i32 = 1;
pub const AINPUT_EVENT_TYPE_MOTION: i32 = 2;
// The action is packed with the pointer index in the high bits; mask to the kind.
pub const AMOTION_EVENT_ACTION_MASK: i32 = 0xff;
pub const AMOTION_EVENT_ACTION_DOWN: i32 = 0;
pub const AMOTION_EVENT_ACTION_UP: i32 = 1;
pub const AMOTION_EVENT_ACTION_MOVE: i32 = 2;
pub const AMOTION_EVENT_ACTION_CANCEL: i32 = 3;
pub const AKEY_EVENT_ACTION_DOWN: i32 = 0;
pub const AKEY_EVENT_ACTION_UP: i32 = 1;
pub const AKEYCODE_BACK: i32 = 4;

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
