// Hardware-backed local secret store: a stable 32-byte key per alias, sealed by an
// AndroidKeyStore key and persisted (sealed) in the app's files dir. The crypto lives
// in ZiguiSecureStore.java; this is the one JNI call into it. False when the key could
// not be read or created (class not bundled, keystore unavailable) - the caller then
// treats secrets as unavailable rather than inventing an unstable key.

const jni = @import("../jni.zig");
const util = @import("util.zig");

pub fn get_or_create_key(alias: []const u8, out: *[32]u8) bool {
    const c = util.ctx() orelse return false;
    const env = c.env;
    const t = env.*;

    const cls = util.load_app_class(env, c.activity, "io.qoinly.zigui.ZiguiSecureStore") orelse return false;
    defer t.DeleteLocalRef(env, cls);
    const mid = t.GetStaticMethodID(
        env,
        cls,
        "getOrCreateKey",
        "(Landroid/content/Context;Ljava/lang/String;)[B",
    ) orelse return false;

    const jalias = util.jstr(env, alias) orelse return false;
    defer t.DeleteLocalRef(env, jalias);
    var a = [_]jni.jvalue{ .{ .l = c.activity }, .{ .l = jalias } };
    const arr = t.CallStaticObjectMethodA(env, cls, mid, &a) orelse {
        t.ExceptionClear(env); // a thrown exception leaves the slot pending; clear it
        return false;
    };
    defer t.DeleteLocalRef(env, arr);

    if (t.GetArrayLength(env, arr) != 32) return false;
    t.GetByteArrayRegion(env, arr, 0, 32, out);
    return true;
}
