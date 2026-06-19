// Broadcast subscription: receive system/app broadcasts the app subscribes to. The
// shipped receivers forward each onReceive (the action + the intent extras as a Java
// String[] of alternating key, value, with SMS decoded to address/body and the data
// URI under "data") here. A context-registered receiver delivers on the app's MAIN
// thread (the paint thread), so the foreground store is single-threaded and needs no
// atomic publish; the static receiver runs headless and only dispatches.

const std = @import("std");
const jni = @import("../jni.zig");
const util = @import("util.zig");
const kv = @import("../../../napi/broadcast.zig");
const headless = @import("../../../napi/headless.zig");

const JNIEnv = util.JNIEnv;

const MAX_PAIRS = 32; // a broadcast's extras (ACTION_BATTERY_CHANGED carries ~15)
const KV_STORAGE = 2048; // backing bytes for all the keys + values of one broadcast
const ACTION_MAX = 256;

// The most recent broadcast, awaiting one take. Single-threaded (main thread).
var g_action: [ACTION_MAX]u8 = undefined;
var g_action_len: usize = 0;
var g_storage: [KV_STORAGE]u8 = undefined;
var g_pairs: [MAX_PAIRS]kv.KeyValue = undefined;
var g_pairs_n: usize = 0;
var g_valid: bool = false;

// Registers a context receiver for `action` (accumulated on one filter). Subscribing
// the same action twice is harmless.
pub fn subscribe(action: []const u8) void {
    std.debug.assert(action.len > 0);
    const c = util.ctx() orelse return;
    const env = c.env;
    const t = env.*;
    const cls = t.GetObjectClass(env, c.activity) orelse return;
    defer t.DeleteLocalRef(env, cls);
    const m = t.GetMethodID(env, cls, "broadcastSubscribe", "(Ljava/lang/String;)V") orelse return;
    const a = util.jstr(env, action) orelse return;
    defer t.DeleteLocalRef(env, a);
    var args = [_]jni.jvalue{.{ .l = a }};
    t.CallVoidMethodA(env, c.activity, m, &args);
}

// The runtime (context-registered) receiver forwards here on the main thread; stored
// for the next take().
pub fn on_native_broadcast(env_ptr: *anyopaque, action: ?*anyopaque, kv_array: ?*anyopaque) void {
    const env: JNIEnv = @ptrCast(@alignCast(env_ptr));
    g_action_len = util.read_jstr(env, action, &g_action).len;
    g_pairs_n = read_pairs(env, kv_array, &g_pairs, &g_storage);
    std.debug.assert(g_action_len <= g_action.len); // the fill invariant take() relies on
    std.debug.assert(g_pairs_n <= g_pairs.len);
    g_valid = true;
}

// The app reads the latest broadcast once; null when nothing arrived since.
pub fn take() ?kv.Broadcast {
    if (!g_valid) return null;
    std.debug.assert(g_action_len <= g_action.len); // never slice past the buffers,
    std.debug.assert(g_pairs_n <= g_pairs.len); // even where the fill asserts are elided
    g_valid = false;
    return .{ .action = g_action[0..g_action_len], .extras = g_pairs[0..g_pairs_n] };
}

// The manifest (static) receiver forwards here for the headless path - on the
// receiver's thread, possibly a cold-started process. Reads into locals and dispatches
// the decoded event; no mailbox, no foreground assumption.
pub fn on_native_static_broadcast(
    env_ptr: *anyopaque,
    action: ?*anyopaque,
    kv_array: ?*anyopaque,
) void {
    const env: JNIEnv = @ptrCast(@alignCast(env_ptr));
    var abuf: [ACTION_MAX]u8 = undefined;
    var storage: [KV_STORAGE]u8 = undefined;
    var pairs: [MAX_PAIRS]kv.KeyValue = undefined;
    const action_s = util.read_jstr(env, action, &abuf);
    const n = read_pairs(env, kv_array, &pairs, &storage);
    std.debug.assert(n <= pairs.len);
    headless.dispatch(.{ .broadcast = .{ .action = action_s, .extras = pairs[0..n] } });
}

// Reads a Java String[] of alternating [key, value, ...] into `pairs`, with the bytes
// copied into `buf` (the pair slices point into it). Stops at pairs.len or buf room.
fn read_pairs(env: JNIEnv, array: ?*anyopaque, pairs: []kv.KeyValue, buf: []u8) usize {
    const ref = array orelse return 0;
    const t = env.*;
    const len: usize = @intCast(@max(t.GetArrayLength(env, ref), 0));
    var used: usize = 0;
    var n: usize = 0;
    var i: usize = 0;
    while (i + 1 < len and n < pairs.len) : (i += 2) {
        const k = read_element(env, ref, i, buf[used..]);
        used += k.len;
        std.debug.assert(used <= buf.len); // read_jstr clamped each element to the room left
        const v = read_element(env, ref, i + 1, buf[used..]);
        used += v.len;
        std.debug.assert(used <= buf.len);
        pairs[n] = .{ .key = k, .value = v };
        n += 1;
    }
    std.debug.assert(n <= pairs.len);
    return n;
}

// Reads array element `index` (a Java String) into buf, releasing the element ref.
fn read_element(env: JNIEnv, array: jni.jobject, index: usize, buf: []u8) []const u8 {
    const t = env.*;
    const obj = t.GetObjectArrayElement(env, array, @intCast(index));
    defer if (obj) |o| t.DeleteLocalRef(env, o);
    return util.read_jstr(env, obj, buf);
}
