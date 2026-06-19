// The system document picker. open_file launches it; the chosen file's text comes
// back through the app's ZiguiActivity.onActivityResult -> on_native_file, and the
// app reads it once via take_file.

const std = @import("std");
const jni = @import("../jni.zig");
const util = @import("util.zig");
const utf8 = @import("utf8.zig");

const JNIEnv = util.JNIEnv;

// The request id startActivityForResult tags the pick with; the app's
// onActivityResult must echo it back so this is the only result it reads.
pub const FILE_REQUEST_CODE: jni.jint = 0x5A16;

// The picked file's text content, awaiting the app's one take_file. A whole file is
// large, so this caps the preview rather than allocating per pick.
const FILE_MAX: usize = 4096;
var g_file_buf: [FILE_MAX]u8 = undefined;
var g_file_len: usize = 0;
var g_file_valid: bool = false;

// Launches the system document picker (ACTION_OPEN_DOCUMENT). The chosen file's
// text arrives later through on_native_file via the activity's onActivityResult.
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
}

// The app's ZiguiActivity.onActivityResult forwards the picked file's text here
// (the erased env + Java String), the IME-sink shape. It becomes the next take_file.
pub fn on_native_file(env_ptr: *anyopaque, content: ?*anyopaque) void {
    const env: JNIEnv = @ptrCast(@alignCast(env_ptr));
    const ref = content orelse return;
    const t = env.*;
    const chars = t.GetStringUTFChars(env, ref, null) orelse return;
    defer t.ReleaseStringUTFChars(env, ref, chars);
    const span = std.mem.span(chars);
    // Back the cap-truncation off any split codepoint before the copy.
    g_file_len = utf8.floor(span, @min(span.len, FILE_MAX));
    @memcpy(g_file_buf[0..g_file_len], span[0..g_file_len]);
    g_file_valid = true;
    std.debug.assert(g_file_len <= FILE_MAX);
}

// The app reads a just-picked file once (consume-once, the navigator take_result
// shape); null when nothing was picked since the last read.
pub fn take_file(buf: []u8) ?[]const u8 {
    if (!g_file_valid) return null;
    std.debug.assert(g_file_len <= g_file_buf.len);
    g_file_valid = false;
    const n = @min(g_file_len, buf.len);
    @memcpy(buf[0..n], g_file_buf[0..n]);
    return buf[0..n];
}
