// Notification listening: observe notifications posted by any app. The shipped
// ZiguiNotificationListenerService forwards each posted notification here (the
// layer-2 event shape: Java calls INTO native); the app reads the latest via take.
// The service is user-enabled in system settings - request_enable opens that screen,
// enabled() reports whether it is connected.

const std = @import("std");
const jni = @import("../jni.zig");
const util = @import("util.zig");
const utf8 = @import("utf8.zig");
const headless = @import("../../../napi/headless.zig");

const JNIEnv = util.JNIEnv;

// The most recent posted notification, "package\ttitle\ttext", awaiting one take.
const NOTIF_MAX: usize = 512;
var g_buf: [NOTIF_MAX]u8 = undefined;
var g_len: usize = 0;
// Filled on the service's binder thread, polled on the paint thread, so the buffer
// is published through a release/acquire flag (the std.atomic.Value pattern used
// elsewhere for cross-thread state): the acquire in take establishes happens-before
// on the g_buf/g_len writes. A new notification arriving mid-take can still garble
// the one line being copied, but it stays in-bounds and the next take is clean.
var g_valid: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

const NOTIF_CLASS = "io.qoinly.zigui.ZiguiNotificationListenerService";

// Whether the listener is connected (its static flag). The optional service is reached
// by its static methods (loaded via the activity classloader), not via the activity.
pub fn enabled() bool {
    const c = util.ctx() orelse return false;
    const env = c.env;
    const t = env.*;
    const cls = util.load_app_class(env, c.activity, NOTIF_CLASS) orelse return false;
    defer t.DeleteLocalRef(env, cls);
    const m = t.GetStaticMethodID(env, cls, "isEnabled", "()Z") orelse return false;
    return t.CallStaticBooleanMethodA(env, cls, m, null) != 0;
}

// Opens the notification-access settings so the user can enable the listener.
pub fn request_enable() void {
    const c = util.ctx() orelse return;
    const env = c.env;
    const t = env.*;
    const intent_cls = t.FindClass(env, "android/content/Intent") orelse return;
    defer t.DeleteLocalRef(env, intent_cls);
    const ctor = t.GetMethodID(env, intent_cls, "<init>", "(Ljava/lang/String;)V") orelse return;
    const settings = "android.settings.ACTION_NOTIFICATION_LISTENER_SETTINGS";
    const action = util.jstr(env, settings) orelse return;
    defer t.DeleteLocalRef(env, action);
    var a = [_]jni.jvalue{.{ .l = action }};
    const intent = t.NewObjectA(env, intent_cls, ctor, &a) orelse return;
    defer t.DeleteLocalRef(env, intent);
    util.start_activity(env, c.activity, intent);
}

// The shipped service forwards each posted notification here (package, title, text,
// all erased Java Strings); it becomes the next take. Runs on the service's thread,
// but only g_* are touched and a torn read degrades to a stale/partial line.
pub fn on_native_notification(
    env_ptr: *anyopaque,
    pkg: ?*anyopaque,
    title: ?*anyopaque,
    text: ?*anyopaque,
) void {
    const env: JNIEnv = @ptrCast(@alignCast(env_ptr));
    var pbuf: [128]u8 = undefined;
    var tbuf: [192]u8 = undefined;
    var xbuf: [NOTIF_MAX]u8 = undefined;
    const p = util.read_jstr(env, pkg, &pbuf);
    const ti = util.read_jstr(env, title, &tbuf);
    const tx = util.read_jstr(env, text, &xbuf);

    // Headless: hand the app a decoded event on this thread, so its handler runs even
    // when nothing is foreground to poll the mailbox below.
    headless.dispatch(.{ .notification = .{ .package = p, .title = ti, .text = tx } });

    // Foreground mailbox for take(): "package\ttitle\ttext".
    g_valid.store(false, .monotonic); // mark in-progress so a poll skips a half-write
    g_len = 0;
    put(p);
    put_byte('\t');
    put(ti);
    put_byte('\t');
    put(tx);
    std.debug.assert(g_len <= NOTIF_MAX);
    g_valid.store(true, .release); // publish the fully-written buffer
}

// The app reads the latest notification once (consume-once, the take_file shape);
// null when nothing arrived since the last read.
pub fn take(buf: []u8) ?[]const u8 {
    if (!g_valid.swap(false, .acquire)) return null;
    std.debug.assert(g_len <= g_buf.len); // the fill invariant on_native_notification holds
    // Clamp against g_buf too, not just buf: a torn g_len (the plain-var read racing a
    // concurrent fill) must never index past g_buf, even where the assert is elided.
    const len = @min(g_len, g_buf.len);
    const n = @min(len, buf.len);
    @memcpy(buf[0..n], g_buf[0..n]);
    return buf[0..n];
}

// Appends a slice to g_buf, clamped to the room left (codepoint-floored at the cut).
fn put(slice: []const u8) void {
    std.debug.assert(g_len <= NOTIF_MAX); // the clamp below relies on the room calc
    const k = utf8.floor(slice, @min(slice.len, NOTIF_MAX - g_len));
    @memcpy(g_buf[g_len .. g_len + k], slice[0..k]);
    g_len += k;
}

fn put_byte(b: u8) void {
    if (g_len >= NOTIF_MAX) return;
    g_buf[g_len] = b;
    g_len += 1;
}
