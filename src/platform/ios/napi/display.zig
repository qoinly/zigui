// Display + chrome: keep the screen awake, override the brightness, and - via the root view
// controller in app.zig - the status-bar style/visibility (immersive) and the orientation
// lock (the scene-owned window resizes, so the surface + safe-area follow the orientation).
const objc = @import("../../macos/objc.zig");
const app = @import("../app.zig");
const Id = objc.Id;

// UIApplication.idleTimerDisabled - when on, the screen won't auto-dim or lock.
pub fn keep_awake(on: bool) void {
    const cls = objc.get_class("UIApplication") orelse return;
    const ui = objc.msg_send(Id, cls, "sharedApplication", .{});
    objc.msg_send(void, ui, "setIdleTimerDisabled:", .{if (on) objc.YES else objc.NO});
}

// UIScreen.mainScreen.brightness in [0,1]; a negative level is a no-op (iOS has no
// "reset to system default" - the system resumes control once nothing overrides it).
pub fn set_brightness(level: f32) void {
    if (level < 0) return;
    const cls = objc.get_class("UIScreen") orelse return;
    const screen = objc.msg_send(Id, cls, "mainScreen", .{});
    objc.msg_send(void, screen, "setBrightness:", .{@as(objc.CGFloat, level)});
}

// dark = dark icons (black, for a light bar); the controller's preferredStatusBarStyle reads it.
pub fn status_bar_dark_icons(dark: bool) void {
    app.set_status_dark(dark);
}

// Hide the status bar for an immersive page.
pub fn immersive(on: bool) void {
    app.set_immersive(on);
}

// The facade's code: 0 landscape, 1 portrait, else (auto/sensor) = free rotation. Mapped to a
// UIInterfaceOrientationMask the root controller enforces + the window scene adopts.
pub fn set_orientation(code: i32) void {
    const mask: objc.NSUInteger = switch (code) {
        0 => 24, // landscape (left | right)
        1 => 2, // portrait
        else => 26, // all but upside-down
    };
    app.set_orientation(mask);
}
