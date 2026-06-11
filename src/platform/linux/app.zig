// run_forever blocks in wl_display_dispatch; every protocol listener runs on
// this thread, so all rendering stays single-threaded - the same contract the
// Windows message loop keeps.

const std = @import("std");
const wl = @import("wayland.zig");

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
            // dispatch blocks until events arrive; quit is set by a listener on
            // this thread, so the flag is re-checked right after it could flip.
            const rc = wl.dispatch();
            if (rc < 0) break; // the compositor hung up: treat as quit
        }
    }

    pub fn quit(self: App) void {
        _ = self;
        std.debug.assert(wl.conn.display != null);
        wl.quit_requested = true;
        wl.flush();
    }
};
