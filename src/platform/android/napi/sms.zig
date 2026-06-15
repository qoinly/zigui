// Stored-SMS reading and SMS sending. read queries the device inbox; send hands a
// message to SmsManager. The Cursor / SmsManager work lives in the activity (Java is
// far simpler for both than JNI); native just calls and, for read, copies the result
// out. read needs READ_SMS, send needs SEND_SMS (both ungranted-safe, no crash).

const std = @import("std");
const jni = @import("../jni.zig");
const util = @import("util.zig");

// The recent inbox messages, "address\tbody\n..." per message, copied into buf. null
// on a JNI miss; empty when the inbox is empty or READ_SMS is not granted.
pub fn read(buf: []u8) ?[]const u8 {
    const c = util.ctx() orelse return null;
    const env = c.env;
    const t = env.*;
    const cls = t.GetObjectClass(env, c.activity) orelse return null;
    defer t.DeleteLocalRef(env, cls);
    const m = t.GetMethodID(env, cls, "smsRead", "()Ljava/lang/String;") orelse return null;
    const s = t.CallObjectMethodA(env, c.activity, m, null) orelse return null;
    defer t.DeleteLocalRef(env, s);
    const chars = t.GetStringUTFChars(env, s, null) orelse return null;
    defer t.ReleaseStringUTFChars(env, s, chars);
    const span = std.mem.span(chars);
    var n = @min(span.len, buf.len);
    // A byte-count truncation could split a UTF-8 codepoint; back off to its start.
    while (n > 0 and n < span.len and (span[n] & 0xc0) == 0x80) n -= 1;
    @memcpy(buf[0..n], span[0..n]);
    return buf[0..n];
}

// Sends an SMS to address. The activity's smsSend lets SmsManager split a multi-part
// body into parts; the body is capped near 1 KB (util.STR_MAX) here, longer text is
// truncated. A no-op when address is empty or SEND_SMS is not granted.
pub fn send(address: []const u8, body: []const u8) void {
    std.debug.assert(address.len > 0);
    const c = util.ctx() orelse return;
    const env = c.env;
    const t = env.*;
    const cls = t.GetObjectClass(env, c.activity) orelse return;
    defer t.DeleteLocalRef(env, cls);
    const sig = "(Ljava/lang/String;Ljava/lang/String;)V";
    const m = t.GetMethodID(env, cls, "smsSend", sig) orelse return;
    const addr = util.jstr(env, address) orelse return;
    defer t.DeleteLocalRef(env, addr);
    // jstr caps + asserts at STR_MAX, so clamp the body first - a long one truncates,
    // never trips the assert; back off so the cut never splits a UTF-8 codepoint.
    var bn = @min(body.len, util.STR_MAX);
    while (bn > 0 and bn < body.len and (body[bn] & 0xc0) == 0x80) bn -= 1;
    const text = util.jstr(env, body[0..bn]) orelse return;
    defer t.DeleteLocalRef(env, text);
    var args = [_]jni.jvalue{ .{ .l = addr }, .{ .l = text } };
    t.CallVoidMethodA(env, c.activity, m, &args);
}
