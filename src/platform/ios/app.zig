// The iOS app entry and lifecycle. Unlike the desktop backend there is no run
// loop to call: UIApplicationMain owns it and never returns, so run_main blocks
// like the desktop run. The surface is not handed over by the framework either -
// the delegate's didFinishLaunching builds the UIWindow and a CAMetalLayer-backed
// view, records them in g_window, and notifies the registered surface delegate.
//
// The delegate and the metal view are both built at runtime through the
// Objective-C runtime (the macOS custom-shell precedent), so the backend ships no
// .m and no bridge VM.

const std = @import("std");
const objc = @import("../macos/objc.zig");
const native = @import("native.zig");
const custom_shell = @import("custom_shell.zig");

const Id = objc.Id;

// UIViewAutoresizing bits: the metal layer tracks the view through rotation.
const autoresize_flexible_width: objc.NSUInteger = 1 << 1;
const autoresize_flexible_height: objc.NSUInteger = 1 << 4;

pub const ActivationPolicy = enum { regular, accessory, prohibited };
pub const Error = error{InitFailed};

// One fullscreen surface per app; app_runtime.zig and the renderer both read this
// storage, so it lives here (the shell holds a pointer to it).
var g_window: native.IOSWindow = .{};

// The high-level App registers this to receive surface lifecycle events; the
// delegate callbacks below fan into it.
pub const SurfaceDelegate = struct {
    ctx: *anyopaque,
    on_ready: *const fn (ctx: *anyopaque, window: *native.IOSWindow) void,
    on_lost: *const fn (ctx: *anyopaque) void,
};

var g_delegate: ?SurfaceDelegate = null;

pub fn set_surface_delegate(delegate: SurfaceDelegate) void {
    g_delegate = delegate;
}

// The process-level platform app. iOS has no dock/activation, app menu, or
// last-window quit, and UIApplicationMain owns the run loop, so every method is a
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

extern "c" fn UIApplicationMain(
    argc: c_int,
    argv: [*][*:0]u8,
    principal_class_name: ?Id,
    delegate_class_name: ?Id,
) c_int;

// Hands control to UIKit, naming the runtime-built delegate class. UIApplication
// instantiates it and drives the lifecycle; this never returns.
pub fn run_main() void {
    ensure_delegate_class();
    std.debug.assert(g_delegate != null); // run() registers it before this call
    std.debug.assert(g_delegate_class != null);
    const name = ns_string("ZiguiAppDelegate");
    // UIApplicationMain owns the loop and never returns, so this frame (and its
    // argv) stays live for the app's life. UIKit ignores argv beyond argv[0].
    var argv = [_][*:0]u8{@constCast(@as([*:0]const u8, "zigui"))};
    _ = UIApplicationMain(1, &argv, null, name);
}

var g_delegate_class: ?objc.Class = null;

fn ensure_delegate_class() void {
    if (g_delegate_class != null) return;
    const NSObject = objc.get_class("NSObject") orelse return;
    const cls = objc.objc_allocateClassPair(NSObject, "ZiguiAppDelegate", 0) orelse return;
    _ = objc.class_addMethod(
        cls,
        objc.sel("application:didFinishLaunchingWithOptions:"),
        @ptrCast(&did_finish_launching),
        "B@:@@",
    );
    objc.objc_registerClassPair(cls);
    g_delegate_class = cls;
}

// UIKit calls this once on launch: build the window and view, then notify the
// registered surface delegate that the surface is ready.
fn did_finish_launching(_: Id, _: objc.Sel, _: Id, _: Id) callconv(.c) bool {
    build_surface();
    return true;
}

fn build_surface() void {
    std.debug.assert(!g_window.in_use); // launch fires once
    if (!make_window()) return;
    std.debug.assert(g_window.window != null);
    std.debug.assert(g_window.layer != null);
    g_window.in_use = true;
    g_window.sync_extent();
    std.debug.assert(g_window.width_pt >= 1);
    custom_shell.set_window(&g_window);
    if (g_delegate) |d| d.on_ready(d.ctx, &g_window);
}

fn make_window() bool {
    const UIScreen = objc.get_class("UIScreen") orelse return false;
    const screen = objc.msg_send(Id, UIScreen, "mainScreen", .{});
    const bounds = objc.msg_send(native.CGRect, screen, "bounds", .{});
    const scale = objc.msg_send(objc.CGFloat, screen, "scale", .{});
    std.debug.assert(scale >= 1);

    const vc = make_root_controller(bounds, scale) orelse return false;
    const UIWindow = objc.get_class("UIWindow") orelse return false;
    const window = objc.msg_send(Id, objc.alloc(UIWindow), "initWithFrame:", .{bounds});
    objc.msg_send(void, window, "setRootViewController:", .{vc});
    objc.msg_send(void, window, "makeKeyAndVisible", .{});

    g_window.window = window;
    g_window.scale = @intFromFloat(scale);
    return true;
}

// The root controller's view is the CAMetalLayer-backed surface the renderer
// draws into; record both the view and its layer for the shell to read.
fn make_root_controller(bounds: native.CGRect, scale: objc.CGFloat) ?Id {
    const UIViewController = objc.get_class("UIViewController") orelse return null;
    const vc = objc.msg_send(Id, objc.alloc(UIViewController), "init", .{});
    std.debug.assert(@intFromPtr(vc) != 0);
    const view = make_metal_view(bounds, scale) orelse return null;
    objc.msg_send(void, vc, "setView:", .{view});
    g_window.view = view;
    g_window.layer = objc.msg_send(Id, view, "layer", .{});
    std.debug.assert(g_window.layer != null);
    return vc;
}

fn make_metal_view(bounds: native.CGRect, scale: objc.CGFloat) ?Id {
    const cls = ensure_metal_view_class() orelse return null;
    const view = objc.msg_send(Id, objc.alloc(cls), "initWithFrame:", .{bounds});
    std.debug.assert(@intFromPtr(view) != 0);
    objc.msg_send(void, view, "setContentScaleFactor:", .{scale});
    const mask = autoresize_flexible_width | autoresize_flexible_height;
    objc.msg_send(void, view, "setAutoresizingMask:", .{mask});
    return view;
}

var g_metal_view_class: ?objc.Class = null;

// A UIView subclass whose +layerClass is CAMetalLayer, so the view's own backing
// layer is the drawable - it resizes with the view, no manual sublayer to track.
fn ensure_metal_view_class() ?objc.Class {
    if (g_metal_view_class) |c| return c;
    const UIView = objc.get_class("UIView") orelse return null;
    const cls = objc.objc_allocateClassPair(UIView, "ZiguiMetalView", 0) orelse return null;
    const meta = objc.object_getClass(@ptrCast(cls)) orelse return null;
    _ = objc.class_addMethod(meta, objc.sel("layerClass"), @ptrCast(&metal_layer_class), "#@:");
    objc.objc_registerClassPair(cls);
    g_metal_view_class = cls;
    return cls;
}

fn metal_layer_class(_: objc.Class, _: objc.Sel) callconv(.c) objc.Class {
    // CAMetalLayer is always present (QuartzCore is linked); the lookup cannot fail.
    return objc.get_class("CAMetalLayer").?;
}

fn ns_string(s: [:0]const u8) Id {
    const NSString = objc.get_class("NSString").?;
    return objc.msg_send(Id, NSString, "stringWithUTF8String:", .{@as([*:0]const u8, s.ptr)});
}
