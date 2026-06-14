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
// varargs). GetMethodID / GetStaticMethodID / GetFieldID share one shape.
const FindClassFn = *const fn (JNIEnv, [*:0]const u8) callconv(.c) jclass;
const ExceptionClearFn = *const fn (JNIEnv) callconv(.c) void;
const DeleteLocalRefFn = *const fn (JNIEnv, jobject) callconv(.c) void;
const GetObjectClassFn = *const fn (JNIEnv, jobject) callconv(.c) jclass;
const LookupFn = *const fn (JNIEnv, jclass, [*:0]const u8, [*:0]const u8) callconv(.c) ?*anyopaque;
const CallObjectAFn = *const fn (JNIEnv, jobject, jmethodID, ?[*]const jvalue) callconv(.c) jobject;
const GetIntFieldFn = *const fn (JNIEnv, jobject, jfieldID) callconv(.c) jint;
const CallStaticIntAFn = *const fn (JNIEnv, jclass, jmethodID, ?[*]const jvalue) callconv(.c) jint;

// Slot offsets are from jni.h's JNINativeInterface_; the padding-run lengths are
// the gaps (in pointer-sized slots) between the entries we use.
pub const JNINativeInterface = extern struct {
    _r0: [6]?*const anyopaque, // 0..5: reserved + GetVersion + DefineClass
    FindClass: FindClassFn, // 6
    _r1: [10]?*const anyopaque, // 7..16
    ExceptionClear: ExceptionClearFn, // 17
    _r2: [5]?*const anyopaque, // 18..22
    DeleteLocalRef: DeleteLocalRefFn, // 23
    _r3: [7]?*const anyopaque, // 24..30
    GetObjectClass: GetObjectClassFn, // 31
    _r4: [1]?*const anyopaque, // 32
    GetMethodID: LookupFn, // 33
    _r5: [2]?*const anyopaque, // 34..35
    CallObjectMethodA: CallObjectAFn, // 36
    _r6: [57]?*const anyopaque, // 37..93
    GetFieldID: LookupFn, // 94
    _r7: [5]?*const anyopaque, // 95..99
    GetIntField: GetIntFieldFn, // 100
    _r8: [12]?*const anyopaque, // 101..112
    GetStaticMethodID: LookupFn, // 113
    _r9: [17]?*const anyopaque, // 114..130
    CallStaticIntMethodA: CallStaticIntAFn, // 131
};

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
