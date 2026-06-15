// Reading stored SMS: query the device inbox for the most recent messages, as
// "address\tbody" lines. The Cursor work lives in the activity's smsRead (Java is far
// simpler for a Cursor than JNI); native just calls it and copies the result out.
// Needs the READ_SMS runtime permission - an ungranted read comes back empty.

const std = @import("std");
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
