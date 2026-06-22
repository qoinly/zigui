// Local notifications via UNUserNotificationCenter. post() schedules one for immediate
// delivery; a delegate makes it show as a banner while the app is foreground (iOS otherwise
// suppresses foreground notifications). Needs the notifications permission granted.
// iOS has no system toast, so toast() synthesizes a transient bottom overlay.
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

// --- toast: a transient bottom overlay (iOS has no system toast) ---

extern "c" var _dispatch_main_q: anyopaque;
extern "c" fn dispatch_time(when: u64, delta: i64) u64;
extern "c" fn dispatch_after(when: u64, queue: *anyopaque, block: *const objc.Block) void;

var g_desc: objc.BlockDescriptor = .{ .size = @sizeOf(objc.Block) };
var g_remove_block: objc.Block = undefined;
var g_toast: ?Id = null;

// rgba components are [0,1], not 0-255.
fn color(r: f64, g: f64, b: f64, a: f64) ?Id {
    const UIColor = objc.get_class("UIColor") orelse return null;
    const sel = "colorWithRed:green:blue:alpha:";
    return objc.msg_send(Id, UIColor, sel, .{
        @as(objc.CGFloat, r), @as(objc.CGFloat, g), @as(objc.CGFloat, b), @as(objc.CGFloat, a),
    });
}

// Removes the current toast (runs on the main queue, ~2s after the toast was shown).
fn do_remove(_: *objc.Block) callconv(.c) void {
    if (g_toast) |l| objc.msg_send(void, l, "removeFromSuperview", .{});
    g_toast = null;
}

// A rounded label pinned near the bottom of the key window, auto-removed after ~2s. Only one
// shows at a time (a new toast replaces the prior).
pub fn toast(text: []const u8) void {
    std.debug.assert(text.len > 0);
    const win = util.key_window() orelse return;
    const bounds = objc.msg_send(objc.NSRect, win, "bounds", .{});
    const Label = objc.get_class("UILabel") orelse return;
    const label = objc.msg_send(Id, objc.alloc(Label), "init", .{});
    _ = objc.msg_send(Id, label, "autorelease", .{}); // the window retains it as a subview
    var buf: [256]u8 = undefined;
    if (util.nsstring(&buf, text)) |ns| objc.msg_send(void, label, "setText:", .{ns});
    if (color(1, 1, 1, 1)) |c| objc.msg_send(void, label, "setTextColor:", .{c});
    if (color(0, 0, 0, 0.85)) |c| objc.msg_send(void, label, "setBackgroundColor:", .{c});
    objc.msg_send(void, label, "setTextAlignment:", .{@as(objc.NSInteger, 1)}); // center
    const layer = objc.msg_send(Id, label, "layer", .{});
    objc.msg_send(void, layer, "setCornerRadius:", .{@as(objc.CGFloat, 16)});
    objc.msg_send(void, label, "setClipsToBounds:", .{objc.YES});
    const margin: objc.CGFloat = 40;
    const frame = objc.NSRect{
        .origin = .{ .x = margin, .y = bounds.size.height - 120 },
        .size = .{ .width = bounds.size.width - margin * 2, .height = 44 },
    };
    objc.msg_send(void, label, "setFrame:", .{frame});
    if (g_toast) |old| objc.msg_send(void, old, "removeFromSuperview", .{});
    objc.msg_send(void, win, "addSubview:", .{label});
    g_toast = label;
    g_remove_block = objc.global_block(@ptrCast(&do_remove), &g_desc);
    dispatch_after(dispatch_time(0, 2_000_000_000), &_dispatch_main_q, &g_remove_block);
}
