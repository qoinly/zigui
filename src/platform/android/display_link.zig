// Android vsync source: AChoreographer posts a frame callback that fires once
// on the next display refresh, so re-posting from inside it is the run loop -
// the same shape the standalone vsync example proved (12b8066). It fronts the
// cross-platform DisplayLink surface (init/start/stop/deinit) so start_paint_loop
// drives Android exactly as it drives the desktop links.
//
// One NativeActivity owns one fullscreen surface (native.MAX_WINDOWS == 1), so a
// single process-global slot holds the link state; the framework runs the
// looper this posts onto, on the same thread that builds the link.

const std = @import("std");
const native = @import("native.zig");

pub const dispatch_function_t = *const fn (?*anyopaque) callconv(.c) void;
pub const CGDirectDisplayID = u32;

pub const Error = error{NoVsyncSlots};

pub fn get_main_display_id() CGDirectDisplayID {
    return 0;
}

const Slot = struct {
    callback: ?dispatch_function_t = null,
    context: ?*anyopaque = null,
    chor: ?*native.AChoreographer = null,
    running: bool = false,
    // A frame callback is in flight; guards against posting two parallel chains.
    posted: bool = false,
};

var g_slot: Slot = .{};

pub const DisplayLink = struct {
    active: bool = false,

    pub fn init(
        display_id: CGDirectDisplayID,
        context: ?*anyopaque,
        callback: dispatch_function_t,
    ) Error!DisplayLink {
        std.debug.assert(display_id == 0); // per-display links are not wired
        std.debug.assert(@intFromPtr(callback) != 0);
        std.debug.assert(g_slot.callback == null); // one surface, one link
        g_slot = .{ .callback = callback, .context = context };
        return .{ .active = true };
    }

    pub fn start(self: *DisplayLink) Error!void {
        std.debug.assert(self.active);
        if (g_slot.running) return;
        g_slot.running = true;
        g_slot.chor = native.AChoreographer_getInstance();
        // No frame clock (a looper-less thread) cannot pace presents; draw one
        // frame so the surface at least shows its first content.
        if (g_slot.chor == null) {
            if (g_slot.callback) |cb| cb(g_slot.context);
            return;
        }
        post();
    }

    pub fn stop(self: *DisplayLink) void {
        std.debug.assert(self.active);
        g_slot.running = false;
    }

    pub fn deinit(self: *DisplayLink) void {
        if (!self.active) return;
        g_slot = .{};
        self.active = false;
    }
};

fn post() void {
    if (!g_slot.running or g_slot.posted) return;
    const chor = g_slot.chor orelse return;
    g_slot.posted = true;
    native.AChoreographer_postFrameCallback(chor, on_vsync, null);
}

fn on_vsync(frame_time_nanos: i64, data: ?*anyopaque) callconv(.c) void {
    _ = frame_time_nanos;
    _ = data;
    g_slot.posted = false;
    // A teardown between the post and this fire clears the slot; do nothing then.
    if (!g_slot.running) return;
    if (g_slot.callback) |cb| cb(g_slot.context);
    post();
}
