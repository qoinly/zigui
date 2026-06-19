// Accessibility-service control: inject gestures and read the foreground node tree
// (the remote-control surface). The service must be enabled by the user in system
// settings - request_enable opens that screen; enabled() reports whether it is on.
const p = @import("platform.zig");
const impl = p.domain("accessibility");

pub const GlobalAction = enum { back, home, recents };

// AccessibilityEvent.TYPE_* bits to subscribe to (a subset of the common ones).
pub const Event = enum(i32) {
    view_clicked = 0x1,
    view_focused = 0x8,
    window_state_changed = 0x20,
    notification_state_changed = 0x40,
    window_content_changed = 0x800,
};

// Whether the accessibility service is connected. Inject and read do nothing until it is.
pub fn enabled() bool {
    if (@hasDecl(impl, "enabled")) return impl.enabled();
    p.unsupported("accessibility.enabled");
}
// Open the system accessibility settings so the user can enable the service.
pub fn request_enable() void {
    if (@hasDecl(impl, "request_enable")) {
        impl.request_enable();
    } else p.unsupported("accessibility.request_enable");
}
// Inject a tap at screen-pixel (x, y).
pub fn tap(x: f32, y: f32) void {
    if (@hasDecl(impl, "tap")) impl.tap(x, y) else p.unsupported("accessibility.tap");
}
// Inject a swipe from (x1, y1) to (x2, y2) over duration_ms.
pub fn swipe(x1: f32, y1: f32, x2: f32, y2: f32, duration_ms: i32) void {
    if (@hasDecl(impl, "swipe")) {
        impl.swipe(x1, y1, x2, y2, duration_ms);
    } else p.unsupported("accessibility.swipe");
}
// Perform a global navigation action (back / home / recents).
pub fn global_action(action: GlobalAction) void {
    if (@hasDecl(impl, "global_action")) {
        // AccessibilityService.GLOBAL_ACTION_*: BACK 1, HOME 2, RECENTS 3.
        impl.global_action(switch (action) {
            .back => 1,
            .home => 2,
            .recents => 3,
        });
    } else p.unsupported("accessibility.global_action");
}
// Read the foreground window's node tree as text into buf (one node per line:
// "x,y,w,h\ttext"); null on failure, empty when nothing is readable.
pub fn read(buf: []u8) ?[]const u8 {
    if (@hasDecl(impl, "read")) return impl.read(buf);
    p.unsupported("accessibility.read");
}
// Subscribe to an accessibility event type; the service then forwards matching events
// for take_event. Opt-in and filtered - nothing is forwarded until you subscribe.
pub fn subscribe_event(event: Event) void {
    if (@hasDecl(impl, "subscribe_event")) {
        impl.subscribe_event(@intFromEnum(event));
    } else p.unsupported("accessibility.subscribe_event");
}
// The latest subscribed event as "type\tpackage\ttext" into buf, read once; null
// until one arrives.
pub fn take_event(buf: []u8) ?[]const u8 {
    if (@hasDecl(impl, "take_event")) return impl.take_event(buf);
    p.unsupported("accessibility.take_event");
}
