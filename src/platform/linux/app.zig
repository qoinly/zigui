// run_forever owns a poll loop over the display fd: protocol listeners AND the
// display-link ticks all run on this one thread, so rendering stays
// single-threaded - the same contract the Windows message loop keeps.

const std = @import("std");
const wl = @import("wayland.zig");
const xcb = @import("xcb.zig");
const loop = @import("loop.zig");
const backend = @import("backend.zig");
const shell = @import("custom_shell.zig");
const x11_shell = @import("x11_shell.zig");
const paint = @import("../../window/paint.zig");

const pollfd = extern struct { fd: i32, events: i16, revents: i16 };
extern "c" fn poll(fds: [*]pollfd, count: c_ulong, timeout_ms: c_int) c_int;
const POLLIN: i16 = 1;
// Tick cadence: ~120Hz polling halves worst-case input latency vs one display
// frame; an idle tick costs two reads and a dirty check, and the FIFO
// swapchain paces real presents to the refresh rate.
const TICK_MS: c_int = 8;

// Adaptive idle poll (X11). When enabled (default) the loop sleeps up to
// `g_idle_cap_ms` between wakeups while nothing animates, instead of the fixed
// TICK_MS — cutting idle wakeups from ~125/s to a few/s. An active animation still
// polls at TICK_MS for vsync-rate frames, and a scheduled redraw (caret blink,
// resource meter) is honoured within the cap. X11 autorepeat is server-side, so a
// held key still wakes the poll via its fd. Runtime-settable via set_idle_poll; the
// interval is floored so it can never be tuned into a busy-spin.
const IDLE_CAP_FLOOR_MS: c_int = 32;
const IDLE_CAP_CEIL_MS: c_int = 10_000;
var g_adaptive_poll: bool = true;
var g_idle_cap_ms: c_int = 250;

// Toggle adaptive idle polling and set the idle wakeup interval (ms). The interval
// is clamped to [32, 10000] so a caller can never request a busy-spin.
pub fn set_idle_poll(enabled: bool, interval_ms: u32) void {
    g_adaptive_poll = enabled;
    const req: c_int = @intCast(@min(interval_ms, @as(u32, @intCast(IDLE_CAP_CEIL_MS))));
    g_idle_cap_ms = std.math.clamp(req, IDLE_CAP_FLOOR_MS, IDLE_CAP_CEIL_MS);
}

// The next poll timeout from the render layer's reported state (set during the
// prior tick_all): TICK_MS while animating, the nearest scheduled redraw clamped
// into [TICK_MS, cap] otherwise, or the full cap when fully idle.
fn adaptive_timeout() c_int {
    if (!g_adaptive_poll) return TICK_MS;
    if (paint.wants_fast_poll) return TICK_MS;
    if (paint.soonest_deadline_ms < 0) return g_idle_cap_ms;
    return std.math.clamp(@as(c_int, paint.soonest_deadline_ms), TICK_MS, g_idle_cap_ms);
}

pub const ActivationPolicy = enum { regular, accessory, prohibited };

pub const Error = error{InitFailed};

pub const App = struct {
    pub fn init() Error!App {
        backend.resolve() catch return error.InitFailed;
        if (backend.active == .wayland) {
            std.debug.assert(wl.conn.display != null);
            std.debug.assert(wl.conn.compositor != null);
        } else {
            std.debug.assert(xcb.conn != null);
        }
        return .{};
    }

    pub fn deinit(self: App) void {
        _ = self;
        switch (backend.active) {
            .wayland => wl.disconnect(),
            .x11 => xcb.disconnect(),
        }
    }

    // No dock/activation concept on Linux; kept for API parity.
    pub fn set_activation_policy(self: App, policy: ActivationPolicy) void {
        _ = self;
        _ = policy;
    }

    // No app menu bar on Linux; kept for API parity so shared examples compile.
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
        switch (backend.active) {
            .wayland => run_wayland(),
            .x11 => run_x11(),
        }
    }

    fn run_wayland() void {
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
            shell.tick_key_repeat();
            loop.tick_all();
        }
    }

    fn run_x11() void {
        std.debug.assert(xcb.conn != null);
        std.debug.assert(!x11_shell.quit_requested);
        var timeout: c_int = 0; // render the first frame immediately
        while (!x11_shell.quit_requested) {
            xcb.flush();
            var fds = [_]pollfd{.{ .fd = xcb.connection_fd(), .events = POLLIN, .revents = 0 }};
            _ = poll(&fds, 1, timeout);
            x11_shell.process_events();
            shell.tick_key_repeat();
            // The render layer reports its wakeup needs during tick_all; reset the
            // signals first, then size the next sleep from what it asked for.
            paint.wants_fast_poll = false;
            paint.soonest_deadline_ms = -1;
            loop.tick_all();
            timeout = adaptive_timeout();
        }
    }

    pub fn quit(self: App) void {
        _ = self;
        switch (backend.active) {
            .wayland => {
                std.debug.assert(wl.conn.display != null);
                wl.quit_requested = true;
                wl.flush();
            },
            .x11 => {
                x11_shell.quit_requested = true;
            },
        }
    }
};
