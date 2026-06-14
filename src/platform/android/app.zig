// The Android app entry and lifecycle. There is no main() that owns the loop:
// the framework calls the exported ANativeActivity_onCreate, which runs the
// app's own main() (the @import("root").main bridge) so the SAME example main
// drives desktop and Android. main() calls App.init/run, which defer the real
// setup - the surface arrives asynchronously via onNativeWindowCreated, after
// onCreate returns. So App.init/run_forever here are parity no-ops (the
// process-level app owns nothing), and the high-level Android App (app_runtime.zig)
// registers a surface delegate to receive the window create/destroy events.

const std = @import("std");
const native = @import("native.zig");
const android_shell = @import("custom_shell.zig");
const input = @import("input.zig");
const jni = @import("jni.zig");

pub const ActivationPolicy = enum { regular, accessory, prohibited };
pub const Error = error{InitFailed};

// One fullscreen surface per Activity; app_runtime.zig and the renderer both
// read this storage, so it lives here (the shell holds a pointer to it).
var g_window: native.AndroidWindow = .{};

// Kept so the insets can be re-read from JNI (it needs the activity's env+object)
// when the layout changes.
var g_activity: ?*native.ANativeActivity = null;

// The high-level App registers this to receive surface lifecycle events; the
// framework callbacks below fan into it.
pub const SurfaceDelegate = struct {
    ctx: *anyopaque,
    on_ready: *const fn (ctx: *anyopaque, window: *native.AndroidWindow) void,
    on_lost: *const fn (ctx: *anyopaque) void,
};

var g_delegate: ?SurfaceDelegate = null;

pub fn set_surface_delegate(delegate: SurfaceDelegate) void {
    g_delegate = delegate;
}

// The process-level platform app. Android has no dock/activation, app menu, or
// last-window quit, and the framework owns the run loop, so every method is a
// parity no-op - the high-level App in app_runtime.zig holds the real state.
pub const App = struct {
    pub fn init() Error!App {
        return .{};
    }

    pub fn deinit(self: App) void {
        _ = self;
    }

    pub fn set_activation_policy(self: App, policy: ActivationPolicy) void {
        _ = self;
        _ = policy;
    }

    pub fn install_edit_menu(self: App) void {
        _ = self;
    }

    pub fn quit_on_last_window_closed(self: App) void {
        _ = self;
    }

    pub fn run_forever(self: App) void {
        _ = self;
    }

    pub fn quit(self: App) void {
        _ = self;
    }
};

pub export fn ANativeActivity_onCreate(
    activity: *native.ANativeActivity,
    saved_state: ?*anyopaque,
    saved_state_size: usize,
) void {
    _ = saved_state;
    _ = saved_state_size;
    activity.callbacks.onNativeWindowCreated = on_window_created;
    activity.callbacks.onNativeWindowDestroyed = on_window_destroyed;
    activity.callbacks.onInputQueueCreated = on_input_queue_created;
    activity.callbacks.onInputQueueDestroyed = on_input_queue_destroyed;
    activity.callbacks.onContentRectChanged = on_content_rect_changed;
    g_activity = activity;
    // Run the app's main() now: it calls App.init/run, which register the
    // surface delegate and return at once. The window callbacks above then fire.
    run_root_main();
}

// Bridge to the app's main(): on the example build root is the example main.zig
// (has main, builds the kit App); on a standalone zigui lib build root is
// zigui's root.zig (no main, the guard skips it). A switch on the return type
// (not a runtime if) keeps the dead branch out of analysis when main is void.
fn run_root_main() void {
    const root = @import("root");
    // comptime so a no-main root (the standalone zigui lib build) prunes the
    // whole block - a runtime guard would still analyze the root.main reference.
    if (comptime @hasDecl(root, "main")) {
        const Ret = @typeInfo(@TypeOf(root.main)).@"fn".return_type.?;
        switch (@typeInfo(Ret)) {
            .error_union => root.main() catch {
                _ = __android_log_write(ANDROID_LOG_ERROR, "zigui", "app main returned an error");
            },
            else => root.main(),
        }
    }
}

const Activity = native.ANativeActivity;
const Window = native.ANativeWindow;

fn on_window_created(activity: *Activity, window: *Window) callconv(.c) void {
    _ = activity;
    std.debug.assert(@intFromPtr(window) != 0); // the framework owns this surface ptr
    // A resume can re-create the surface without a destroy in between; tear an
    // old renderer down first so it never leaks or samples a stale window.
    notify_lost();
    g_window = .{ .in_use = true, .native = window };
    g_window.sync_extent();
    android_shell.set_window(&g_window);
    refresh_insets(); // best-effort; onContentRectChanged refreshes once laid out
    if (g_delegate) |d| d.on_ready(d.ctx, &g_window);
}

fn on_window_destroyed(activity: *Activity, window: *Window) callconv(.c) void {
    _ = activity;
    _ = window;
    notify_lost();
    android_shell.clear_window();
    g_window = .{};
}

fn notify_lost() void {
    if (g_delegate) |d| d.on_lost(d.ctx);
}

// The content rect changes on rotation / bar show-hide; re-read the insets then.
fn on_content_rect_changed(activity: *Activity, rect: *const native.ARect) callconv(.c) void {
    _ = activity;
    _ = rect;
    refresh_insets();
}

// Pull the system-bar insets from JNI into the shell. A null read (view not laid
// out, or pre-API-30) leaves the last-known insets, so an early call never snaps
// content to zero.
fn refresh_insets() void {
    const a = g_activity orelse return;
    if (jni.safe_insets(a.env, a.clazz)) |insets| android_shell.set_insets(insets);
}

// The framework passes the AInputQueue erased as *anyopaque in this slot; the
// input layer attaches it to the thread looper and drains touch from there.
fn on_input_queue_created(activity: *Activity, queue: *anyopaque) callconv(.c) void {
    _ = activity;
    std.debug.assert(@intFromPtr(queue) != 0); // the framework owns this queue ptr
    input.on_queue_created(@ptrCast(queue));
}

fn on_input_queue_destroyed(activity: *Activity, queue: *anyopaque) callconv(.c) void {
    _ = activity;
    std.debug.assert(@intFromPtr(queue) != 0);
    input.on_queue_destroyed(@ptrCast(queue));
}

// Minimal NDK logging (liblog) so a failed bring-up shows in logcat instead of a
// silent black screen.
const ANDROID_LOG_ERROR: c_int = 6;
extern fn __android_log_write(prio: c_int, tag: [*:0]const u8, text: [*:0]const u8) c_int;
