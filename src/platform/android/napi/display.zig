// Window-level display properties: keep-screen-on, the status-bar icon tint, and
// immersive (hide the system bars). All three live only on the Java window /
// insets controller, reached through JNI on the activity (the safe_insets pattern).
// Calls run on the paint thread, which for a NativeActivity IS the UI thread, so
// the window mutations are on the thread the framework requires. Each setter caches
// its last applied value and hops into JNI only on a real change.

const std = @import("std");
const jni = @import("../jni.zig");

// WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON.
const FLAG_KEEP_SCREEN_ON: jni.jint = 0x00000080;
// WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS - a LIGHT status-bar
// background, i.e. DARK icons (for a light app); cleared = light icons (dark app).
const APPEARANCE_LIGHT_STATUS_BARS: jni.jint = 0x00000008;
// WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE - hidden bars peek
// back on an edge swipe, the standard immersive gesture.
const BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE: jni.jint = 2;

var g_keep_awake: ?bool = null;
var g_dark_icons: ?bool = null;
var g_immersive: ?bool = null;

const Window = struct { env: jni.JNIEnv, obj: jni.jobject };

// The activity's current Window, or null when the JNI thread/activity is not yet
// bound. The caller owns the returned local ref (DeleteLocalRef when done).
fn window() ?Window {
    const env = jni.thread_env() orelse return null;
    const activity = jni.thread_activity() orelse return null;
    const t = env.*;
    t.ExceptionClear(env); // start from a clean exception slate
    const act_cls = t.GetObjectClass(env, activity) orelse return null;
    defer t.DeleteLocalRef(env, act_cls);
    const get = t.GetMethodID(
        env,
        act_cls,
        "getWindow",
        "()Landroid/view/Window;",
    ) orelse return null;
    const obj = t.CallObjectMethodA(env, activity, get, null) orelse return null;
    return .{ .env = env, .obj = obj };
}

// The window's WindowInsetsController (API 30+), or null on an older device where
// the lookup fails. The caller owns the returned local ref.
fn insets_controller(env: jni.JNIEnv, win: jni.jobject) ?jni.jobject {
    std.debug.assert(win != null); // window() only returns a non-null surface
    const t = env.*;
    const win_cls = t.GetObjectClass(env, win) orelse return null;
    defer t.DeleteLocalRef(env, win_cls);
    const get = t.GetMethodID(
        env,
        win_cls,
        "getInsetsController",
        "()Landroid/view/WindowInsetsController;",
    ) orelse return null;
    return t.CallObjectMethodA(env, win, get, null);
}

// WindowInsets.Type.systemBars() - the status + navigation bar type bitmask
// (API 30+), or null where the type class is absent.
fn system_bars_mask(env: jni.JNIEnv) ?jni.jint {
    const t = env.*;
    const cls = t.FindClass(env, "android/view/WindowInsets$Type") orelse {
        t.ExceptionClear(env);
        return null;
    };
    defer t.DeleteLocalRef(env, cls);
    const m = t.GetStaticMethodID(env, cls, "systemBars", "()I") orelse return null;
    return t.CallStaticIntMethodA(env, cls, m, null);
}

// FLAG_KEEP_SCREEN_ON: while on, the display never dims or sleeps. Window.addFlags
// / clearFlags is API 1, so this is the one property that holds on every device.
pub fn keep_awake(on: bool) void {
    if (g_keep_awake) |prev| if (prev == on) return;
    const w = window() orelse return;
    const env = w.env;
    const t = env.*;
    defer t.DeleteLocalRef(env, w.obj);
    const win_cls = t.GetObjectClass(env, w.obj) orelse return;
    defer t.DeleteLocalRef(env, win_cls);
    const name = if (on) "addFlags" else "clearFlags";
    const m = t.GetMethodID(env, win_cls, name, "(I)V") orelse return;
    var args = [_]jni.jvalue{.{ .i = FLAG_KEEP_SCREEN_ON }};
    t.CallVoidMethodA(env, w.obj, m, &args);
    g_keep_awake = on; // cache only after the apply ran, so a skipped one retries
}

// The status-bar icon tint via setSystemBarsAppearance: dark icons set the
// LIGHT_STATUS_BARS appearance bit, light icons clear it. No-op before API 30.
pub fn status_bar_dark_icons(dark: bool) void {
    if (g_dark_icons) |prev| if (prev == dark) return;
    const w = window() orelse return;
    const env = w.env;
    const t = env.*;
    defer t.DeleteLocalRef(env, w.obj);
    const ctl = insets_controller(env, w.obj) orelse return;
    defer t.DeleteLocalRef(env, ctl);
    const ctl_cls = t.GetObjectClass(env, ctl) orelse return;
    defer t.DeleteLocalRef(env, ctl_cls);
    const m = t.GetMethodID(env, ctl_cls, "setSystemBarsAppearance", "(II)V") orelse return;
    const appearance: jni.jint = if (dark) APPEARANCE_LIGHT_STATUS_BARS else 0;
    var args = [_]jni.jvalue{ .{ .i = appearance }, .{ .i = APPEARANCE_LIGHT_STATUS_BARS } };
    t.CallVoidMethodA(env, ctl, m, &args);
    g_dark_icons = dark;
}

// Immersive: hide (on) or show (off) the system bars. Hiding first sets the
// transient-by-swipe behavior so the bars stay reachable. No-op before API 30.
pub fn immersive(on: bool) void {
    if (g_immersive) |prev| if (prev == on) return;
    const w = window() orelse return;
    const env = w.env;
    const t = env.*;
    defer t.DeleteLocalRef(env, w.obj);
    const ctl = insets_controller(env, w.obj) orelse return;
    defer t.DeleteLocalRef(env, ctl);
    const ctl_cls = t.GetObjectClass(env, ctl) orelse return;
    defer t.DeleteLocalRef(env, ctl_cls);
    const mask = system_bars_mask(env) orelse return;
    std.debug.assert(mask != 0); // a zero type mask would hide/show nothing
    if (on) {
        const beh = t.GetMethodID(env, ctl_cls, "setSystemBarsBehavior", "(I)V") orelse return;
        var ba = [_]jni.jvalue{.{ .i = BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE }};
        t.CallVoidMethodA(env, ctl, beh, &ba);
    }
    const name = if (on) "hide" else "show";
    const m = t.GetMethodID(env, ctl_cls, name, "(I)V") orelse return;
    var args = [_]jni.jvalue{.{ .i = mask }};
    t.CallVoidMethodA(env, ctl, m, &args);
    g_immersive = on;
}
