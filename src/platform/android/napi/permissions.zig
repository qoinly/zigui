// Runtime permissions. An immediate-mode app polls status() / granted() each frame
// and calls request() while not granted; the system dialog's answer is read back by
// the next poll, so there is no result callback to wire.
//
// The manifest enumeration, the four-state resolution, and the "have we ever asked"
// flag live in the Java shell (ZiguiActivity), the way sms read/send do: the platform
// exposes them only through PackageManager / SharedPreferences chains that are far
// terser in Java. Native is a thin bridge - one call, copy the flat result out.
// granted_jni / request_jni stay native because the hot per-frame poll and the
// notifications gate share them.

const std = @import("std");
const jni = @import("../jni.zig");
const util = @import("util.zig");
const utf8 = @import("utf8.zig");

const JNIEnv = util.JNIEnv;

pub const POST_NOTIFICATIONS = "android.permission.POST_NOTIFICATIONS";

pub fn granted(name: []const u8) bool {
    std.debug.assert(name.len > 0);
    std.debug.assert(name.len <= util.STR_MAX);
    const c = util.ctx() orelse return false;
    return granted_jni(c.env, c.activity, name);
}

// The four-state as a 0..3 code (0 granted, 1 not-requested, 2 declined, 3 declined
// permanently); the facade maps it to permissions.Status. 1 is the safe default off
// the UI thread or on a JNI miss, and the clamp keeps the facade's @enumFromInt safe.
pub fn status_code(name: []const u8) u8 {
    std.debug.assert(name.len > 0);
    std.debug.assert(name.len <= util.STR_MAX);
    const c = util.ctx() orelse return 1;
    const t = c.env.*;
    const cls = t.GetObjectClass(c.env, c.activity) orelse return 1;
    defer t.DeleteLocalRef(c.env, cls);
    const m = t.GetMethodID(c.env, cls, "permissionState", "(Ljava/lang/String;)I") orelse return 1;
    const perm = util.jstr(c.env, name) orelse return 1;
    defer t.DeleteLocalRef(c.env, perm);
    var a = [_]jni.jvalue{.{ .l = perm }};
    const code = t.CallIntMethodA(c.env, c.activity, m, &a);
    return if (code >= 0 and code <= 3) @intCast(code) else 1;
}

// The permissions the manifest declares, so a screen drives off the manifest instead
// of hardcoding names. The shell returns them "\n"-joined; the bytes are copied into
// `scratch` and the returned slices point into it. `scratch` must hold the joined
// length or the overflow is dropped at a codepoint boundary.
pub fn declared(out: [][]const u8, scratch: []u8) [][]const u8 {
    std.debug.assert(out.len > 0); // a caller asking for zero names is a bug
    std.debug.assert(scratch.len > 0);
    const c = util.ctx() orelse return out[0..0];
    const t = c.env.*;
    const cls = t.GetObjectClass(c.env, c.activity) orelse return out[0..0];
    defer t.DeleteLocalRef(c.env, cls);
    const m = t.GetMethodID(c.env, cls, "permissionsDeclared", "()Ljava/lang/String;") orelse
        return out[0..0];
    const s = t.CallObjectMethodA(c.env, c.activity, m, null) orelse return out[0..0];
    defer t.DeleteLocalRef(c.env, s);
    const chars = t.GetStringUTFChars(c.env, s, null) orelse return out[0..0];
    defer t.ReleaseStringUTFChars(c.env, s, chars);
    const span = std.mem.span(chars);
    const n = utf8.floor(span, @min(span.len, scratch.len));
    @memcpy(scratch[0..n], span[0..n]);
    return split_lines(scratch[0..n], out);
}

// Splits the "\n"-joined names into slices of `buf`, bounded by out.len. Empty segments
// (a leading / trailing / doubled separator) are skipped.
fn split_lines(buf: []const u8, out: [][]const u8) [][]const u8 {
    std.debug.assert(out.len <= 4096); // a manifest's permission count is small
    var count: usize = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i <= buf.len and count < out.len) : (i += 1) {
        if (i == buf.len or buf[i] == '\n') {
            if (i > start) {
                out[count] = buf[start..i];
                count += 1;
            }
            start = i + 1;
        }
    }
    std.debug.assert(count <= out.len);
    return out[0..count];
}

pub fn request(name: []const u8) void {
    std.debug.assert(name.len > 0);
    std.debug.assert(name.len <= util.STR_MAX);
    const c = util.ctx() orelse return;
    const t = c.env.*;
    const cls = t.GetObjectClass(c.env, c.activity) orelse return;
    defer t.DeleteLocalRef(c.env, cls);
    // permissionRequest records the attempt (so a later status() can tell a permanent
    // denial from a never-asked one) and then raises the system dialog.
    const m = t.GetMethodID(c.env, cls, "permissionRequest", "(Ljava/lang/String;)V") orelse return;
    const perm = util.jstr(c.env, name) orelse return;
    defer t.DeleteLocalRef(c.env, perm);
    var a = [_]jni.jvalue{.{ .l = perm }};
    t.CallVoidMethodA(c.env, c.activity, m, &a);
}

// Pre-API-23 has no checkSelfPermission (permissions are install-time), so a
// missing method reads as granted. Shared with notifications' POST_NOTIFICATIONS.
pub fn granted_jni(env: JNIEnv, activity: jni.jobject, name: []const u8) bool {
    std.debug.assert(name.len > 0);
    const t = env.*;
    const act_cls = t.GetObjectClass(env, activity) orelse return false;
    defer t.DeleteLocalRef(env, act_cls);
    const check = t.GetMethodID(
        env,
        act_cls,
        "checkSelfPermission",
        "(Ljava/lang/String;)I",
    ) orelse return true;
    const perm = util.jstr(env, name) orelse return false;
    defer t.DeleteLocalRef(env, perm);
    var a = [_]jni.jvalue{.{ .l = perm }};
    return t.CallIntMethodA(env, activity, check, &a) == 0; // 0 = PERMISSION_GRANTED
}

// Activity.requestPermissions(new String[]{name}, 0) - raises the system grant
// dialog; the result is handled by Android, not awaited here. The notifications gate
// uses this directly; the public request() goes through the shell so it records the
// asked flag too.
pub fn request_jni(env: JNIEnv, activity: jni.jobject, name: []const u8) void {
    std.debug.assert(name.len > 0);
    const t = env.*;
    const str_cls = t.FindClass(env, "java/lang/String") orelse return;
    defer t.DeleteLocalRef(env, str_cls);
    const perm = util.jstr(env, name) orelse return;
    defer t.DeleteLocalRef(env, perm);
    const arr = t.NewObjectArray(env, 1, str_cls, perm) orelse return; // element 0 = perm
    defer t.DeleteLocalRef(env, arr);
    const act_cls = t.GetObjectClass(env, activity) orelse return;
    defer t.DeleteLocalRef(env, act_cls);
    const req = t.GetMethodID(
        env,
        act_cls,
        "requestPermissions",
        "([Ljava/lang/String;I)V",
    ) orelse return;
    var a = [_]jni.jvalue{ .{ .l = arr }, .{ .i = 0 } };
    t.CallVoidMethodA(env, activity, req, &a);
}
