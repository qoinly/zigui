// Notifications. Posts on a default channel; on API 33+ POST_NOTIFICATIONS is a
// runtime permission, so an ungranted first call requests it (the system dialog)
// and posts nothing - once granted, the next call posts.

const std = @import("std");
const jni = @import("../jni.zig");
const util = @import("util.zig");
const permissions = @import("permissions.zig");

const JNIEnv = util.JNIEnv;

pub fn post(title: []const u8, text: []const u8) void {
    std.debug.assert(title.len > 0);
    const c = util.ctx() orelse return;
    const env = c.env;
    const t = env.*;
    if (!permissions.granted_jni(env, c.activity, permissions.POST_NOTIFICATIONS)) {
        permissions.request_jni(env, c.activity, permissions.POST_NOTIFICATIONS);
        return;
    }
    const mgr = util.system_service(env, c.activity, "notification") orelse return;
    defer t.DeleteLocalRef(env, mgr);
    const mgr_cls = t.GetObjectClass(env, mgr) orelse return;
    defer t.DeleteLocalRef(env, mgr_cls);

    const chan_id = util.jstr(env, "zigui") orelse return;
    defer t.DeleteLocalRef(env, chan_id);
    if (!create_channel(env, mgr, mgr_cls, chan_id)) return;

    const notification = build_notification(env, c.activity, chan_id, title, text) orelse return;
    defer t.DeleteLocalRef(env, notification);
    const notify_m = t.GetMethodID(
        env,
        mgr_cls,
        "notify",
        "(ILandroid/app/Notification;)V",
    ) orelse return;
    var na = [_]jni.jvalue{ .{ .i = 1 }, .{ .l = notification } };
    t.CallVoidMethodA(env, mgr, notify_m, &na);
}

// new NotificationChannel(id, id, IMPORTANCE_DEFAULT) -> createNotificationChannel.
// Re-creating an existing channel is a no-op, so this runs safely each post.
fn create_channel(env: JNIEnv, mgr: jni.jobject, mgr_cls: jni.jobject, id: jni.jobject) bool {
    const t = env.*;
    const chan_cls = t.FindClass(env, "android/app/NotificationChannel") orelse return false;
    defer t.DeleteLocalRef(env, chan_cls);
    const ctor = t.GetMethodID(
        env,
        chan_cls,
        "<init>",
        "(Ljava/lang/String;Ljava/lang/CharSequence;I)V",
    ) orelse return false;
    var ca = [_]jni.jvalue{ .{ .l = id }, .{ .l = id }, .{ .i = 3 } }; // 3 = IMPORTANCE_DEFAULT
    const chan = t.NewObjectA(env, chan_cls, ctor, &ca) orelse return false;
    defer t.DeleteLocalRef(env, chan);
    const create = t.GetMethodID(
        env,
        mgr_cls,
        "createNotificationChannel",
        "(Landroid/app/NotificationChannel;)V",
    ) orelse return false;
    var aa = [_]jni.jvalue{.{ .l = chan }};
    t.CallVoidMethodA(env, mgr, create, &aa);
    return true;
}

// Notification.Builder(context, channel).setContentTitle/Text.setSmallIcon.build.
fn build_notification(
    env: JNIEnv,
    activity: jni.jobject,
    chan_id: jni.jobject,
    title: []const u8,
    text: []const u8,
) ?jni.jobject {
    const t = env.*;
    const b_cls = t.FindClass(env, "android/app/Notification$Builder") orelse return null;
    defer t.DeleteLocalRef(env, b_cls);
    const ctor = t.GetMethodID(
        env,
        b_cls,
        "<init>",
        "(Landroid/content/Context;Ljava/lang/String;)V",
    ) orelse return null;
    var ba = [_]jni.jvalue{ .{ .l = activity }, .{ .l = chan_id } };
    const builder = t.NewObjectA(env, b_cls, ctor, &ba) orelse return null;
    defer t.DeleteLocalRef(env, builder);

    const set_title = t.GetMethodID(
        env,
        b_cls,
        "setContentTitle",
        "(Ljava/lang/CharSequence;)Landroid/app/Notification$Builder;",
    ) orelse return null;
    const title_str = util.jstr(env, title) orelse return null;
    defer t.DeleteLocalRef(env, title_str);
    var ta = [_]jni.jvalue{.{ .l = title_str }};
    if (t.CallObjectMethodA(env, builder, set_title, &ta)) |r| t.DeleteLocalRef(env, r);

    const set_text = t.GetMethodID(
        env,
        b_cls,
        "setContentText",
        "(Ljava/lang/CharSequence;)Landroid/app/Notification$Builder;",
    ) orelse return null;
    const text_str = util.jstr(env, text) orelse return null;
    defer t.DeleteLocalRef(env, text_str);
    var xa = [_]jni.jvalue{.{ .l = text_str }};
    if (t.CallObjectMethodA(env, builder, set_text, &xa)) |r| t.DeleteLocalRef(env, r);

    const set_icon = t.GetMethodID(
        env,
        b_cls,
        "setSmallIcon",
        "(I)Landroid/app/Notification$Builder;",
    ) orelse return null;
    var ica = [_]jni.jvalue{.{ .i = framework_info_icon(env) }};
    if (t.CallObjectMethodA(env, builder, set_icon, &ica)) |r| t.DeleteLocalRef(env, r);

    const build = t.GetMethodID(
        env,
        b_cls,
        "build",
        "()Landroid/app/Notification;",
    ) orelse return null;
    return t.CallObjectMethodA(env, builder, build, null);
}

// android.R.drawable.ic_dialog_info - a framework icon, so the library ships none.
fn framework_info_icon(env: JNIEnv) jni.jint {
    const t = env.*;
    const cls = t.FindClass(env, "android/R$drawable") orelse return 0;
    defer t.DeleteLocalRef(env, cls);
    const fid = t.GetStaticFieldID(env, cls, "ic_dialog_info", "I") orelse return 0;
    return t.GetStaticIntField(env, cls, fid);
}
