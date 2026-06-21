// Outbound links: open a url in Safari (or whichever app claims the scheme).
const std = @import("std");
const objc = @import("../../macos/objc.zig");
const util = @import("util.zig");
const Id = objc.Id;

// [[UIApplication sharedApplication] openURL:options:completionHandler:] with an empty
// options dict and no completion handler.
pub fn open_url(url: []const u8) void {
    std.debug.assert(url.len > 0);
    var buf: [2048]u8 = undefined;
    const ns = util.nsstring(&buf, url) orelse return;
    const NSURL = objc.get_class("NSURL") orelse return;
    const nsurl = objc.msg_send(?Id, NSURL, "URLWithString:", .{ns}) orelse return;
    const UIApplication = objc.get_class("UIApplication") orelse return;
    const app = objc.msg_send(Id, UIApplication, "sharedApplication", .{});
    const NSDictionary = objc.get_class("NSDictionary") orelse return;
    const opts = objc.msg_send(Id, NSDictionary, "dictionary", .{});
    const no_handler: ?*anyopaque = null;
    objc.msg_send(void, app, "openURL:options:completionHandler:", .{ nsurl, opts, no_handler });
}

// Share text via the system share sheet (UIActivityViewController), presented modally
// from the key window's root view controller.
pub fn share_text(text: []const u8) void {
    std.debug.assert(text.len > 0);
    var buf: [4096]u8 = undefined;
    const ns = util.nsstring(&buf, text) orelse return;
    const NSArray = objc.get_class("NSArray") orelse return;
    const items = objc.msg_send(Id, NSArray, "arrayWithObject:", .{ns});
    const AVC = objc.get_class("UIActivityViewController") orelse return;
    const nil_acts: ?*anyopaque = null;
    const init_sel = "initWithActivityItems:applicationActivities:";
    const avc = objc.msg_send(Id, objc.alloc(AVC), init_sel, .{ items, nil_acts });
    const root = util.root_vc() orelse return;
    const no_completion: ?*anyopaque = null;
    const present_sel = "presentViewController:animated:completion:";
    objc.msg_send(void, root, present_sel, .{ avc, objc.YES, no_completion });
    _ = objc.msg_send(Id, avc, "autorelease", .{}); // present retained it; balance our alloc
}
