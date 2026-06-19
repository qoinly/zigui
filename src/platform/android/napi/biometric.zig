// Biometric auth (fingerprint / face) via the system BiometricPrompt. authenticate
// drives the prompt through the app's ZiguiActivity.authenticateBiometric (the
// show_keyboard shape: a generic activity method run on the UI thread); the terminal
// outcome arrives through on_native_biometric and the app reads it once via
// take_result. available reports whether an enrolled biometric exists to prompt for.

const std = @import("std");
const jni = @import("../jni.zig");
const util = @import("util.zig");

// 0 = nothing delivered since the last read, 1 = succeeded, 2 = failed/cancelled.
var g_result: i32 = 0;

// Calls the activity's authenticateBiometric, which builds the prompt on the UI
// thread and reports the terminal result back through on_native_biometric. The prior
// unread result is cleared so a poll only ever sees this run's outcome.
pub fn authenticate(title: []const u8, subtitle: []const u8) void {
    std.debug.assert(title.len > 0); // the prompt shows a title, so it must be set
    g_result = 0;
    const c = util.ctx() orelse return;
    const env = c.env;
    const t = env.*;
    const cls = t.GetObjectClass(env, c.activity) orelse return;
    defer t.DeleteLocalRef(env, cls);
    const m = t.GetMethodID(
        env,
        cls,
        "authenticateBiometric",
        "(Ljava/lang/String;Ljava/lang/String;)V",
    ) orelse return;
    const title_str = util.jstr(env, title) orelse return;
    defer t.DeleteLocalRef(env, title_str);
    const sub_str = util.jstr(env, subtitle) orelse return;
    defer t.DeleteLocalRef(env, sub_str);
    var a = [_]jni.jvalue{ .{ .l = title_str }, .{ .l = sub_str } };
    t.CallVoidMethodA(env, c.activity, m, &a);
}

// BiometricManager.canAuthenticate() == BIOMETRIC_SUCCESS (0): a biometric is
// enrolled and usable. Any miss (no service, no hardware, nothing enrolled) is false.
pub fn available() bool {
    const c = util.ctx() orelse return false;
    const env = c.env;
    const t = env.*;
    const bm = util.system_service(env, c.activity, "biometric") orelse return false;
    defer t.DeleteLocalRef(env, bm);
    const bm_cls = t.GetObjectClass(env, bm) orelse return false;
    defer t.DeleteLocalRef(env, bm_cls);
    const m = t.GetMethodID(env, bm_cls, "canAuthenticate", "()I") orelse return false;
    return t.CallIntMethodA(env, bm, m, null) == 0; // 0 = BIOMETRIC_SUCCESS
}

// The app's ZiguiActivity.nativeOnBiometric forwards the prompt's terminal outcome
// here (1 succeeded, 2 failed/cancelled); it becomes the next take_result. Runs on
// the main executor, the same thread the paint loop polls from, so no cross-thread
// hand-off is needed.
pub fn on_native_biometric(code: i32) void {
    std.debug.assert(code == 1 or code == 2); // only the two terminal outcomes bridge
    g_result = code;
}

// The app reads the last auth outcome once (consume-once, the take_file shape):
// 1 succeeded, 2 failed; null when nothing finished since the last read.
pub fn take_result() ?i32 {
    if (g_result == 0) return null;
    const r = g_result;
    g_result = 0;
    std.debug.assert(r == 1 or r == 2); // a stored result is always one of the two
    return r;
}
