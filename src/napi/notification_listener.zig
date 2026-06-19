// Notification listening: observe notifications posted by any app. The listener is a
// user-enabled service - request_enable opens that settings screen, enabled() reports
// whether it is on, and take yields the latest posted notification.
const p = @import("platform.zig");
const impl = p.domain("notification_listener");

// Whether the listener service is connected. take yields nothing until it is.
pub fn enabled() bool {
    if (@hasDecl(impl, "enabled")) return impl.enabled();
    p.unsupported("notification_listener.enabled");
}
// Open the notification-access settings so the user can enable the listener.
pub fn request_enable() void {
    if (@hasDecl(impl, "request_enable")) return impl.request_enable();
    p.unsupported("notification_listener.request_enable");
}
// The most recent posted notification as "package\ttitle\ttext" into buf, read once;
// null until one arrives.
pub fn take(buf: []u8) ?[]const u8 {
    if (@hasDecl(impl, "take")) return impl.take(buf);
    p.unsupported("notification_listener.take");
}
