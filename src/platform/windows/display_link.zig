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
        if (loop.get_vsync_slot(self.token)) |slot| {
            slot.running.store(false, .seq_cst);
            // Snap an in-progress idle wait so the join never sits out the cap.
            if (slot.wake_event) |ev| _ = win32.SetEvent(ev);
        }
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
        // During the modal resize/move loop, WM_SIZE drives paint synchronously
        // on the GUI thread; a posted WM_VSYNC outranks input in GetMessage and
        // would starve the mouse-moves the resize depends on. So instead of
        // posting, keep pacing on DwmFlush and PUBLISH each vblank's timestamp:
        // the WM_SIZE handler gates its paints on it (at most one per vblank),
        // which locks the resize cadence to the compositor clock at any refresh
        // rate. Resume normal posting once the drag ends.
        if (loop.resizing.load(.seq_cst)) {
            if (win32.DwmFlush() != 0) {
                win32.Sleep(8);
                continue;
            }
            var now: i64 = 0;
            _ = win32.QueryPerformanceCounter(&now);
            loop.vblank_qpc.store(now, .seq_cst);
            continue;
        }
        // Adaptive idle: when the last tick reported nothing animating, park on
        // the wake event (input, a redraw request, or stop() sets it) instead of
        // pacing on DwmFlush. Falling through to DwmFlush after the wait keeps a
        // woken frame aligned to the compositor, so a continuous input stream
        // still renders at vsync rate rather than at input rate.
        if (loop.adaptive_poll.load(.seq_cst)) {
            const demand = slot.demand_ms.load(.seq_cst);
            if (demand != 0) {
                const cap = loop.idle_cap_ms.load(.seq_cst);
                const timeout: u32 = if (demand < 0)
                    cap
                else
                    std.math.clamp(@as(u32, @intCast(demand)), 8, cap);
                if (slot.wake_event) |ev| _ = win32.WaitForSingleObject(ev, timeout);
                if (!slot.running.load(.seq_cst)) return;
            }
        }
        if (win32.DwmFlush() != 0) {
            win32.Sleep(8);
        }
        _ = win32.PostThreadMessageW(loop.gui_thread_id, loop.WM_VSYNC, token, 0);
    }
}
