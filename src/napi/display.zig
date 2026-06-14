// Display + window properties: keep the screen awake, tint the status-bar icons,
// hide the system bars (immersive).
const p = @import("platform.zig");
const impl = p.domain("display");

pub const StatusBarIcons = enum { light, dark };
pub const Orientation = enum { auto, portrait, landscape, sensor };

pub fn keep_awake(on: bool) void {
    if (@hasDecl(impl, "keep_awake")) impl.keep_awake(on) else p.unsupported("display.keep_awake");
}
pub fn status_bar_icons(which: StatusBarIcons) void {
    if (@hasDecl(impl, "status_bar_dark_icons")) {
        impl.status_bar_dark_icons(which == .dark);
    } else p.unsupported("display.status_bar_icons");
}
pub fn immersive(on: bool) void {
    if (@hasDecl(impl, "immersive")) impl.immersive(on) else p.unsupported("display.immersive");
}
// Lock the screen to an orientation (or let the sensor/system decide).
pub fn orientation(which: Orientation) void {
    if (@hasDecl(impl, "set_orientation")) {
        // ActivityInfo.SCREEN_ORIENTATION_*: UNSPECIFIED -1, LANDSCAPE 0, PORTRAIT 1, SENSOR 4.
        impl.set_orientation(switch (which) {
            .auto => -1,
            .landscape => 0,
            .portrait => 1,
            .sensor => 4,
        });
    } else p.unsupported("display.orientation");
}
// Override the screen brightness in [0,1]; a negative resets to the system default.
pub fn brightness(level: f32) void {
    if (@hasDecl(impl, "set_brightness")) {
        impl.set_brightness(level);
    } else p.unsupported("display.brightness");
}
