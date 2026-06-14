// Haptic feedback.
const p = @import("platform.zig");
const impl = p.domain("haptics");

pub fn vibrate(ms: i64) void {
    if (@hasDecl(impl, "vibrate")) impl.vibrate(ms) else p.unsupported("haptics.vibrate");
}
