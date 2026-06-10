// Vsync source: a background thread paced by DwmFlush (blocks until the next
// DWM compositor frame) that posts WM_VSYNC to the GUI thread. The thread only
// signals - the paint callback runs on the GUI thread (see app.run_forever),
// because D3D11 + HWND are single-thread affine. This mirrors the macOS
// CVDisplayLink "background thread signals main" shape.

const std = @import("std");
const win32 = @import("win32.zig");
const loop = @import("loop.zig");

pub const dispatch_function_t = loop.VsyncCallback;
pub const CGDirectDisplayID = u32;

pub const Error = error{ NoVsyncSlots, ThreadSpawnFailed };

pub fn get_main_display_id() CGDirectDisplayID {
    return 0;
}

pub const DisplayLink = struct {
    thread: ?std.Thread = null,
    token: usize = 0,

    pub fn init(
        display_id: CGDirectDisplayID,
        context: ?*anyopaque,
        callback: dispatch_function_t,
    ) Error!DisplayLink {
        _ = display_id;
        const token = loop.alloc_vsync_slot(callback, context) orelse return error.NoVsyncSlots;
        return .{ .token = token };
    }

    pub fn start(self: *DisplayLink) Error!void {
        if (self.thread != null) return;
        const slot = loop.get_vsync_slot(self.token) orelse return error.NoVsyncSlots;
        slot.running.store(true, .seq_cst);
        self.thread = std.Thread.spawn(.{}, vsync_loop, .{self.token}) catch {
            slot.running.store(false, .seq_cst);
            return error.ThreadSpawnFailed;
        };
    }

    pub fn stop(self: *DisplayLink) void {
        if (loop.get_vsync_slot(self.token)) |slot| slot.running.store(false, .seq_cst);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    // Parity with the macOS link: joining the vsync thread is the full teardown.
    pub fn deinit(self: *DisplayLink) void {
        self.stop();
        loop.free_vsync_slot(self.token);
        self.token = 0;
    }
};

fn vsync_loop(token: usize) void {
    // Exits when stop() clears this link's slot; each tick blocks on the compositor
    // (or the Sleep fallback on failure), so it paces to refresh and never spins.
    std.debug.assert(token != 0);
    while (true) {
        const slot = loop.get_vsync_slot(token) orelse return;
        if (!slot.running.load(.seq_cst)) return;
        std.debug.assert(loop.gui_thread_id != 0); // post target, set before this thread spawns
        // During the modal resize/move loop, WM_SIZE drives paint synchronously,
        // so this thread goes fully idle for its duration. A posted WM_VSYNC
        // outranks input in GetMessage and would starve the mouse-move messages
        // the resize + cursor depend on (cursor lags seconds behind the hand);
        // and DwmFlush here contends with the GUI thread's Present. Resume the
        // normal cadence once the drag ends.
        if (loop.resizing.load(.seq_cst)) {
            win32.Sleep(8);
            continue;
        }
        if (win32.DwmFlush() != 0) {
            win32.Sleep(8);
        }
        _ = win32.PostThreadMessageW(loop.gui_thread_id, loop.WM_VSYNC, token, 0);
    }
}
