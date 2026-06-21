// Haptic feedback. iOS has no public duration-based vibration, so `ms` is advisory -
// this fires one medium impact via UIImpactFeedbackGenerator. A no-op on hardware
// without a Taptic Engine (the simulator, older devices).
const std = @import("std");
const objc = @import("../../macos/objc.zig");
const Id = objc.Id;

pub fn vibrate(ms: i64) void {
    std.debug.assert(ms > 0); // a zero-length buzz is a caller bug, not a request
    const cls = objc.get_class("UIImpactFeedbackGenerator") orelse return;
    const style: objc.NSInteger = 1; // UIImpactFeedbackStyleMedium
    const gen = objc.msg_send(Id, objc.alloc(cls), "initWithStyle:", .{style});
    objc.msg_send(void, gen, "prepare", .{});
    objc.msg_send(void, gen, "impactOccurred", .{});
    _ = objc.msg_send(Id, gen, "autorelease", .{}); // the runloop pool frees it post-event
}
