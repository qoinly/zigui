// Broadcast subscription: receive the system/app broadcasts the app subscribes to.
// subscribe registers an action; take yields the latest received broadcast as
// "action\tpayload" (the payload is action-specific - decoded SMS, best-effort
// extras, or empty).
const p = @import("platform.zig");
const impl = p.domain("broadcast");

// Subscribe to a broadcast action (e.g. "android.intent.action.SCREEN_ON").
pub fn subscribe(action: []const u8) void {
    if (@hasDecl(impl, "subscribe")) return impl.subscribe(action);
    p.unsupported("broadcast.subscribe");
}
// The most recent matching broadcast as "action\tpayload" into buf, read once; null
// until one arrives.
pub fn take(buf: []u8) ?[]const u8 {
    if (@hasDecl(impl, "take")) return impl.take(buf);
    p.unsupported("broadcast.take");
}
