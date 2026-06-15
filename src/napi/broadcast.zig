// Broadcast subscription: receive the system/app broadcasts the app subscribes to.
// subscribe registers an action; take yields the latest received broadcast as an
// action plus its intent extras (and data URI) as key=value pairs - a broadcast can
// carry many (ACTION_BATTERY_CHANGED has ~15), so the extras are an array. SMS is
// decoded into address/body pairs; other broadcasts get their extras stringified.
const p = @import("platform.zig");
const impl = p.domain("broadcast");

pub const KeyValue = struct { key: []const u8, value: []const u8 };

// One received broadcast. The slices borrow the impl's storage and are valid until
// the next broadcast arrives (the take_* borrowing contract).
pub const Broadcast = struct {
    action: []const u8,
    extras: []const KeyValue,
};

// Subscribe to a broadcast action (e.g. "android.intent.action.SCREEN_ON").
pub fn subscribe(action: []const u8) void {
    if (@hasDecl(impl, "subscribe")) return impl.subscribe(action);
    p.unsupported("broadcast.subscribe");
}

// The most recent matching broadcast, read once; null until one arrives.
pub fn take() ?Broadcast {
    if (@hasDecl(impl, "take")) return impl.take();
    p.unsupported("broadcast.take");
}
