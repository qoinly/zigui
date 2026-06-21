// Device status: battery level/charging (BatteryManager) and connectivity
// (ConnectivityManager). Read-only queries an app polls; a miss reads as the safe
// default (0% / not charging / offline).

const std = @import("std");
const jni = @import("../jni.zig");
const util = @import("util.zig");

const JNIEnv = util.JNIEnv;

// BatteryManager.getIntProperty(BATTERY_PROPERTY_CAPACITY) - the charge percent.
pub fn battery_level() u8 {
    const c = util.ctx() orelse return 0;
    const env = c.env;
    const t = env.*;
    const bm = util.system_service(env, c.activity, "batterymanager") orelse return 0;
    defer t.DeleteLocalRef(env, bm);
    const bm_cls = t.GetObjectClass(env, bm) orelse return 0;
    defer t.DeleteLocalRef(env, bm_cls);
    const prop = t.GetMethodID(env, bm_cls, "getIntProperty", "(I)I") orelse return 0;
    var a = [_]jni.jvalue{.{ .i = 4 }}; // 4 = BATTERY_PROPERTY_CAPACITY
    const v = t.CallIntMethodA(env, bm, prop, &a);
    if (v < 0) return 0; // the property is unknown on this device
    return @intCast(@min(v, 100));
}

// BatteryManager.isCharging() (API 23+).
pub fn charging() bool {
    const c = util.ctx() orelse return false;
    const env = c.env;
    const t = env.*;
    const bm = util.system_service(env, c.activity, "batterymanager") orelse return false;
    defer t.DeleteLocalRef(env, bm);
    const bm_cls = t.GetObjectClass(env, bm) orelse return false;
    defer t.DeleteLocalRef(env, bm_cls);
    const m = t.GetMethodID(env, bm_cls, "isCharging", "()Z") orelse return false;
    return t.CallBooleanMethodA(env, bm, m, null) != 0;
}

// Whether the active network can reach the internet (NET_CAPABILITY_INTERNET).
pub fn online() bool {
    const caps = active_caps() orelse return false;
    const env = caps.env;
    defer env.*.DeleteLocalRef(env, caps.obj);
    return caps_has(env, caps.obj, "hasCapability", 12); // 12 = NET_CAPABILITY_INTERNET
}

// 0 = none, 1 = wifi, 2 = cellular, 3 = other; the facade maps it to NetworkType.
pub fn network_code() u8 {
    const caps = active_caps() orelse return 0;
    const env = caps.env;
    defer env.*.DeleteLocalRef(env, caps.obj);
    if (caps_has(env, caps.obj, "hasTransport", 1)) return 1; // 1 = TRANSPORT_WIFI
    if (caps_has(env, caps.obj, "hasTransport", 0)) return 2; // 0 = TRANSPORT_CELLULAR
    return 3; // a network with neither transport (ethernet, vpn, ...)
}

const Caps = struct { env: JNIEnv, obj: jni.jobject };

// ConnectivityManager.getActiveNetwork() -> getNetworkCapabilities(). Null when
// offline. The caller owns the returned NetworkCapabilities local ref.
fn active_caps() ?Caps {
    const c = util.ctx() orelse return null;
    const env = c.env;
    const t = env.*;
    const cm = util.system_service(env, c.activity, "connectivity") orelse return null;
    defer t.DeleteLocalRef(env, cm);
    const cm_cls = t.GetObjectClass(env, cm) orelse return null;
    defer t.DeleteLocalRef(env, cm_cls);
    const get_net = t.GetMethodID(
        env,
        cm_cls,
        "getActiveNetwork",
        "()Landroid/net/Network;",
    ) orelse return null;
    const net = t.CallObjectMethodA(env, cm, get_net, null) orelse return null;
    defer t.DeleteLocalRef(env, net);
    const get_caps = t.GetMethodID(
        env,
        cm_cls,
        "getNetworkCapabilities",
        "(Landroid/net/Network;)Landroid/net/NetworkCapabilities;",
    ) orelse return null;
    var a = [_]jni.jvalue{.{ .l = net }};
    const caps = t.CallObjectMethodA(env, cm, get_caps, &a) orelse return null;
    return .{ .env = env, .obj = caps };
}

fn caps_has(env: JNIEnv, caps: jni.jobject, method: [*:0]const u8, code: jni.jint) bool {
    const t = env.*;
    const cls = t.GetObjectClass(env, caps) orelse return false;
    defer t.DeleteLocalRef(env, cls);
    const m = t.GetMethodID(env, cls, method, "(I)Z") orelse return false;
    var a = [_]jni.jvalue{.{ .i = code }};
    return t.CallBooleanMethodA(env, caps, m, &a) != 0;
}

// PackageManager.getPackageInfo(packageName, 0).versionName copied into buf - the app's
// own manifest versionName; empty when it is null (a build without one). Reading the
// own package never throws NameNotFoundException, so no exception check is needed.
pub fn app_version(buf: []u8) []const u8 {
    const c = util.ctx() orelse return "";
    const env = c.env;
    const t = env.*;
    const act_cls = t.GetObjectClass(env, c.activity) orelse return "";
    defer t.DeleteLocalRef(env, act_cls);

    const get_pm = t.GetMethodID(
        env,
        act_cls,
        "getPackageManager",
        "()Landroid/content/pm/PackageManager;",
    ) orelse return "";
    const pm = t.CallObjectMethodA(env, c.activity, get_pm, null) orelse return "";
    defer t.DeleteLocalRef(env, pm);
    const get_name = t.GetMethodID(env, act_cls, "getPackageName", "()Ljava/lang/String;") orelse
        return "";
    const pkg = t.CallObjectMethodA(env, c.activity, get_name, null) orelse return "";
    defer t.DeleteLocalRef(env, pkg);

    const pm_cls = t.GetObjectClass(env, pm) orelse return "";
    defer t.DeleteLocalRef(env, pm_cls);
    const get_info = t.GetMethodID(
        env,
        pm_cls,
        "getPackageInfo",
        "(Ljava/lang/String;I)Landroid/content/pm/PackageInfo;",
    ) orelse return "";
    var ia = [_]jni.jvalue{ .{ .l = pkg }, .{ .i = 0 } };
    const info = t.CallObjectMethodA(env, pm, get_info, &ia) orelse return "";
    defer t.DeleteLocalRef(env, info);

    const info_cls = t.GetObjectClass(env, info) orelse return "";
    defer t.DeleteLocalRef(env, info_cls);
    const fid = t.GetFieldID(env, info_cls, "versionName", "Ljava/lang/String;") orelse return "";
    const vname = t.GetObjectField(env, info, fid) orelse return "";
    defer t.DeleteLocalRef(env, vname);
    return util.read_jstr(env, vname, buf);
}
