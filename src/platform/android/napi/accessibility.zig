// AccessibilityService control: inject gestures and read the foreground node tree.
// The system-bound service lives in the app (ZiguiAccessibilityService); native
// reaches it through generic activity methods (the show_keyboard pattern), so the
// library never names the app package. request_enable opens the system settings
// where the user toggles the service on - an app cannot enable it itself.

const std = @import("std");
const jni = @import("../jni.zig");
const util = @import("util.zig");

const JNIEnv = util.JNIEnv;

// Whether the service is connected (the activity reads its static instance). Inject
// and read are no-ops until this is true.
pub fn enabled() bool {
    const c = util.ctx() orelse return false;
    const env = c.env;
    const t = env.*;
    const cls = t.GetObjectClass(env, c.activity) orelse return false;
    defer t.DeleteLocalRef(env, cls);
    const m = t.GetMethodID(env, cls, "a11yEnabled", "()Z") orelse return false;
    return t.CallBooleanMethodA(env, c.activity, m, null) != 0;
}

// Opens the system accessibility settings so the user can enable the service.
pub fn request_enable() void {
    const c = util.ctx() orelse return;
    const env = c.env;
    const t = env.*;
    const intent_cls = t.FindClass(env, "android/content/Intent") orelse return;
    defer t.DeleteLocalRef(env, intent_cls);
    const ctor = t.GetMethodID(env, intent_cls, "<init>", "(Ljava/lang/String;)V") orelse return;
    const action = util.jstr(env, "android.settings.ACCESSIBILITY_SETTINGS") orelse return;
    defer t.DeleteLocalRef(env, action);
    var a = [_]jni.jvalue{.{ .l = action }};
    const intent = t.NewObjectA(env, intent_cls, ctor, &a) orelse return;
    defer t.DeleteLocalRef(env, intent);
    util.start_activity(env, c.activity, intent);
}

// Inject a tap at screen-pixel (x, y) through dispatchGesture.
pub fn tap(x: f32, y: f32) void {
    var a = [_]jni.jvalue{ .{ .f = x }, .{ .f = y } };
    activity_void("a11yTap", "(FF)V", &a);
}

// Inject a swipe from (x1, y1) to (x2, y2) over duration_ms through dispatchGesture.
pub fn swipe(x1: f32, y1: f32, x2: f32, y2: f32, duration_ms: jni.jint) void {
    var a = [_]jni.jvalue{
        .{ .f = x1 }, .{ .f = y1 }, .{ .f = x2 }, .{ .f = y2 }, .{ .i = duration_ms },
    };
    activity_void("a11ySwipe", "(FFFFI)V", &a);
}

// performGlobalAction(code): the facade maps a GlobalAction to the GLOBAL_ACTION_* code.
pub fn global_action(code: jni.jint) void {
    var a = [_]jni.jvalue{.{ .i = code }};
    activity_void("a11yGlobalAction", "(I)V", &a);
}

// Reads the foreground window's node tree as text (one "x,y,w,h\ttext" line per
// node that has text), copied into buf. null on a JNI miss; an empty slice when no
// service is connected or the tree has no text.
pub fn read(buf: []u8) ?[]const u8 {
    const c = util.ctx() orelse return null;
    const env = c.env;
    const t = env.*;
    const cls = t.GetObjectClass(env, c.activity) orelse return null;
    defer t.DeleteLocalRef(env, cls);
    const m = t.GetMethodID(env, cls, "a11yReadScreen", "()Ljava/lang/String;") orelse return null;
    const s = t.CallObjectMethodA(env, c.activity, m, null) orelse return null;
    defer t.DeleteLocalRef(env, s);
    const chars = t.GetStringUTFChars(env, s, null) orelse return null;
    defer t.ReleaseStringUTFChars(env, s, chars);
    const span = std.mem.span(chars);
    var n = @min(span.len, buf.len);
    // A byte-count truncation could split a UTF-8 codepoint; back off to its start.
    while (n > 0 and n < span.len and (span[n] & 0xc0) == 0x80) n -= 1;
    @memcpy(buf[0..n], span[0..n]);
    return buf[0..n];
}

// Calls a no-arg-class activity method that returns void (the inject path). A miss
// at any JNI step degrades to no-op, like the other activity-method bridges.
fn activity_void(name: [*:0]const u8, sig: [*:0]const u8, args: [*]const jni.jvalue) void {
    const c = util.ctx() orelse return;
    const env = c.env;
    const t = env.*;
    const cls = t.GetObjectClass(env, c.activity) orelse return;
    defer t.DeleteLocalRef(env, cls);
    const m = t.GetMethodID(env, cls, name, sig) orelse return;
    t.CallVoidMethodA(env, c.activity, m, args);
}
