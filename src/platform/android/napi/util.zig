// Shared JNI helpers for the android native-api domains: reach the activity (a
// Context) on the paint thread, which for a NativeActivity is the UI thread where
// the managers and startActivity expect to be touched. Each domain file builds its
// JNI calls on these. A JNI-lookup failure degrades silently; an off-thread call
// warns once then no-ops (see ctx). Never a crash.

const std = @import("std");
const jni = @import("../jni.zig");
const utf8 = @import("utf8.zig");

pub const JNIEnv = jni.JNIEnv;

// liblog, to warn once when napi is misused off the UI thread (see ctx).
extern fn __android_log_write(prio: c_int, tag: [*:0]const u8, text: [*:0]const u8) c_int;
var g_warned_off_thread: bool = false;

// A short scratch span for a Java string; titles, urls, and shared text are small.
pub const STR_MAX: usize = 1024;

pub const Ctx = struct { env: JNIEnv, activity: jni.jobject };

pub fn ctx() ?Ctx {
    // napi binds to the UI thread (g_env is its JNIEnv). Off it - a background job or a
    // headless handler - the call degrades to a safe no-op rather than touch a wrong-
    // thread env, and warns once so the misuse shows in logcat without crashing.
    if (!jni.on_ui_thread()) {
        if (!g_warned_off_thread) {
            g_warned_off_thread = true;
            _ = __android_log_write(5, "zigui", "napi.* called off the UI thread " ++
                "(a background / headless handler must not); ignored");
        }
        return null;
    }
    const env = jni.thread_env() orelse return null;
    const activity = jni.thread_activity() orelse return null;
    env.*.ExceptionClear(env); // start from a clean exception slate
    return .{ .env = env, .activity = activity };
}

// Reads a Java String's modified-UTF8 into buf (clamped, codepoint-floored at the
// cut), valid for the caller's scope. Empty on a null ref or a JNI miss.
pub fn read_jstr(env: JNIEnv, s: ?*anyopaque, buf: []u8) []const u8 {
    const ref = s orelse return buf[0..0];
    const t = env.*;
    const chars = t.GetStringUTFChars(env, ref, null) orelse return buf[0..0];
    defer t.ReleaseStringUTFChars(env, ref, chars);
    const span = std.mem.span(chars);
    const n = utf8.floor(span, @min(span.len, buf.len));
    std.debug.assert(n <= buf.len); // the floor only shrinks the clamp, never grows it
    @memcpy(buf[0..n], span[0..n]);
    return buf[0..n];
}

// A NUL-terminated Java String from a UTF-8 slice (clamped to STR_MAX).
pub fn jstr(env: JNIEnv, s: []const u8) ?jni.jobject {
    std.debug.assert(s.len <= STR_MAX); // callers pass small labels/urls/text
    var buf: [STR_MAX + 1]u8 = undefined;
    const n = @min(s.len, STR_MAX);
    @memcpy(buf[0..n], s[0..n]);
    buf[n] = 0;
    return env.*.NewStringUTF(env, @ptrCast(&buf));
}

// Context.getSystemService(name) - the manager objects (vibrator, notification,
// clipboard). The caller owns the returned local ref.
pub fn system_service(env: JNIEnv, activity: jni.jobject, name: []const u8) ?jni.jobject {
    const t = env.*;
    const act_cls = t.GetObjectClass(env, activity) orelse return null;
    defer t.DeleteLocalRef(env, act_cls);
    const mid = t.GetMethodID(
        env,
        act_cls,
        "getSystemService",
        "(Ljava/lang/String;)Ljava/lang/Object;",
    ) orelse return null;
    const name_str = jstr(env, name) orelse return null;
    defer t.DeleteLocalRef(env, name_str);
    var arg = [_]jni.jvalue{.{ .l = name_str }};
    return t.CallObjectMethodA(env, activity, mid, &arg);
}

pub fn start_activity(env: JNIEnv, activity: jni.jobject, intent: jni.jobject) void {
    std.debug.assert(intent != null);
    const t = env.*;
    const act_cls = t.GetObjectClass(env, activity) orelse return;
    defer t.DeleteLocalRef(env, act_cls);
    const start = t.GetMethodID(
        env,
        act_cls,
        "startActivity",
        "(Landroid/content/Intent;)V",
    ) orelse return;
    var a = [_]jni.jvalue{.{ .l = intent }};
    t.CallVoidMethodA(env, activity, start, &a);
}
