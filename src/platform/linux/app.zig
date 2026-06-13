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
        while (!x11_shell.quit_requested) {
            xcb.flush();
            var fds = [_]pollfd{.{ .fd = xcb.connection_fd(), .events = POLLIN, .revents = 0 }};
            _ = poll(&fds, 1, TICK_MS);
            x11_shell.process_events();
            shell.tick_key_repeat();
            loop.tick_all();
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
