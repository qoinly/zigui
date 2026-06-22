// The system document picker. open_file launches it; the chosen file's display name
// plus a readable local path (a copy ZiguiActivity.onActivityResult imports into the
// app's cacheDir) come back through on_native_file, and the app reads them once via
// take_file. pending() reports the in-flight pick (drive a spinner off it). The result
// lands on the UI thread, off the render thread, so it wakes the loop via
// background.nudge() rather than relying on an animating frame.

const jni = @import("../jni.zig");
const util = @import("util.zig");
const background = @import("../../../background.zig");
const PickedFile = @import("../../../napi/picker_types.zig").PickedFile;

const JNIEnv = util.JNIEnv;

// The request id startActivityForResult tags the pick with; the app's
// onActivityResult must echo it back so this is the only result it reads.
pub const FILE_REQUEST_CODE: jni.jint = 0x5A16;

// The picked file's display name + local path, awaiting the app's one take_file. The
// name caps at a leaf filename; the path at a cacheDir absolute path.
var g_name: [256]u8 = undefined;
var g_name_len: usize = 0;
var g_path: [1024]u8 = undefined;
var g_path_len: usize = 0;
var g_valid: bool = false;
var g_pending: bool = false;

// Launches the system document picker (ACTION_OPEN_DOCUMENT). The chosen file's name +
// path arrive later through on_native_file via the activity's onActivityResult.
pub fn open_file() void {
    const c = util.ctx() orelse return;
    const env = c.env;
    const t = env.*;
    const intent_cls = t.FindClass(env, "android/content/Intent") orelse return;
    defer t.DeleteLocalRef(env, intent_cls);
    const ctor = t.GetMethodID(env, intent_cls, "<init>", "(Ljava/lang/String;)V") orelse return;
    const action = util.jstr(env, "android.intent.action.OPEN_DOCUMENT") orelse return;
    defer t.DeleteLocalRef(env, action);
    var aa = [_]jni.jvalue{.{ .l = action }};
    const intent = t.NewObjectA(env, intent_cls, ctor, &aa) orelse return;
    defer t.DeleteLocalRef(env, intent);

    const add_cat = t.GetMethodID(
        env,
        intent_cls,
        "addCategory",
        "(Ljava/lang/String;)Landroid/content/Intent;",
    ) orelse return;
    const cat = util.jstr(env, "android.intent.category.OPENABLE") orelse return;
    defer t.DeleteLocalRef(env, cat);
    var cata = [_]jni.jvalue{.{ .l = cat }};
    if (t.CallObjectMethodA(env, intent, add_cat, &cata)) |r| t.DeleteLocalRef(env, r);

    const set_type = t.GetMethodID(
        env,
        intent_cls,
        "setType",
        "(Ljava/lang/String;)Landroid/content/Intent;",
    ) orelse return;
    const mime = util.jstr(env, "*/*") orelse return;
    defer t.DeleteLocalRef(env, mime);
    var ta = [_]jni.jvalue{.{ .l = mime }};
    if (t.CallObjectMethodA(env, intent, set_type, &ta)) |r| t.DeleteLocalRef(env, r);

    const act_cls = t.GetObjectClass(env, c.activity) orelse return;
    defer t.DeleteLocalRef(env, act_cls);
    const start = t.GetMethodID(
        env,
        act_cls,
        "startActivityForResult",
        "(Landroid/content/Intent;I)V",
    ) orelse return;
    var sa = [_]jni.jvalue{ .{ .l = intent }, .{ .i = FILE_REQUEST_CODE } };
    t.CallVoidMethodA(env, c.activity, start, &sa);
    g_valid = false; // drop any undrained prior result before this pick
    g_pending = true; // the result or cancel clears it
}

// Whether a pick is in flight (between open_file and the result/cancel). A caller
// drives a spinner off this.
pub fn pending() bool {
    return g_pending;
}

// The picked file's name + local path, returned once after a pick (null until then,
// and again after the single read). The slices live until the next open_file.
pub fn take_file() ?PickedFile {
    if (!g_valid) return null;
    g_valid = false;
    return .{ .name = g_name[0..g_name_len], .path = g_path[0..g_path_len] };
}

// onActivityResult forwards the picked file's display name + cacheDir path here (the
// erased env + two Java Strings). Stashed for the app's one take_file, then the loop is
// woken so the next poll lands it.
pub fn on_native_file(env_ptr: *anyopaque, name: ?*anyopaque, path: ?*anyopaque) void {
    const env: JNIEnv = @ptrCast(@alignCast(env_ptr));
    g_name_len = util.read_jstr(env, name, &g_name).len;
    g_path_len = util.read_jstr(env, path, &g_path).len;
    g_valid = true;
    g_pending = false;
    background.nudge();
}

// onActivityResult forwards a cancel or a failed import here: clear the in-flight flag
// so the spinner stops, and wake the loop so the change shows.
pub fn on_native_cancel() void {
    g_pending = false;
    background.nudge();
}
