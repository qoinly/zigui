// Broadcast subscription: receive system/app broadcasts the app subscribes to. The
// shipped ZiguiActivity registers a context receiver for each subscribed action and
// forwards every onReceive (the action + an action-specific payload) here. Unlike the
// notification listener, a context-registered receiver delivers onReceive on the app's
// MAIN thread - the same thread the paint loop polls from - so the store is
// single-threaded and needs no atomic publish.

const std = @import("std");
const jni = @import("../jni.zig");
const util = @import("util.zig");
const utf8 = @import("utf8.zig");

const JNIEnv = util.JNIEnv;

// The most recent broadcast, "action\tpayload", awaiting one take.
const BC_MAX: usize = 512;
var g_buf: [BC_MAX]u8 = undefined;
var g_len: usize = 0;
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

// The shipped receiver forwards each broadcast here: the action and a payload (for
// SMS, "sender\tbody"; otherwise best-effort "key=value" extras, or empty). Stored as
// "action\tpayload" for the next take. Runs on the main thread (see the file note).
pub fn on_native_broadcast(env_ptr: *anyopaque, action: ?*anyopaque, payload: ?*anyopaque) void {
    const env: JNIEnv = @ptrCast(@alignCast(env_ptr));
    g_len = 0;
    append(env, action);
    append_byte('\t');
    append(env, payload);
    g_valid = true;
    std.debug.assert(g_len <= BC_MAX);
}

// The app reads the latest broadcast once (consume-once, the take_file shape); null
// when nothing arrived since the last read.
pub fn take(buf: []u8) ?[]const u8 {
    if (!g_valid) return null;
    std.debug.assert(g_len <= g_buf.len);
    g_valid = false;
    const n = @min(g_len, buf.len);
    @memcpy(buf[0..n], g_buf[0..n]);
    return buf[0..n];
}

// Appends a Java String's modified-UTF8 to g_buf, clamped to what is left, with a
// back-off so a truncation never splits a codepoint.
fn append(env: JNIEnv, s: ?*anyopaque) void {
    const ref = s orelse return;
    std.debug.assert(g_len <= BC_MAX); // the back-off below relies on the room calc
    const t = env.*;
    const chars = t.GetStringUTFChars(env, ref, null) orelse return;
    defer t.ReleaseStringUTFChars(env, ref, chars);
    const span = std.mem.span(chars);
    const k = utf8.floor(span, @min(span.len, BC_MAX - g_len));
    @memcpy(g_buf[g_len .. g_len + k], span[0..k]);
    g_len += k;
}

fn append_byte(b: u8) void {
    if (g_len >= BC_MAX) return;
    g_buf[g_len] = b;
    g_len += 1;
}
