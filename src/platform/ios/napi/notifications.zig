// Local notifications via UNUserNotificationCenter. post() schedules one for immediate
// delivery; a delegate makes it show as a banner while the app is foreground (iOS otherwise
// suppresses foreground notifications). Needs the notifications permission granted.
// There is no toast() - iOS has no system transient overlay, so the facade reports it
// unsupported here.
const std = @import("std");
const objc = @import("../../macos/objc.zig");
const util = @import("util.zig");
const Id = objc.Id;

var g_delegate: ?Id = null;

fn center() ?Id {
    const cls = objc.get_class("UNUserNotificationCenter") orelse return null;
    return objc.msg_send(?Id, cls, "currentNotificationCenter", .{});
}

// willPresentNotification:withCompletionHandler: - call the OS-provided completion block
// with banner+sound so the notification shows while the app is in the foreground. A block
// is its own implicit first argument, so invoke it as block.invoke(block, options).
fn will_present(_: Id, _: objc.Sel, _: Id, _: Id, completion: Id) callconv(.c) void {
    const blk: *objc.Block = @ptrCast(@alignCast(completion));
    const Invoke = *const fn (*anyopaque, objc.NSUInteger) callconv(.c) void;
    const invoke: Invoke = @ptrCast(@alignCast(blk.invoke));
    invoke(@ptrCast(completion), 18); // UNNotificationPresentationOptions: banner (16) | sound (2)
}

fn ensure_delegate() void {
    if (g_delegate != null) return;
    const c = center() orelse return;
    const NSObject = objc.get_class("NSObject") orelse return;
    const cls = objc.objc_allocateClassPair(NSObject, "ZiguiNotifDelegate", 0) orelse return;
    const sel = "userNotificationCenter:willPresentNotification:withCompletionHandler:";
    _ = objc.class_addMethod(cls, objc.sel(sel), @ptrCast(&will_present), "v@:@@@");
    objc.objc_registerClassPair(cls);
    const d = objc.msg_send(Id, objc.alloc(cls), "init", .{});
    g_delegate = d; // the center's delegate is weak, so keep it alive here
    objc.msg_send(void, c, "setDelegate:", .{d});
}

pub fn post(title: []const u8, body: []const u8) void {
    std.debug.assert(title.len > 0);
    ensure_delegate();
    const c = center() orelse return;
    const Content = objc.get_class("UNMutableNotificationContent") orelse return;
    const content = objc.msg_send(Id, objc.alloc(Content), "init", .{});
    _ = objc.msg_send(Id, content, "autorelease", .{}); // balance the alloc on every exit
    var tbuf: [256]u8 = undefined;
    var bbuf: [512]u8 = undefined;
    if (util.nsstring(&tbuf, title)) |t| objc.msg_send(void, content, "setTitle:", .{t});
    if (util.nsstring(&bbuf, body)) |b| objc.msg_send(void, content, "setBody:", .{b});
    const Req = objc.get_class("UNNotificationRequest") orelse return;
    var ibuf: [32]u8 = undefined;
    const ident = util.nsstring(&ibuf, "zigui.demo") orelse return;
    const no_trigger: ?*anyopaque = null; // nil trigger = deliver immediately
    const rsel = "requestWithIdentifier:content:trigger:";
    const req = objc.msg_send(Id, Req, rsel, .{ ident, content, no_trigger });
    const no_comp: ?*anyopaque = null;
    objc.msg_send(void, c, "addNotificationRequest:withCompletionHandler:", .{ req, no_comp });
}
