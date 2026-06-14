// Haptics. VibrationEffect.createOneShot(ms, DEFAULT_AMPLITUDE) -> Vibrator.vibrate.

const std = @import("std");
const jni = @import("../jni.zig");
const util = @import("util.zig");

pub fn vibrate(ms: i64) void {
    std.debug.assert(ms > 0); // a zero-length buzz is a caller bug, not a request
    const c = util.ctx() orelse return;
    const env = c.env;
    const t = env.*;
    const vib = util.system_service(env, c.activity, "vibrator") orelse return;
    defer t.DeleteLocalRef(env, vib);
    const eff_cls = t.FindClass(env, "android/os/VibrationEffect") orelse return;
    defer t.DeleteLocalRef(env, eff_cls);
    const create = t.GetStaticMethodID(
        env,
        eff_cls,
        "createOneShot",
        "(JI)Landroid/os/VibrationEffect;",
    ) orelse return;
    var ca = [_]jni.jvalue{ .{ .j = ms }, .{ .i = -1 } }; // -1 = DEFAULT_AMPLITUDE
    const effect = t.CallStaticObjectMethodA(env, eff_cls, create, &ca) orelse return;
    defer t.DeleteLocalRef(env, effect);
    const vib_cls = t.GetObjectClass(env, vib) orelse return;
    defer t.DeleteLocalRef(env, vib_cls);
    const vibrate_m = t.GetMethodID(
        env,
        vib_cls,
        "vibrate",
        "(Landroid/os/VibrationEffect;)V",
    ) orelse return;
    var va = [_]jni.jvalue{.{ .l = effect }};
    t.CallVoidMethodA(env, vib, vibrate_m, &va);
}
