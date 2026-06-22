// Plain-text clipboard via UIPasteboard.generalPasteboard, plus an external-change poll.
const objc = @import("../../macos/objc.zig");
const util = @import("util.zig");
const Id = objc.Id;

var g_last_count: objc.NSInteger = -1;

fn general() ?Id {
    const cls = objc.get_class("UIPasteboard") orelse return null;
    return objc.msg_send(Id, cls, "generalPasteboard", .{});
}

pub fn read(buf: []u8) []const u8 {
    const pb = general() orelse return buf[0..0];
    const s = objc.msg_send(?Id, pb, "string", .{}) orelse return buf[0..0];
    return util.read_nsstring(s, buf);
}

pub fn write(text: []const u8) void {
    const pb = general() orelse return;
    var buf: [4096]u8 = undefined;
    const ns = util.nsstring(&buf, text) orelse return;
    objc.msg_send(void, pb, "setString:", .{ns});
}

// UIPasteboard.changeCount bumps when any app writes the clipboard; reading it (unlike
// .string) raises no paste-permission prompt, so a loop can poll for an external change
// cheaply and read() only when it flips. The first call seeds the baseline.
pub fn changed() bool {
    const pb = general() orelse return false;
    const count = objc.msg_send(objc.NSInteger, pb, "changeCount", .{});
    if (g_last_count < 0) {
        g_last_count = count;
        return false;
    }
    const did = count != g_last_count;
    g_last_count = count;
    return did;
}
