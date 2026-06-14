// Display + window properties: keep the screen awake, tint the status-bar icons,
// hide the system bars (immersive).
const p = @import("platform.zig");
const impl = p.domain("display");

pub const StatusBarIcons = enum { light, dark };

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
