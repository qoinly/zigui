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
    _ = objc.class_addMethod(
        cls,
        objc.sel("application:configurationForConnectingSceneSession:options:"),
        @ptrCast(&config_for_scene),
        "@@:@@@",
    );
    objc.objc_registerClassPair(cls);
    g_delegate_class = cls;
}

// UIKit calls this on launch. The window is built when the scene connects (scenes own
// sizing + rotation), so this only acknowledges launch.
fn did_finish_launching(_: Id, _: objc.Sel, _: Id, _: Id) callconv(.c) bool {
    return true;
}

var g_scene_delegate_class: ?objc.Class = null;

// The app delegate hands UIKit this configuration so the connecting scene uses our scene
// delegate (a runtime class). A scene-owned window resizes on rotation, so the surface and
// safe-area insets follow the interface orientation.
fn config_for_scene(_: Id, _: objc.Sel, _: Id, session: Id, _: Id) callconv(.c) Id {
    const Cfg = objc.get_class("UISceneConfiguration").?;
    const role = objc.msg_send(Id, session, "role", .{});
    const sel = "configurationWithName:sessionRole:";
    const cfg = objc.msg_send(Id, Cfg, sel, .{ ns_string("Default Configuration"), role });
    if (ensure_scene_delegate_class()) |scls| {
        objc.msg_send(void, cfg, "setDelegateClass:", .{scls});
    }
    return cfg;
}

fn ensure_scene_delegate_class() ?objc.Class {
    if (g_scene_delegate_class) |c| return c;
    const NSObject = objc.get_class("NSObject") orelse return null;
    const cls = objc.objc_allocateClassPair(NSObject, "ZiguiSceneDelegate", 0) orelse return null;
    const sel = objc.sel("scene:willConnectToSession:options:");
    _ = objc.class_addMethod(cls, sel, @ptrCast(&scene_will_connect), "v@:@@@");
    // UIKit asserts the scene delegate conforms to UISceneDelegate (UIWindowSceneDelegate
    // incorporates it); declare both on the runtime class.
    if (objc.objc_getProtocol("UISceneDelegate")) |p| _ = objc.class_addProtocol(cls, p);
    if (objc.objc_getProtocol("UIWindowSceneDelegate")) |p| _ = objc.class_addProtocol(cls, p);
    objc.objc_registerClassPair(cls);
    g_scene_delegate_class = cls;
    return cls;
}

// UIKit calls this when the window scene attaches: build the window into that scene, then
// notify the registered surface delegate that the surface is ready.
fn scene_will_connect(_: Id, _: objc.Sel, scene: Id, _: Id, _: Id) callconv(.c) void {
    build_surface(scene);
}

fn build_surface(scene: Id) void {
    std.debug.assert(@intFromPtr(scene) != 0); // UIKit hands a live window scene
    std.debug.assert(!g_window.in_use); // the scene connects once
    if (!make_window(scene)) return;
    std.debug.assert(g_window.window != null);
    std.debug.assert(g_window.layer != null);
    g_window.in_use = true;
    g_window.sync_extent();
    std.debug.assert(g_window.width_pt >= 1);
    custom_shell.set_window(&g_window);
    if (g_delegate) |d| d.on_ready(d.ctx, &g_window);
}

fn make_window(scene: Id) bool {
    const UIScreen = objc.get_class("UIScreen") orelse return false;
    const screen = objc.msg_send(Id, UIScreen, "mainScreen", .{});
    const bounds = objc.msg_send(native.CGRect, screen, "bounds", .{});
    const scale = objc.msg_send(objc.CGFloat, screen, "scale", .{});
    std.debug.assert(scale >= 1);

    const vc = make_root_controller(bounds, scale) orelse return false;
    const UIWindow = objc.get_class("UIWindow") orelse return false;
    const window = objc.msg_send(Id, objc.alloc(UIWindow), "initWithWindowScene:", .{scene});
    objc.msg_send(void, window, "setRootViewController:", .{vc});
    objc.msg_send(void, window, "makeKeyAndVisible", .{});

    g_window.window = window;
    g_window.scale = @intFromFloat(scale);
    return true;
}

// The root controller's view is the CAMetalLayer-backed surface the renderer
// draws into; record both the view and its layer for the shell to read.
fn make_root_controller(bounds: native.CGRect, scale: objc.CGFloat) ?Id {
    const cls = ensure_root_vc_class() orelse return null;
    const vc = objc.msg_send(Id, objc.alloc(cls), "init", .{});
    std.debug.assert(@intFromPtr(vc) != 0);
    g_root_vc = vc;
    const view = make_metal_view(bounds, scale) orelse return null;
    objc.msg_send(void, vc, "setView:", .{view});
    g_window.view = view;
    g_window.layer = objc.msg_send(Id, view, "layer", .{});
    std.debug.assert(g_window.layer != null);
    return vc;
}

// Chrome the root controller reflects: the status-bar style and visibility (immersive). The
// napi (display.*) writes the state; the controller's overrides below read it.
var g_status_dark: bool = false;
var g_immersive: bool = false;
var g_orientation: objc.NSUInteger = 26; // UIInterfaceOrientationMaskAllButUpsideDown
var g_root_vc: ?Id = null;
var g_root_vc_class: ?objc.Class = null;

// UIStatusBarStyle: 3 darkContent (dark icons on a light bar), 1 lightContent (light icons).
fn vc_status_style(_: Id, _: objc.Sel) callconv(.c) objc.NSInteger {
    return if (g_status_dark) 3 else 1;
}
fn vc_status_hidden(_: Id, _: objc.Sel) callconv(.c) objc.BOOL {
    return if (g_immersive) objc.YES else objc.NO;
}
fn vc_orientations(_: Id, _: objc.Sel) callconv(.c) objc.NSUInteger {
    return g_orientation;
}

fn ensure_root_vc_class() ?objc.Class {
    if (g_root_vc_class) |c| return c;
    const UIViewController = objc.get_class("UIViewController") orelse return null;
    const name = "ZiguiViewController";
    const cls = objc.objc_allocateClassPair(UIViewController, name, 0) orelse return null;
    add_chrome_method(cls, "preferredStatusBarStyle", @ptrCast(&vc_status_style), "q@:");
    add_chrome_method(cls, "prefersStatusBarHidden", @ptrCast(&vc_status_hidden), "B@:");
    add_chrome_method(cls, "supportedInterfaceOrientations", @ptrCast(&vc_orientations), "Q@:");
    objc.objc_registerClassPair(cls);
    g_root_vc_class = cls;
    return cls;
}

fn add_chrome_method(
    cls: objc.Class,
    name: [:0]const u8,
    imp: *const anyopaque,
    enc: [:0]const u8,
) void {
    _ = objc.class_addMethod(cls, objc.sel(name), imp, enc);
}

pub fn set_status_dark(dark: bool) void {
    g_status_dark = dark;
    status_appearance_update();
}
pub fn set_immersive(on: bool) void {
    g_immersive = on;
    status_appearance_update();
}
// UIKit caches the status-bar appearance; this makes it re-query the overrides above.
fn status_appearance_update() void {
    const vc = g_root_vc orelse return;
    objc.msg_send(void, vc, "setNeedsStatusBarAppearanceUpdate", .{});
}

var g_geom_desc: objc.BlockDescriptor = .{ .size = @sizeOf(objc.Block) };
var g_geom_block: objc.Block = undefined;

// requestGeometryUpdate requires an error handler; a rejected update (the orientation is
// outside the supported set) leaves the app in its current orientation.
fn geometry_error(_: *objc.Block, _: Id) callconv(.c) void {}

// Set the allowed orientation mask, then ask the window scene to adopt it now (the override
// alone only constrains future rotations).
pub fn set_orientation(mask: objc.NSUInteger) void {
    g_orientation = mask;
    if (g_root_vc) |vc| {
        const sel = objc.sel("setNeedsUpdateOfSupportedInterfaceOrientations");
        if (objc.msg_send(objc.BOOL, vc, "respondsToSelector:", .{sel}) != 0) {
            objc.msg_send(void, vc, "setNeedsUpdateOfSupportedInterfaceOrientations", .{});
        }
    }
    force_geometry(mask);
}

fn force_geometry(mask: objc.NSUInteger) void {
    const window = g_window.window orelse return;
    const scene = objc.msg_send(?Id, window, "windowScene", .{}) orelse return;
    const PrefsCls = objc.get_class("UIWindowSceneGeometryPreferencesIOS") orelse return;
    const init_sel = "initWithInterfaceOrientations:";
    const prefs = objc.msg_send(Id, objc.alloc(PrefsCls), init_sel, .{mask});
    std.debug.assert(@intFromPtr(prefs) != 0);
    _ = objc.msg_send(Id, prefs, "autorelease", .{});
    g_geom_block = objc.global_block(@ptrCast(&geometry_error), &g_geom_desc);
    const sel = "requestGeometryUpdateWithPreferences:errorHandler:";
    objc.msg_send(void, scene, sel, .{ prefs, &g_geom_block });
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
    add_touch_methods(cls);
    objc.objc_registerClassPair(cls);
    g_metal_view_class = cls;
    return cls;
}

fn metal_layer_class(_: objc.Class, _: objc.Sel) callconv(.c) objc.Class {
    // CAMetalLayer is always present (QuartzCore is linked); the lookup cannot fail.
    return objc.get_class("CAMetalLayer").?;
}

fn add_touch_methods(cls: objc.Class) void {
    add_method(cls, "touchesBegan:withEvent:", @ptrCast(&touches_began));
    add_method(cls, "touchesMoved:withEvent:", @ptrCast(&touches_moved));
    add_method(cls, "touchesEnded:withEvent:", @ptrCast(&touches_ended));
    add_method(cls, "touchesCancelled:withEvent:", @ptrCast(&touches_cancelled));
}

// "v@:@@" = void return; self, _cmd, NSSet* touches, UIEvent* - the signature all
// four touch selectors share, so one helper installs them.
fn add_method(cls: objc.Class, name: [:0]const u8, imp: *const anyopaque) void {
    _ = objc.class_addMethod(cls, objc.sel(name), imp, "v@:@@");
}

// A touch down hit-tests and presses the control under the finger; the engine fires
// the click on the matching up. iOS view coords are top-left, y-down - the same
// space the engine hit-tests in - so the point passes through unscaled.
fn touches_began(self: Id, _: objc.Sel, touches: Id, _: Id) callconv(.c) void {
    const p = touch_point(self, touches) orelse return;
    if (custom_shell.mouse_dispatch()) |d| d.on_down(d.ctx, @floatCast(p.x), @floatCast(p.y));
}

fn touches_moved(self: Id, _: objc.Sel, touches: Id, _: Id) callconv(.c) void {
    const p = touch_point(self, touches) orelse return;
    if (custom_shell.touch_move()) |tm| tm.cb(tm.ctx, @floatCast(p.x), @floatCast(p.y));
}

fn touches_ended(_: Id, _: objc.Sel, _: Id, _: Id) callconv(.c) void {
    const d = custom_shell.mouse_dispatch() orelse return;
    d.on_up(d.ctx);
    d.on_exit(d.ctx); // touch has no hover, so the release also clears pressed state
}

fn touches_cancelled(_: Id, _: objc.Sel, _: Id, _: Id) callconv(.c) void {
    const d = custom_shell.mouse_dispatch() orelse return;
    d.on_up(d.ctx);
    d.on_exit(d.ctx);
}

fn touch_point(view: Id, touches: Id) ?native.CGPoint {
    const touch = objc.msg_send(?Id, touches, "anyObject", .{}) orelse return null;
    return objc.msg_send(native.CGPoint, touch, "locationInView:", .{view});
}

fn ns_string(s: [:0]const u8) Id {
    const NSString = objc.get_class("NSString").?;
    return objc.msg_send(Id, NSString, "stringWithUTF8String:", .{@as([*:0]const u8, s.ptr)});
}
