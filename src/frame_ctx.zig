const std = @import("std");
const paint = @import("window/paint.zig");
const types = @import("window/types.zig");

// Per-frame context the free builders read so the caller does not thread an
// allocator/theme/paint into every `col`/`button`. `run` sets it for the
// duration of one synchronous `render` call (which never suspends), then clears
// it. The UI is single-threaded - one display link on the main thread - so a
// module-level pointer is the mechanically-sympathetic choice; the negative
// space is asserted on every transition.
pub const FrameCtx = struct {
    arena: std.mem.Allocator, // reset each frame by run
    theme: *const types.Theme,
    paint: *paint.PaintContext,
    state: ?*anyopaque = null, // the caller's run state; handed back to callbacks
};

var current: ?*FrameCtx = null;

pub fn enter(fc: *FrameCtx) void {
    std.debug.assert(current == null);
    current = fc;
}

pub fn leave() void {
    std.debug.assert(current != null);
    current = null;
}

pub fn get() *FrameCtx {
    return current orelse @panic("zigui: a builder was called outside render()");
}
