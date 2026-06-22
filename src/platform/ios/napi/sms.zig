// Send an SMS via MFMessageComposeViewController. iOS cannot send programmatically, so this
// presents the system composer pre-filled with the address + body and the user taps send.
// canSendText is false on a device with no Messages (incl. most simulators), so send is then
// a no-op. The inbox is private on iOS (no read API), so the facade reports sms.read
// unsupported here.
const std = @import("std");
const objc = @import("../../macos/objc.zig");
const util = @import("util.zig");
const Id = objc.Id;

var g_delegate: ?Id = null;

// messageComposeViewController:didFinishWithResult: - dismiss the composer once the user
// sends or cancels.
fn did_finish(_: Id, _: objc.Sel, controller: Id, _: objc.NSInteger) callconv(.c) void {
    const no_completion: ?*anyopaque = null;
    const sel = "dismissViewControllerAnimated:completion:";
    objc.msg_send(void, controller, sel, .{ objc.YES, no_completion });
}

// A retained NSObject subclass carrying the compose delegate, built once. The composer's
// delegate is weak, so g_delegate keeps it alive.
fn ensure_delegate() ?Id {
    if (g_delegate) |d| return d;
    const NSObject = objc.get_class("NSObject") orelse return null;
    const cls = objc.objc_allocateClassPair(NSObject, "ZiguiSmsDelegate", 0) orelse return null;
    const sel = "messageComposeViewController:didFinishWithResult:";
    _ = objc.class_addMethod(cls, objc.sel(sel), @ptrCast(&did_finish), "v@:@q");
    objc.objc_registerClassPair(cls);
    const d = objc.msg_send(Id, objc.alloc(cls), "init", .{});
    g_delegate = d;
    return d;
}

pub fn send(address: []const u8, body: []const u8) void {
    std.debug.assert(address.len > 0);
    const cls = objc.get_class("MFMessageComposeViewController") orelse return;
    if (objc.msg_send(objc.BOOL, cls, "canSendText", .{}) == 0) return; // no SMS on this device
    const vc = objc.msg_send(Id, objc.alloc(cls), "init", .{});
    _ = objc.msg_send(Id, vc, "autorelease", .{}); // present retains it; balance the alloc
    var abuf: [64]u8 = undefined;
    if (util.nsstring(&abuf, address)) |num| {
        const NSArray = objc.get_class("NSArray") orelse return;
        const recipients = objc.msg_send(Id, NSArray, "arrayWithObject:", .{num});
        objc.msg_send(void, vc, "setRecipients:", .{recipients});
    }
    var bbuf: [512]u8 = undefined;
    if (util.nsstring(&bbuf, body)) |b| objc.msg_send(void, vc, "setBody:", .{b});
    const d = ensure_delegate() orelse return;
    objc.msg_send(void, vc, "setMessageComposeDelegate:", .{d});
    const root = util.root_vc() orelse return;
    const no_completion: ?*anyopaque = null;
    const psel = "presentViewController:animated:completion:";
    objc.msg_send(void, root, psel, .{ vc, objc.YES, no_completion });
}
