// Outbound intents: open a url in the browser, or share text through the chooser.

const std = @import("std");
const jni = @import("../jni.zig");
const util = @import("util.zig");

// new Intent(ACTION_VIEW, Uri.parse(url)) -> startActivity, opening the url in the
// browser (or whichever app claims it).
pub fn open_url(url: []const u8) void {
    std.debug.assert(url.len > 0);
    const c = util.ctx() orelse return;
    const env = c.env;
    const t = env.*;
    const uri_cls = t.FindClass(env, "android/net/Uri") orelse return;
    defer t.DeleteLocalRef(env, uri_cls);
    const parse = t.GetStaticMethodID(
        env,
        uri_cls,
        "parse",
        "(Ljava/lang/String;)Landroid/net/Uri;",
    ) orelse return;
    const url_str = util.jstr(env, url) orelse return;
    defer t.DeleteLocalRef(env, url_str);
    var pa = [_]jni.jvalue{.{ .l = url_str }};
    const uri = t.CallStaticObjectMethodA(env, uri_cls, parse, &pa) orelse return;
    defer t.DeleteLocalRef(env, uri);
    const intent_cls = t.FindClass(env, "android/content/Intent") orelse return;
    defer t.DeleteLocalRef(env, intent_cls);
    const ctor = t.GetMethodID(
        env,
        intent_cls,
        "<init>",
        "(Ljava/lang/String;Landroid/net/Uri;)V",
    ) orelse return;
    const action = util.jstr(env, "android.intent.action.VIEW") orelse return;
    defer t.DeleteLocalRef(env, action);
    var ia = [_]jni.jvalue{ .{ .l = action }, .{ .l = uri } };
    const intent = t.NewObjectA(env, intent_cls, ctor, &ia) orelse return;
    defer t.DeleteLocalRef(env, intent);
    util.start_activity(env, c.activity, intent);
}

// new Intent(ACTION_SEND).setType("text/plain").putExtra(EXTRA_TEXT, text), wrapped
// in a chooser so the user picks the target app.
pub fn share_text(text: []const u8) void {
    std.debug.assert(text.len > 0);
    const c = util.ctx() orelse return;
    const env = c.env;
    const t = env.*;
    const intent_cls = t.FindClass(env, "android/content/Intent") orelse return;
    defer t.DeleteLocalRef(env, intent_cls);
    const ctor = t.GetMethodID(env, intent_cls, "<init>", "(Ljava/lang/String;)V") orelse return;
    const action = util.jstr(env, "android.intent.action.SEND") orelse return;
    defer t.DeleteLocalRef(env, action);
    var aa = [_]jni.jvalue{.{ .l = action }};
    const intent = t.NewObjectA(env, intent_cls, ctor, &aa) orelse return;
    defer t.DeleteLocalRef(env, intent);

    const set_type = t.GetMethodID(
        env,
        intent_cls,
        "setType",
        "(Ljava/lang/String;)Landroid/content/Intent;",
    ) orelse return;
    const mime = util.jstr(env, "text/plain") orelse return;
    defer t.DeleteLocalRef(env, mime);
    var ta = [_]jni.jvalue{.{ .l = mime }};
    if (t.CallObjectMethodA(env, intent, set_type, &ta)) |r| t.DeleteLocalRef(env, r);

    const put_extra = t.GetMethodID(
        env,
        intent_cls,
        "putExtra",
        "(Ljava/lang/String;Ljava/lang/String;)Landroid/content/Intent;",
    ) orelse return;
    const key = util.jstr(env, "android.intent.extra.TEXT") orelse return;
    defer t.DeleteLocalRef(env, key);
    const val = util.jstr(env, text) orelse return;
    defer t.DeleteLocalRef(env, val);
    var ea = [_]jni.jvalue{ .{ .l = key }, .{ .l = val } };
    if (t.CallObjectMethodA(env, intent, put_extra, &ea)) |r| t.DeleteLocalRef(env, r);

    const make = t.GetStaticMethodID(
        env,
        intent_cls,
        "createChooser",
        "(Landroid/content/Intent;Ljava/lang/CharSequence;)Landroid/content/Intent;",
    ) orelse return;
    var ma = [_]jni.jvalue{ .{ .l = intent }, .{ .l = null } };
    const chooser = t.CallStaticObjectMethodA(env, intent_cls, make, &ma) orelse return;
    defer t.DeleteLocalRef(env, chooser);
    util.start_activity(env, c.activity, chooser);
}
