// The soft-keyboard (IME) bridge. A pure NativeActivity has no InputConnection,
// so the ZiguiActivity Java shim hosts a hidden EditText that owns the editing;
// every change is pushed here via the exported nativeOnText, and the kit draws
// the value (text_field_native_paint is false on Android). Native raises/dismisses
// the keyboard by calling showKeyboard/hideKeyboard back on the activity.

const std = @import("std");
const jni = @import("jni.zig");
const utf8 = @import("napi/utf8.zig");

pub const FIELD_BUF_MAX: usize = 256;

var g_buf: [FIELD_BUF_MAX]u8 = undefined;
var g_len: usize = 0;
var g_caret: usize = 0;

// The app's ZiguiActivity.nativeOnText (a package-named JNI export it owns)
// forwards here whenever the edited text changes; the full text + caret become
// the field's value for the kit to draw. The env/string arrive erased so the app
// export needs no zigui-internal JNI types.
pub fn on_native_text(env_ptr: *anyopaque, text: ?*anyopaque, caret_index: i32) void {
    const env: jni.JNIEnv = @ptrCast(@alignCast(env_ptr));
    const text_ref = text orelse return;
    const table = env.*;
    const chars = table.GetStringUTFChars(env, text_ref, null) orelse return;
    defer table.ReleaseStringUTFChars(env, text_ref, chars);
    const slice = std.mem.span(chars);
    // Back a cap-truncation off any split codepoint so the kit never shapes an
    // invalid trailing sequence.
    g_len = utf8.floor(slice, @min(slice.len, g_buf.len));
    @memcpy(g_buf[0..g_len], slice[0..g_len]);
    const clamped: usize = @intCast(@max(caret_index, 0));
    g_caret = @min(clamped, g_len);
    std.debug.assert(g_len <= g_buf.len);
    std.debug.assert(g_caret <= g_len);
}

// Seeds the editor with the field's current value and raises the soft keyboard.
pub fn show_keyboard(initial: []const u8) void {
    std.debug.assert(initial.len <= FIELD_BUF_MAX); // a field value never exceeds the buffer
    std.debug.assert(g_len <= g_buf.len); // the editor state the kit polls stays consistent
    const env = jni.thread_env() orelse return;
    const activity = jni.thread_activity() orelse return;
    const table = env.*;
    const class = table.GetObjectClass(env, activity) orelse return;
    defer table.DeleteLocalRef(env, class);
    const method = table.GetMethodID(
        env,
        class,
        "showKeyboard",
        "(Ljava/lang/String;)V",
    ) orelse return;
    const java_string = jstring(env, initial) orelse return;
    defer table.DeleteLocalRef(env, java_string);
    var args = [_]jni.jvalue{.{ .l = java_string }};
    table.CallVoidMethodA(env, activity, method, &args);
}

pub fn hide_keyboard() void {
    std.debug.assert(g_len <= g_buf.len); // the editor state the kit polls stays consistent
    const env = jni.thread_env() orelse return;
    const activity = jni.thread_activity() orelse return;
    const table = env.*;
    const class = table.GetObjectClass(env, activity) orelse return;
    defer table.DeleteLocalRef(env, class);
    const method = table.GetMethodID(env, class, "hideKeyboard", "()V") orelse return;
    table.CallVoidMethodA(env, activity, method, null);
}

pub fn value(buf: []u8) []const u8 {
    std.debug.assert(g_len <= g_buf.len); // the editor invariant on_native_text holds
    std.debug.assert(g_caret <= g_len); // the caret the kit draws alongside stays in range
    const n = @min(g_len, buf.len);
    @memcpy(buf[0..n], g_buf[0..n]);
    return buf[0..n];
}

pub fn caret() usize {
    std.debug.assert(g_caret <= g_len);
    return g_caret;
}

// A null-terminated Java String from a UTF-8 slice (BMP, the supported range).
fn jstring(env: jni.JNIEnv, s: []const u8) ?jni.jobject {
    std.debug.assert(s.len <= FIELD_BUF_MAX); // callers seed from a field value, which fits
    var buf: [FIELD_BUF_MAX + 1]u8 = undefined; // + 1 for the NUL the JNI string needs
    const n = @min(s.len, FIELD_BUF_MAX);
    std.debug.assert(n < buf.len);
    @memcpy(buf[0..n], s[0..n]);
    buf[n] = 0;
    return env.*.NewStringUTF(env, @ptrCast(&buf));
}
