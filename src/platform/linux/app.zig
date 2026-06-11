// run_forever owns a poll loop over the display fd: protocol listeners AND the
// display-link ticks all run on this one thread, so rendering stays
// single-threaded - the same contract the Windows message loop keeps.

const std = @import("std");
const wl = @import("wayland.zig");
const loop = @import("loop.zig");

const pollfd = extern struct { fd: i32, events: i16, revents: i16 };
extern "c" fn poll(fds: [*]pollfd, count: c_ulong, timeout_ms: c_int) c_int;
const POLLIN: i16 = 1;
// Tick cadence: ~120Hz polling halves worst-case input latency vs one display
// frame; an idle tick costs two reads and a dirty check, and the FIFO
// swapchain paces real presents to the refresh rate.
const TICK_MS: c_int = 8;

pub const ActivationPolicy = enum { regular, accessory, prohibited };

pub const Error = error{InitFailed};

pub const App = struct {
    pub fn init() Error!App {
        wl.connect() catch return error.InitFailed;
        std.debug.assert(wl.conn.display != null);
        std.debug.assert(wl.conn.compositor != null);
        return .{};
    }

    pub fn deinit(self: App) void {
        _ = self;
        wl.disconnect();
    }

    // No dock/activation concept on Wayland; kept for API parity.
    pub fn set_activation_policy(self: App, policy: ActivationPolicy) void {
        _ = self;
        _ = policy;
    }

    // No app menu bar on Wayland; kept for API parity so shared examples compile.
    pub fn install_edit_menu(self: App) void {
        _ = self;
    }

    // No-op: the custom shell's close path already requests quit for the first
    // window, so closing it ends run_forever. Kept for API parity.
    pub fn quit_on_last_window_closed(self: App) void {
        _ = self;
    }

    pub fn run_forever(self: App) void {
        _ = self;
        std.debug.assert(wl.conn.display != null);
        std.debug.assert(!wl.quit_requested);
        while (!wl.quit_requested) {
            // prepare_read drains queued events first; quit is set by listeners
            // on this thread, so the flag is re-checked every iteration.
            if (!wl.prepare_read()) break; // the compositor hung up: treat as quit
            wl.flush();
            var fds = [_]pollfd{.{ .fd = wl.display_fd(), .events = POLLIN, .revents = 0 }};
            const rc = poll(&fds, 1, TICK_MS);
            if (rc > 0 and (fds[0].revents & POLLIN) != 0) {
                wl.read_events();
            } else {
                wl.cancel_read();
            }
            loop.tick_all();
        }
    }

    pub fn quit(self: App) void {
        _ = self;
        std.debug.assert(wl.conn.display != null);
        wl.quit_requested = true;
        wl.flush();
    }
};
