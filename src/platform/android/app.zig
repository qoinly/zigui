// The Android app entry. There is no main() that owns the loop: the framework
// calls the exported ANativeActivity_onCreate, the surface arrives
// asynchronously via onNativeWindowCreated, and the OS runs the looper. So
// App.init/run_forever are parity stubs (nothing to own here), and the real
// work hangs off the window callbacks - build the shared Vulkan renderer over
// the ANativeWindow and draw.

const std = @import("std");
const native = @import("native.zig");
const renderer = @import("../../renderer.zig");
const primitives = @import("../../primitives.zig");

pub const ActivationPolicy = enum { regular, accessory, prohibited };
pub const Error = error{InitFailed};

// One fullscreen surface per Activity; the renderer reads this by pointer.
var g_window: native.AndroidWindow = .{};
var g_renderer: ?renderer.Renderer = null;

pub const App = struct {
    pub fn init() Error!App {
        return .{};
    }

    pub fn deinit(self: App) void {
        _ = self;
    }

    // No dock/activation, app menu, or last-window quit on Android; kept for
    // API parity so shared code compiles.
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

    // The framework owns the run loop; the lifecycle callbacks below drive
    // rendering, so there is nothing to block on here.
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
}

const Activity = native.ANativeActivity;
const Window = native.ANativeWindow;

fn on_window_created(activity: *Activity, window: *Window) callconv(.c) void {
    _ = activity;
    // A resume can re-create the surface without a destroy in between; tear the
    // old renderer down first so it never leaks or samples a stale window.
    teardown();
    g_window = .{ .in_use = true, .native = window };
    g_window.sync_extent();
    g_renderer = renderer.Renderer.init(@ptrCast(&g_window)) catch {
        g_window = .{};
        return;
    };
    render_once();
}

fn on_window_destroyed(activity: *Activity, window: *Window) callconv(.c) void {
    _ = activity;
    _ = window;
    teardown();
}

fn teardown() void {
    if (g_renderer) |*r| r.deinit();
    g_renderer = null;
    g_window = .{};
}

fn render_once() void {
    const r = if (g_renderer) |*rp| rp else return;
    std.debug.assert(g_window.native != null);
    const clear = renderer.ClearColor.init(0.04, 0.04, 0.04, 1.0);
    var quad = primitives.Quad.init(120, 240, 480, 480);
    _ = quad.set_background_hex(0x3B82F6).set_corner_radius(48);
    const prims = [_]primitives.Primitive{.{ .quad = quad }};
    r.draw_frame(clear, &prims, &.{}, null, &.{}, null);
}
