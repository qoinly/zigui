// Small NSString helpers for the iOS napi: build one from a Zig slice on a caller
// stack buffer, and copy one back out as UTF-8.
const objc = @import("../../macos/objc.zig");
const Id = objc.Id;

// An NSString from `s`, copied null-terminated into `buf`; null if it does not fit.
pub fn nsstring(buf: []u8, s: []const u8) ?Id {
    if (s.len + 1 > buf.len) return null;
    @memcpy(buf[0..s.len], s);
    buf[s.len] = 0;
    const NSString = objc.get_class("NSString") orelse return null;
    const cstr: [*:0]const u8 = @ptrCast(buf.ptr);
    return objc.msg_send(Id, NSString, "stringWithUTF8String:", .{cstr});
}

// Copy an NSString's UTF-8 bytes into `buf`, returning the bounded slice.
pub fn read_nsstring(ns: Id, buf: []u8) []const u8 {
    const cstr = objc.msg_send([*:0]const u8, ns, "UTF8String", .{});
    var i: usize = 0;
    while (i < buf.len and cstr[i] != 0) : (i += 1) buf[i] = cstr[i];
    return buf[0..i];
}

// The key window's root view controller, for presenting modals (the share sheet, the
// pickers). keyWindow is deprecated but still resolves the single-scene app's window.
pub fn root_vc() ?Id {
    const UIApplication = objc.get_class("UIApplication") orelse return null;
    const app = objc.msg_send(Id, UIApplication, "sharedApplication", .{});
    const win = objc.msg_send(?Id, app, "keyWindow", .{}) orelse return null;
    return objc.msg_send(?Id, win, "rootViewController", .{});
}
