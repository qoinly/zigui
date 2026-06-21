// Display properties: keep the screen awake, override the brightness. The status-bar tint,
// immersive mode, and orientation lock need view-controller / app-delegate plumbing and are
// not wired here, so the facade reports them unsupported on iOS.
const objc = @import("../../macos/objc.zig");
const Id = objc.Id;

// UIApplication.idleTimerDisabled - when on, the screen won't auto-dim or lock.
pub fn keep_awake(on: bool) void {
    const cls = objc.get_class("UIApplication") orelse return;
    const app = objc.msg_send(Id, cls, "sharedApplication", .{});
    objc.msg_send(void, app, "setIdleTimerDisabled:", .{if (on) objc.YES else objc.NO});
}

// UIScreen.mainScreen.brightness in [0,1]; a negative level is a no-op (iOS has no
// "reset to system default" - the system resumes control once nothing overrides it).
pub fn set_brightness(level: f32) void {
    if (level < 0) return;
    const cls = objc.get_class("UIScreen") orelse return;
    const screen = objc.msg_send(Id, cls, "mainScreen", .{});
    objc.msg_send(void, screen, "setBrightness:", .{@as(objc.CGFloat, level)});
}
