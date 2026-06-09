// Vsync source: a background thread paced by DwmFlush (blocks until the next
// DWM compositor frame) that posts WM_VSYNC to the GUI thread. The thread only
// signals - the paint callback runs on the GUI thread (see app.run_forever),
// because D3D11 + HWND are single-thread affine. This mirrors the macOS
// CVDisplayLink "background thread signals main" shape.

const std = @import("std");
const win32 = @import("win32.zig");
const loop = @import("loop.zig");

pub const dispatch_function_t = *const fn (?*anyopaque) callconv(.c) void;
pub const CGDirectDisplayID = u32;

pub const Error = error{ThreadSpawnFailed};

pub fn get_main_display_id() CGDirectDisplayID {
    return 0;
}

pub const DisplayLink = struct {
    thread: ?std.Thread = null,

    pub fn init(
        display_id: CGDirectDisplayID,
        context: ?*anyopaque,
        callback: dispatch_function_t,
    ) Error!DisplayLink {
        _ = display_id;
        loop.vsync_cb = callback;
        loop.vsync_ctx = context;
        return .{};
    }

    pub fn start(self: *DisplayLink) Error!void {
        if (self.thread != null) return;
        loop.vsync_running.store(true, .seq_cst);
        self.thread = std.Thread.spawn(.{}, vsync_loop, .{}) catch return error.ThreadSpawnFailed;
    }

    pub fn stop(self: *DisplayLink) void {
        loop.vsync_running.store(false, .seq_cst);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    // Parity with the macOS link: joining the vsync thread is the full teardown.
    pub fn deinit(self: *DisplayLink) void {
        self.stop();
    }
};

fn vsync_loop() void {
    // Exits when stop() clears vsync_running; each tick blocks on the compositor
    // (or the Sleep fallback on failure), so it paces to refresh and never spins.
    while (loop.vsync_running.load(.seq_cst)) {
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
        _ = win32.PostThreadMessageW(loop.gui_thread_id, loop.WM_VSYNC, 0, 0);
    }
}
