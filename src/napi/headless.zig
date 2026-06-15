// Headless background events. On Android these arrive entirely through native APIs -
// a NotificationListenerService and manifest-declared BroadcastReceivers deliver
// them over JNI, even with no Activity and no render loop (the system may cold-start
// the process just to deliver). So this is a napi domain. zigui reads the event via
// JNI on the service/receiver thread, then calls the app's `on_background_event` if
// it defines one - a comptime-discovered entry (the @import("root").main bridge
// pattern), which resolves whether or not main() ran (the cold-start case where no
// runtime registration could have happened).
//
// The handler is pure Zig over a decoded payload. Two rules it must keep:
//  - The payload slices borrow JNI-read buffers valid only for the call; copy what
//    you keep (the take_* borrowing contract).
//  - Do not call other zigui.napi.* domains - JNI there binds to the UI thread; off
//    it, napi refuses the call (a warn-once + no-op, never a wrong-thread env).
//    Headless work is compute / file / socket; publish a result the UI reads on next
//    foreground.

const root = @import("root");
const broadcast = @import("broadcast.zig");

pub const BackgroundEvent = union(enum) {
    notification: Notification,
    // The broadcast shape (action + key=value extras) is shared with the foreground
    // broadcast.take(), so an app handles a broadcast the same way either way.
    broadcast: broadcast.Broadcast,

    pub const Notification = struct {
        package: []const u8,
        title: []const u8,
        text: []const u8,
    };
};

// Call the app's headless handler if it defines one. Comptime-guarded so a root
// without the decl (the standalone zigui lib build, or a desktop app that never set
// one) prunes the reference entirely. Invoked by the android event bridges.
pub fn dispatch(ev: BackgroundEvent) void {
    if (comptime @hasDecl(root, "on_background_event")) {
        root.on_background_event(ev);
    }
}
