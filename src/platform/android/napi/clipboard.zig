// Clipboard via ClipboardManager.

const std = @import("std");
const jni = @import("../jni.zig");
const util = @import("util.zig");

// setPrimaryClip(ClipData.newPlainText("", text)).
pub fn write(text: []const u8) void {
    const c = util.ctx() orelse return;
    const env = c.env;
    const t = env.*;
    const cm = util.system_service(env, c.activity, "clipboard") orelse return;
    defer t.DeleteLocalRef(env, cm);
    const data_cls = t.FindClass(env, "android/content/ClipData") orelse return;
    defer t.DeleteLocalRef(env, data_cls);
    const make = t.GetStaticMethodID(
        env,
        data_cls,
        "newPlainText",
        "(Ljava/lang/CharSequence;Ljava/lang/CharSequence;)Landroid/content/ClipData;",
    ) orelse return;
    const label = util.jstr(env, "") orelse return;
    defer t.DeleteLocalRef(env, label);
    const val = util.jstr(env, text) orelse return;
    defer t.DeleteLocalRef(env, val);
    var ma = [_]jni.jvalue{ .{ .l = label }, .{ .l = val } };
    const clip = t.CallStaticObjectMethodA(env, data_cls, make, &ma) orelse return;
    defer t.DeleteLocalRef(env, clip);
    const cm_cls = t.GetObjectClass(env, cm) orelse return;
    defer t.DeleteLocalRef(env, cm_cls);
    const set = t.GetMethodID(
        env,
        cm_cls,
        "setPrimaryClip",
        "(Landroid/content/ClipData;)V",
    ) orelse return;
    var sa = [_]jni.jvalue{.{ .l = clip }};
    t.CallVoidMethodA(env, cm, set, &sa);
}

// Android has no external-change poll exposed here; a remote loop polls read().
pub fn changed() bool {
    return false;
}

// getPrimaryClip().getItemAt(0).coerceToText(context).toString(), copied into buf;
// an empty span on any miss (no clip, empty clipboard).
pub fn read(buf: []u8) []const u8 {
    const empty = buf[0..0];
    const c = util.ctx() orelse return empty;
    const env = c.env;
    const t = env.*;
    const cm = util.system_service(env, c.activity, "clipboard") orelse return empty;
    defer t.DeleteLocalRef(env, cm);
    const cm_cls = t.GetObjectClass(env, cm) orelse return empty;
    defer t.DeleteLocalRef(env, cm_cls);
    const get_clip = t.GetMethodID(
        env,
        cm_cls,
        "getPrimaryClip",
        "()Landroid/content/ClipData;",
    ) orelse return empty;
    const clip = t.CallObjectMethodA(env, cm, get_clip, null) orelse return empty;
    defer t.DeleteLocalRef(env, clip);
    const clip_cls = t.GetObjectClass(env, clip) orelse return empty;
    defer t.DeleteLocalRef(env, clip_cls);
    const get_item = t.GetMethodID(
        env,
        clip_cls,
        "getItemAt",
        "(I)Landroid/content/ClipData$Item;",
    ) orelse return empty;
    var ia = [_]jni.jvalue{.{ .i = 0 }};
    const item = t.CallObjectMethodA(env, clip, get_item, &ia) orelse return empty;
    defer t.DeleteLocalRef(env, item);
    const item_cls = t.GetObjectClass(env, item) orelse return empty;
    defer t.DeleteLocalRef(env, item_cls);
    const coerce = t.GetMethodID(
        env,
        item_cls,
        "coerceToText",
        "(Landroid/content/Context;)Ljava/lang/CharSequence;",
    ) orelse return empty;
    var ca = [_]jni.jvalue{.{ .l = c.activity }};
    const cs = t.CallObjectMethodA(env, item, coerce, &ca) orelse return empty;
    defer t.DeleteLocalRef(env, cs);
    const cs_cls = t.GetObjectClass(env, cs) orelse return empty;
    defer t.DeleteLocalRef(env, cs_cls);
    const to_str = t.GetMethodID(
        env,
        cs_cls,
        "toString",
        "()Ljava/lang/String;",
    ) orelse return empty;
    const str = t.CallObjectMethodA(env, cs, to_str, null) orelse return empty;
    defer t.DeleteLocalRef(env, str);
    const chars = t.GetStringUTFChars(env, str, null) orelse return empty;
    defer t.ReleaseStringUTFChars(env, str, chars);
    const span = std.mem.span(chars);
    const n = @min(span.len, buf.len);
    @memcpy(buf[0..n], span[0..n]);
    return buf[0..n];
}
