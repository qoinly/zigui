// Plain-text clipboard via UIPasteboard.generalPasteboard.
const objc = @import("../../macos/objc.zig");
const util = @import("util.zig");
const Id = objc.Id;

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
