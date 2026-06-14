// Runtime permissions. An immediate-mode app polls granted() each frame and calls
// request() while it is false; the system dialog's answer is read back by the next
// granted() poll, so there is no result callback to wire.

const std = @import("std");
const jni = @import("../jni.zig");
const util = @import("util.zig");

const JNIEnv = util.JNIEnv;

pub const POST_NOTIFICATIONS = "android.permission.POST_NOTIFICATIONS";

pub fn granted(name: []const u8) bool {
    std.debug.assert(name.len > 0);
    const c = util.ctx() orelse return false;
    return granted_jni(c.env, c.activity, name);
}

pub fn request(name: []const u8) void {
    std.debug.assert(name.len > 0);
    const c = util.ctx() orelse return;
    request_jni(c.env, c.activity, name);
}

// Pre-API-23 has no checkSelfPermission (permissions are install-time), so a
// missing method reads as granted. Shared with notifications' POST_NOTIFICATIONS.
pub fn granted_jni(env: JNIEnv, activity: jni.jobject, name: []const u8) bool {
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
// dialog; the result is handled by Android, not awaited here.
pub fn request_jni(env: JNIEnv, activity: jni.jobject, name: []const u8) void {
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
