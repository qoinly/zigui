// Vsync source: run_forever's poll loop ticks every registered link at its
// fixed cadence on the one GUI thread (paint must stay with the Wayland +
// Vulkan state). The FIFO swapchain self-paces actual presents to the display
// refresh, and an idle tick is two reads and a dirty check - so the fixed
// cadence costs no GPU work, the windows DwmFlush-thread trade-off without
// the thread.

const std = @import("std");
const loop = @import("loop.zig");

pub const dispatch_function_t = loop.VsyncCallback;
pub const CGDirectDisplayID = u32;

pub const Error = error{NoVsyncSlots};

pub fn get_main_display_id() CGDirectDisplayID {
    return 0;
}

pub const DisplayLink = struct {
    token: u32 = 0,

    pub fn init(
        display_id: CGDirectDisplayID,
        context: ?*anyopaque,
        callback: dispatch_function_t,
    ) Error!DisplayLink {
        std.debug.assert(display_id == 0); // per-display links are not wired
        std.debug.assert(@intFromPtr(callback) != 0);
        const token = loop.alloc_vsync_slot(callback, context) orelse
            return error.NoVsyncSlots;
        return .{ .token = token };
    }

    pub fn start(self: *DisplayLink) Error!void {
        std.debug.assert(self.token != 0);
        const slot = loop.get_vsync_slot(self.token) orelse return error.NoVsyncSlots;
        slot.running = true;
    }

    pub fn stop(self: *DisplayLink) void {
        std.debug.assert(self.token != 0);
        if (loop.get_vsync_slot(self.token)) |slot| slot.running = false;
    }

    pub fn deinit(self: *DisplayLink) void {
        self.stop();
        loop.free_vsync_slot(self.token);
        self.token = 0;
        std.debug.assert(self.token == 0);
    }
};
