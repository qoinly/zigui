// Minimal JNI to read the system-bar insets. Android's window insets live only
// on the Java side (no native API), but the surface is edge-to-edge on targetSdk
// 36, so the kit needs them to keep content clear of the status and navigation
// bars. The chain is:
//   activity.getWindow().getDecorView().getRootWindowInsets()
//       .getInsets(WindowInsets.Type.systemBars())  -> Insets{left,top,right,bottom}
//
// Two JNI footguns are handled here. (1) JNIEnv is doubly-indirect: the env value
// is a pointer to the function table pointer, and every call passes that same env
// back as the first argument. (2) The function table is a fixed-ABI struct of
// ~230 entries; we declare only the handful used, with sized padding runs holding
// the exact slot offsets from jni.h between them (each slot is one pointer, so a
// function pointer and a placeholder are the same width).

const std = @import("std");

pub const jobject = ?*anyopaque;
pub const jclass = jobject;
pub const jmethodID = ?*anyopaque;
pub const jfieldID = ?*anyopaque;
pub const jint = i32;

pub const jvalue = extern union {
    z: u8,
    b: i8,
    c: u16,
    s: i16,
    i: jint,
    j: i64,
    f: f32,
    d: f64,
    l: jobject,
};

// env is `JNIEnv*` in C (== const JNINativeInterface**): a pointer to the table
// pointer. Each function is reached as env.*.Fn and called as env.*.Fn(env, ...).
pub const JNIEnv = *const *const JNINativeInterface;

// The table-entry signatures used (A-variant calls take a jvalue array, never C
// varargs). GetMethodID / GetStaticMethodID / GetFieldID share LookupFn; the
// jclass/jobject distinction is erased to ?*anyopaque, so e.g. NewObjectA and
// CallStaticObjectMethodA reuse CallObjectAFn.
// FindClass, NewStringUTF.
const StrToObjFn = *const fn (JNIEnv, [*:0]const u8) callconv(.c) jobject;
const VoidFn = *const fn (JNIEnv) callconv(.c) void; // ExceptionClear
const RefFn = *const fn (JNIEnv, jobject) callconv(.c) void; // Delete{Local,Global}Ref
const ObjToObjFn = *const fn (JNIEnv, jobject) callconv(.c) jobject; // GetObjectClass, NewGlobalRef
const LookupFn = *const fn (JNIEnv, jclass, [*:0]const u8, [*:0]const u8) callconv(.c) ?*anyopaque;
const CallObjectAFn = *const fn (JNIEnv, jobject, jmethodID, ?[*]const jvalue) callconv(.c) jobject;
const CallFloatAFn = *const fn (JNIEnv, jobject, jmethodID, ?[*]const jvalue) callconv(.c) f32;
const CallVoidAFn = *const fn (JNIEnv, jobject, jmethodID, ?[*]const jvalue) callconv(.c) void;
const CallIntAFn = *const fn (JNIEnv, jclass, jmethodID, ?[*]const jvalue) callconv(.c) jint;
const CallBoolAFn = *const fn (JNIEnv, jobject, jmethodID, ?[*]const jvalue) callconv(.c) u8;
const GetIntFieldFn = *const fn (JNIEnv, jobject, jfieldID) callconv(.c) jint;
const GetFloatFieldFn = *const fn (JNIEnv, jobject, jfieldID) callconv(.c) f32;
const SetFloatFieldFn = *const fn (JNIEnv, jobject, jfieldID, f32) callconv(.c) void;
// GetStaticObjectField.
const GetObjFieldFn = *const fn (JNIEnv, jobject, jfieldID) callconv(.c) jobject;
// Reads a jstring as modified-UTF8 (the isCopy out-param is passed null).
const GetStrUTFFn = *const fn (JNIEnv, jobject, ?*u8) callconv(.c) ?[*:0]const u8;
const RelStrUTFFn = *const fn (JNIEnv, jobject, [*:0]const u8) callconv(.c) void;
// A String[] for requestPermissions: allocate, then set each element.
const NewObjectArrayFn = *const fn (JNIEnv, jint, jclass, jobject) callconv(.c) jobject;
const SetObjectArrayElementFn = *const fn (JNIEnv, jobject, jint, jobject) callconv(.c) void;
const GetArrayLengthFn = *const fn (JNIEnv, jobject) callconv(.c) jint;
const GetObjectArrayElementFn = *const fn (JNIEnv, jobject, jint) callconv(.c) jobject;

// Slot offsets are from jni.h's JNINativeInterface_; the padding-run lengths are
// the gaps (in pointer-sized slots) between the entries we use.
pub const JNINativeInterface = extern struct {
    _r0: [6]?*const anyopaque, // 0..5: reserved + GetVersion + DefineClass
    FindClass: StrToObjFn, // 6
    _r1: [10]?*const anyopaque, // 7..16
    ExceptionClear: VoidFn, // 17
    _r2: [3]?*const anyopaque, // 18..20
    NewGlobalRef: ObjToObjFn, // 21
    DeleteGlobalRef: RefFn, // 22
    DeleteLocalRef: RefFn, // 23
    _r3: [6]?*const anyopaque, // 24..29
    NewObjectA: CallObjectAFn, // 30
    GetObjectClass: ObjToObjFn, // 31
    _r4: [1]?*const anyopaque, // 32
    GetMethodID: LookupFn, // 33
    _r5: [2]?*const anyopaque, // 34..35
    CallObjectMethodA: CallObjectAFn, // 36
    _r6: [2]?*const anyopaque, // 37..38
    CallBooleanMethodA: CallBoolAFn, // 39
    _r6c: [11]?*const anyopaque, // 40..50
    CallIntMethodA: CallIntAFn, // 51
    _r6b: [5]?*const anyopaque, // 52..56
    CallFloatMethodA: CallFloatAFn, // 57
    _r7: [5]?*const anyopaque, // 58..62
    CallVoidMethodA: CallVoidAFn, // 63
    _r8: [30]?*const anyopaque, // 64..93
    GetFieldID: LookupFn, // 94
    _r9: [5]?*const anyopaque, // 95..99
    GetIntField: GetIntFieldFn, // 100
    _r10: [1]?*const anyopaque, // 101
    GetFloatField: GetFloatFieldFn, // 102
    _r11: [8]?*const anyopaque, // 103..110
    SetFloatField: SetFloatFieldFn, // 111
    _r11b: [1]?*const anyopaque, // 112
    GetStaticMethodID: LookupFn, // 113
    _r12: [2]?*const anyopaque, // 114..115
    CallStaticObjectMethodA: CallObjectAFn, // 116
    _r13: [14]?*const anyopaque, // 117..130
    CallStaticIntMethodA: CallIntAFn, // 131
    _r14: [12]?*const anyopaque, // 132..143
    GetStaticFieldID: LookupFn, // 144
    GetStaticObjectField: GetObjFieldFn, // 145
    _r15: [4]?*const anyopaque, // 146..149
    GetStaticIntField: GetIntFieldFn, // 150
    _r15b: [16]?*const anyopaque, // 151..166
    NewStringUTF: StrToObjFn, // 167
    _r16: [1]?*const anyopaque, // 168: GetStringUTFLength
    GetStringUTFChars: GetStrUTFFn, // 169
    ReleaseStringUTFChars: RelStrUTFFn, // 170
    GetArrayLength: GetArrayLengthFn, // 171
    NewObjectArray: NewObjectArrayFn, // 172
    GetObjectArrayElement: GetObjectArrayElementFn, // 173
    SetObjectArrayElement: SetObjectArrayElementFn, // 174
};

// The activity's JNIEnv + object, stored by app.zig on the main thread (where the
// lifecycle callbacks and the paint loop run). The text system reads the env to
// render glyphs through android.graphics; the IME shim calls methods on the
// activity object - both on that same thread.
var g_env: ?JNIEnv = null;
var g_activity: jobject = null;
// Recorded on the UI thread so napi can refuse calls from a worker / headless thread,
// where g_env is the wrong thread's JNIEnv (using it cross-thread is undefined).
var g_ui_tid: std.Thread.Id = 0;

pub fn set_thread(env_ptr: ?*anyopaque, activity_obj: jobject) void {
    g_env = if (env_ptr) |p| @ptrCast(@alignCast(p)) else null;
    g_activity = activity_obj;
    g_ui_tid = std.Thread.getCurrentId();
}

pub fn thread_env() ?JNIEnv {
    return g_env;
}

pub fn thread_activity() jobject {
    return g_activity;
}

pub fn on_ui_thread() bool {
    return std.Thread.getCurrentId() == g_ui_tid;
}

// libjnigraphics (a public NDK library): locks a Bitmap's pixels for direct
// native read. ALPHA_8 bitmaps give one coverage byte per pixel, rows padded to
// `stride`.
pub const ANDROID_BITMAP_FORMAT_A_8: i32 = 8;
pub const AndroidBitmapInfo = extern struct {
    width: u32 = 0,
    height: u32 = 0,
    stride: u32 = 0,
    format: i32 = 0,
    flags: u32 = 0,
};
pub extern fn AndroidBitmap_getInfo(JNIEnv, jobject, *AndroidBitmapInfo) c_int;
pub extern fn AndroidBitmap_lockPixels(JNIEnv, jobject, *?*anyopaque) c_int;
pub extern fn AndroidBitmap_unlockPixels(JNIEnv, jobject) c_int;

pub const Insets = struct { left: i32 = 0, top: i32 = 0, right: i32 = 0, bottom: i32 = 0 };

// Reads the system-bar insets in pixels, or null when unavailable (the view is
// not laid out, or the API predates the systemBars type). A null return leaves
// the caller's last-known insets in place rather than snapping to zero.
pub fn safe_insets(env_ptr: ?*anyopaque, activity: jobject) ?Insets {
    const env: JNIEnv = @ptrCast(@alignCast(env_ptr orelse return null));
    const obj = activity orelse return null;
    const t = env.*;
    t.ExceptionClear(env); // start from a clean slate

    const activity_cls = t.GetObjectClass(env, obj) orelse return null;
    defer t.DeleteLocalRef(env, activity_cls);
    const get_window =
        t.GetMethodID(env, activity_cls, "getWindow", "()Landroid/view/Window;") orelse return null;
    const window = t.CallObjectMethodA(env, obj, get_window, null) orelse return null;
    defer t.DeleteLocalRef(env, window);

    const window_cls = t.GetObjectClass(env, window) orelse return null;
    defer t.DeleteLocalRef(env, window_cls);
    const get_decor =
        t.GetMethodID(env, window_cls, "getDecorView", "()Landroid/view/View;") orelse return null;
    const decor = t.CallObjectMethodA(env, window, get_decor, null) orelse return null;
    defer t.DeleteLocalRef(env, decor);

    const view_cls = t.GetObjectClass(env, decor) orelse return null;
    defer t.DeleteLocalRef(env, view_cls);
    const get_root = t.GetMethodID(
        env,
        view_cls,
        "getRootWindowInsets",
        "()Landroid/view/WindowInsets;",
    ) orelse return null;
    // Null before the first layout pass: the view simply has no insets to report.
    const wi = t.CallObjectMethodA(env, decor, get_root, null) orelse return null;
    defer t.DeleteLocalRef(env, wi);

    // WindowInsets.Type.systemBars() is API 30+; on older devices FindClass fails
    // and sets an exception, so clear it and degrade to no insets.
    const type_cls = t.FindClass(env, "android/view/WindowInsets$Type") orelse {
        t.ExceptionClear(env);
        return null;
    };
    defer t.DeleteLocalRef(env, type_cls);
    const system_bars = t.GetStaticMethodID(env, type_cls, "systemBars", "()I") orelse return null;
    const mask = t.CallStaticIntMethodA(env, type_cls, system_bars, null);

    const wi_cls = t.GetObjectClass(env, wi) orelse return null;
    defer t.DeleteLocalRef(env, wi_cls);
    const get_insets =
        t.GetMethodID(env, wi_cls, "getInsets", "(I)Landroid/graphics/Insets;") orelse return null;
    var arg = [_]jvalue{.{ .i = mask }};
    const ins = t.CallObjectMethodA(env, wi, get_insets, &arg) orelse return null;
    defer t.DeleteLocalRef(env, ins);

    const ins_cls = t.GetObjectClass(env, ins) orelse return null;
    defer t.DeleteLocalRef(env, ins_cls);
    const fl = t.GetFieldID(env, ins_cls, "left", "I") orelse return null;
    const ft = t.GetFieldID(env, ins_cls, "top", "I") orelse return null;
    const fr = t.GetFieldID(env, ins_cls, "right", "I") orelse return null;
    const fb = t.GetFieldID(env, ins_cls, "bottom", "I") orelse return null;
    const out = Insets{
        .left = t.GetIntField(env, ins, fl),
        .top = t.GetIntField(env, ins, ft),
        .right = t.GetIntField(env, ins, fr),
        .bottom = t.GetIntField(env, ins, fb),
    };
    // Android guarantees non-negative insets; a negative here is a torn FFI read.
    std.debug.assert(out.left >= 0 and out.top >= 0 and out.right >= 0 and out.bottom >= 0);
    return out;
}
