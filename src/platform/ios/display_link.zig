// iOS vsync source: CADisplayLink fires a target selector once per display
// refresh on the run loop it is added to (the main thread here). It fronts the
// cross-platform DisplayLink surface (init/start/stop/deinit) so start_paint_loop
// drives iOS exactly as the desktop links do. CADisplayLink runs on the main
// thread, so - unlike the macOS CVDisplayLink - the paint callback fires directly
// with no cross-thread coalescing.
//
// One fullscreen surface per app, so a single process-global slot holds the link
// state; the target object and selector are built once through the objc runtime.

const std = @import("std");
const objc = @import("../macos/objc.zig");

pub const dispatch_function_t = *const fn (?*anyopaque) callconv(.c) void;
pub const CGDirectDisplayID = u32;

pub const Error = error{DisplayLinkCreateFailed};

pub fn get_main_display_id() CGDirectDisplayID {
    return 0;
}

const Slot = struct {
    callback: ?dispatch_function_t = null,
    context: ?*anyopaque = null,
    link: ?objc.Id = null, // CADisplayLink, retained while active
    running: bool = false,
    added: bool = false, // already in the run loop (start pauses/unpauses after)
};

var g_slot: Slot = .{};

pub const DisplayLink = struct {
    active: bool = false,

    pub fn init(
        display_id: CGDirectDisplayID,
        context: ?*anyopaque,
        callback: dispatch_function_t,
    ) Error!DisplayLink {
        std.debug.assert(display_id == 0); // per-display links are not wired
        std.debug.assert(g_slot.callback == null); // one surface, one link
        g_slot = .{ .callback = callback, .context = context };
        g_slot.link = make_link() orelse {
            g_slot = .{};
            return Error.DisplayLinkCreateFailed;
        };
        return .{ .active = true };
    }

    pub fn start(self: *DisplayLink) Error!void {
        std.debug.assert(self.active);
        if (g_slot.running) return;
        const link = g_slot.link orelse return Error.DisplayLinkCreateFailed;
        if (g_slot.added) {
            objc.msg_send(void, link, "setPaused:", .{objc.NO});
        } else {
            const NSRunLoop = objc.get_class("NSRunLoop") orelse
                return Error.DisplayLinkCreateFailed;
            const runloop = objc.msg_send(objc.Id, NSRunLoop, "mainRunLoop", .{});
            objc.msg_send(void, link, "addToRunLoop:forMode:", .{ runloop, default_mode() });
            g_slot.added = true;
        }
        g_slot.running = true;
    }

    pub fn stop(self: *DisplayLink) void {
        std.debug.assert(self.active);
        if (!g_slot.running) return;
        if (g_slot.link) |link| objc.msg_send(void, link, "setPaused:", .{objc.YES});
        g_slot.running = false;
    }

    pub fn deinit(self: *DisplayLink) void {
        if (!self.active) return;
        if (g_slot.link) |link| {
            objc.msg_send(void, link, "invalidate", .{}); // drops the link's target retain
            objc.msg_send(void, link, "release", .{});
        }
        g_slot = .{};
        self.active = false;
    }
};

var g_target_class: ?objc.Class = null;

fn make_link() ?objc.Id {
    const cls = ensure_target_class() orelse return null;
    const target = objc.msg_send(objc.Id, objc.alloc(cls), "init", .{});
    const CADisplayLink = objc.get_class("CADisplayLink") orelse {
        objc.msg_send(void, target, "release", .{});
        return null;
    };
    const link = objc.msg_send(
        objc.Id,
        CADisplayLink,
        "displayLinkWithTarget:selector:",
        .{ target, objc.sel("tick:") },
    );
    std.debug.assert(@intFromPtr(link) != 0);
    // The link retains its target, so drop our init reference; retain the link
    // itself so it outlives the launch autorelease pool. deinit's invalidate then
    // releases the target, leaving nothing live.
    const retained = objc.msg_send(objc.Id, link, "retain", .{});
    objc.msg_send(void, target, "release", .{});
    return retained;
}

fn ensure_target_class() ?objc.Class {
    if (g_target_class) |c| return c;
    const NSObject = objc.get_class("NSObject") orelse return null;
    const cls = objc.objc_allocateClassPair(NSObject, "ZiguiDisplayTarget", 0) orelse return null;
    _ = objc.class_addMethod(cls, objc.sel("tick:"), @ptrCast(&tick), "v@:@");
    objc.objc_registerClassPair(cls);
    g_target_class = cls;
    return cls;
}

fn tick(_: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) void {
    if (!g_slot.running) return;
    if (g_slot.callback) |cb| cb(g_slot.context);
}

// The default run-loop mode, matched by value (NSRunLoop compares mode strings),
// so a freshly built string is equivalent to NSDefaultRunLoopMode.
fn default_mode() objc.Id {
    const NSString = objc.get_class("NSString").?;
    return objc.msg_send(objc.Id, NSString, "stringWithUTF8String:", .{
        @as([*:0]const u8, "kCFRunLoopDefaultMode"),
    });
}
