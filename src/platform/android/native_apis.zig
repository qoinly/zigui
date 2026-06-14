// Platform services an app reaches at runtime: haptics, open-url, share,
// notifications, and the clipboard. Each is a framework class reachable from
// native through JNI on the activity (a Context), so none needs app Java - the
// safe_insets / window_props pattern. Calls run on the paint thread, which for a
// NativeActivity is the UI thread, where startActivity and the managers expect to
// be touched. Failures degrade to a silent no-op (orelse return), never a crash.

const std = @import("std");
const jni = @import("jni.zig");

const JNIEnv = jni.JNIEnv;

// A short scratch span for a Java string; titles, urls, and shared text are small.
const STR_MAX: usize = 1024;

const Ctx = struct { env: JNIEnv, activity: jni.jobject };

fn ctx() ?Ctx {
    const env = jni.thread_env() orelse return null;
    const activity = jni.thread_activity() orelse return null;
    env.*.ExceptionClear(env); // start from a clean exception slate
    return .{ .env = env, .activity = activity };
}

// A NUL-terminated Java String from a UTF-8 slice (clamped to STR_MAX).
fn jstr(env: JNIEnv, s: []const u8) ?jni.jobject {
    std.debug.assert(s.len <= STR_MAX); // callers pass small labels/urls/text
    var buf: [STR_MAX + 1]u8 = undefined;
    const n = @min(s.len, STR_MAX);
    @memcpy(buf[0..n], s[0..n]);
    buf[n] = 0;
    return env.*.NewStringUTF(env, @ptrCast(&buf));
}

// Context.getSystemService(name) - the manager objects (vibrator, notification,
// clipboard). The caller owns the returned local ref.
fn system_service(env: JNIEnv, activity: jni.jobject, name: []const u8) ?jni.jobject {
    const t = env.*;
    const act_cls = t.GetObjectClass(env, activity) orelse return null;
    defer t.DeleteLocalRef(env, act_cls);
    const mid = t.GetMethodID(
        env,
        act_cls,
        "getSystemService",
        "(Ljava/lang/String;)Ljava/lang/Object;",
    ) orelse return null;
    const name_str = jstr(env, name) orelse return null;
    defer t.DeleteLocalRef(env, name_str);
    var arg = [_]jni.jvalue{.{ .l = name_str }};
    return t.CallObjectMethodA(env, activity, mid, &arg);
}

fn start_activity(env: JNIEnv, activity: jni.jobject, intent: jni.jobject) void {
    std.debug.assert(intent != null);
    const t = env.*;
    const act_cls = t.GetObjectClass(env, activity) orelse return;
    defer t.DeleteLocalRef(env, act_cls);
    const start = t.GetMethodID(
        env,
        act_cls,
        "startActivity",
        "(Landroid/content/Intent;)V",
    ) orelse return;
    var a = [_]jni.jvalue{.{ .l = intent }};
    t.CallVoidMethodA(env, activity, start, &a);
}

// VibrationEffect.createOneShot(ms, DEFAULT_AMPLITUDE) -> Vibrator.vibrate(effect).
pub fn vibrate(ms: i64) void {
    std.debug.assert(ms > 0); // a zero-length buzz is a caller bug, not a request
    const c = ctx() orelse return;
    const env = c.env;
    const t = env.*;
    const vib = system_service(env, c.activity, "vibrator") orelse return;
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

// new Intent(ACTION_VIEW, Uri.parse(url)) -> startActivity, opening the url in the
// browser (or whichever app claims it).
pub fn open_url(url: []const u8) void {
    std.debug.assert(url.len > 0);
    const c = ctx() orelse return;
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
    const url_str = jstr(env, url) orelse return;
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
    const action = jstr(env, "android.intent.action.VIEW") orelse return;
    defer t.DeleteLocalRef(env, action);
    var ia = [_]jni.jvalue{ .{ .l = action }, .{ .l = uri } };
    const intent = t.NewObjectA(env, intent_cls, ctor, &ia) orelse return;
    defer t.DeleteLocalRef(env, intent);
    start_activity(env, c.activity, intent);
}

// new Intent(ACTION_SEND).setType("text/plain").putExtra(EXTRA_TEXT, text), wrapped
// in a chooser so the user picks the target app.
pub fn share_text(text: []const u8) void {
    std.debug.assert(text.len > 0);
    const c = ctx() orelse return;
    const env = c.env;
    const t = env.*;
    const intent_cls = t.FindClass(env, "android/content/Intent") orelse return;
    defer t.DeleteLocalRef(env, intent_cls);
    const ctor = t.GetMethodID(env, intent_cls, "<init>", "(Ljava/lang/String;)V") orelse return;
    const action = jstr(env, "android.intent.action.SEND") orelse return;
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
    const mime = jstr(env, "text/plain") orelse return;
    defer t.DeleteLocalRef(env, mime);
    var ta = [_]jni.jvalue{.{ .l = mime }};
    if (t.CallObjectMethodA(env, intent, set_type, &ta)) |r| t.DeleteLocalRef(env, r);

    const put_extra = t.GetMethodID(
        env,
        intent_cls,
        "putExtra",
        "(Ljava/lang/String;Ljava/lang/String;)Landroid/content/Intent;",
    ) orelse return;
    const key = jstr(env, "android.intent.extra.TEXT") orelse return;
    defer t.DeleteLocalRef(env, key);
    const val = jstr(env, text) orelse return;
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
    start_activity(env, c.activity, chooser);
}

// Posts a notification on a default channel. On API 33+ POST_NOTIFICATIONS is a
// runtime permission: an ungranted first call requests it (the system dialog) and
// posts nothing; once granted, the next call posts.
pub fn notify(title: []const u8, text: []const u8) void {
    std.debug.assert(title.len > 0);
    const c = ctx() orelse return;
    const env = c.env;
    const t = env.*;
    if (!granted_jni(env, c.activity, POST_NOTIFICATIONS)) {
        request_jni(env, c.activity, POST_NOTIFICATIONS);
        return;
    }
    const mgr = system_service(env, c.activity, "notification") orelse return;
    defer t.DeleteLocalRef(env, mgr);
    const mgr_cls = t.GetObjectClass(env, mgr) orelse return;
    defer t.DeleteLocalRef(env, mgr_cls);

    const chan_id = jstr(env, "zigui") orelse return;
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
    const title_str = jstr(env, title) orelse return null;
    defer t.DeleteLocalRef(env, title_str);
    var ta = [_]jni.jvalue{.{ .l = title_str }};
    if (t.CallObjectMethodA(env, builder, set_title, &ta)) |r| t.DeleteLocalRef(env, r);

    const set_text = t.GetMethodID(
        env,
        b_cls,
        "setContentText",
        "(Ljava/lang/CharSequence;)Landroid/app/Notification$Builder;",
    ) orelse return null;
    const text_str = jstr(env, text) orelse return null;
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

const POST_NOTIFICATIONS = "android.permission.POST_NOTIFICATIONS";

// Whether a runtime permission is granted now (Context.checkSelfPermission == 0).
// An immediate-mode app polls this each frame instead of awaiting a result
// callback. No system here off Android, so callers there see everything granted.
pub fn permission_granted(name: []const u8) bool {
    std.debug.assert(name.len > 0);
    const c = ctx() orelse return false;
    return granted_jni(c.env, c.activity, name);
}

// Raises the system grant dialog for a permission; the answer is read back through
// permission_granted on a later frame, not awaited here.
pub fn request_permission(name: []const u8) void {
    std.debug.assert(name.len > 0);
    const c = ctx() orelse return;
    request_jni(c.env, c.activity, name);
}

// Pre-API-23 has no checkSelfPermission (permissions are install-time), so a
// missing method reads as granted.
fn granted_jni(env: JNIEnv, activity: jni.jobject, name: []const u8) bool {
    const t = env.*;
    const act_cls = t.GetObjectClass(env, activity) orelse return false;
    defer t.DeleteLocalRef(env, act_cls);
    const check = t.GetMethodID(
        env,
        act_cls,
        "checkSelfPermission",
        "(Ljava/lang/String;)I",
    ) orelse return true;
    const perm = jstr(env, name) orelse return false;
    defer t.DeleteLocalRef(env, perm);
    var a = [_]jni.jvalue{.{ .l = perm }};
    return t.CallIntMethodA(env, activity, check, &a) == 0; // 0 = PERMISSION_GRANTED
}

// Activity.requestPermissions(new String[]{name}, 0) - raises the system grant
// dialog; the result is handled by Android, not awaited here.
fn request_jni(env: JNIEnv, activity: jni.jobject, name: []const u8) void {
    const t = env.*;
    const str_cls = t.FindClass(env, "java/lang/String") orelse return;
    defer t.DeleteLocalRef(env, str_cls);
    const perm = jstr(env, name) orelse return;
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

// ClipboardManager.setPrimaryClip(ClipData.newPlainText("", text)).
pub fn clipboard_write(text: []const u8) void {
    const c = ctx() orelse return;
    const env = c.env;
    const t = env.*;
    const cm = system_service(env, c.activity, "clipboard") orelse return;
    defer t.DeleteLocalRef(env, cm);
    const data_cls = t.FindClass(env, "android/content/ClipData") orelse return;
    defer t.DeleteLocalRef(env, data_cls);
    const make = t.GetStaticMethodID(
        env,
        data_cls,
        "newPlainText",
        "(Ljava/lang/CharSequence;Ljava/lang/CharSequence;)Landroid/content/ClipData;",
    ) orelse return;
    const label = jstr(env, "") orelse return;
    defer t.DeleteLocalRef(env, label);
    const val = jstr(env, text) orelse return;
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

// getPrimaryClip().getItemAt(0).coerceToText(context).toString(), copied into buf;
// an empty span on any miss (no clip, empty clipboard).
pub fn clipboard_read(buf: []u8) []const u8 {
    const empty = buf[0..0];
    const c = ctx() orelse return empty;
    const env = c.env;
    const t = env.*;
    const cm = system_service(env, c.activity, "clipboard") orelse return empty;
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

// The request id startActivityForResult tags the pick with; the app's
// onActivityResult must echo it back so this is the only result it reads.
pub const FILE_REQUEST_CODE: jni.jint = 0x5A16;

// The picked file's text content, awaiting the app's one take_picked_file. A whole
// file is large, so this caps the preview rather than allocating per pick.
const FILE_MAX: usize = 4096;
var g_file_buf: [FILE_MAX]u8 = undefined;
var g_file_len: usize = 0;
var g_file_valid: bool = false;

// Launches the system document picker (ACTION_OPEN_DOCUMENT). The chosen file's
// text arrives later through on_native_file via the activity's onActivityResult.
pub fn pick_file() void {
    const c = ctx() orelse return;
    const env = c.env;
    const t = env.*;
    const intent_cls = t.FindClass(env, "android/content/Intent") orelse return;
    defer t.DeleteLocalRef(env, intent_cls);
    const ctor = t.GetMethodID(env, intent_cls, "<init>", "(Ljava/lang/String;)V") orelse return;
    const action = jstr(env, "android.intent.action.OPEN_DOCUMENT") orelse return;
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
    const cat = jstr(env, "android.intent.category.OPENABLE") orelse return;
    defer t.DeleteLocalRef(env, cat);
    var cata = [_]jni.jvalue{.{ .l = cat }};
    if (t.CallObjectMethodA(env, intent, add_cat, &cata)) |r| t.DeleteLocalRef(env, r);

    const set_type = t.GetMethodID(
        env,
        intent_cls,
        "setType",
        "(Ljava/lang/String;)Landroid/content/Intent;",
    ) orelse return;
    const mime = jstr(env, "*/*") orelse return;
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
// (the erased env + Java String), the IME-sink shape. It becomes the next
// take_picked_file return.
pub fn on_native_file(env_ptr: *anyopaque, content: ?*anyopaque) void {
    const env: JNIEnv = @ptrCast(@alignCast(env_ptr));
    const ref = content orelse return;
    const t = env.*;
    const chars = t.GetStringUTFChars(env, ref, null) orelse return;
    defer t.ReleaseStringUTFChars(env, ref, chars);
    const span = std.mem.span(chars);
    g_file_len = @min(span.len, FILE_MAX);
    // A byte-count truncation could split a UTF-8 codepoint; back off to its start.
    while (g_file_len > 0 and g_file_len < span.len and (span[g_file_len] & 0xc0) == 0x80) {
        g_file_len -= 1;
    }
    @memcpy(g_file_buf[0..g_file_len], span[0..g_file_len]);
    g_file_valid = true;
    std.debug.assert(g_file_len <= FILE_MAX);
}

// The app reads a just-picked file once (consume-once, the navigator take_result
// shape); null when nothing was picked since the last read.
pub fn take_picked_file(buf: []u8) ?[]const u8 {
    if (!g_file_valid) return null;
    std.debug.assert(g_file_len <= g_file_buf.len);
    g_file_valid = false;
    const n = @min(g_file_len, buf.len);
    @memcpy(buf[0..n], g_file_buf[0..n]);
    return buf[0..n];
}
