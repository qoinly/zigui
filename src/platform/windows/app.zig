// run_forever pumps the Win32 message queue and, on the display-link vsync
// signal (delivered as a thread message), runs the paint callback on this (the
// GUI) thread - so all rendering stays single-threaded.

const std = @import("std");
const win32 = @import("win32.zig");
const loop = @import("loop.zig");

pub const ActivationPolicy = enum { regular, accessory, prohibited };

pub const Error = error{InitFailed};

pub const App = struct {
    pub fn init() Error!App {
        // Per-monitor DPI v2 so client metrics and the swapchain are in real
        // device pixels on mixed-DPI setups.
        _ = win32.SetProcessDpiAwarenessContext(win32.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        loop.gui_thread_id = win32.GetCurrentThreadId();
        return .{};
    }

    pub fn deinit(self: App) void {
        _ = self;
    }

    // No dock/activation concept on Windows; kept for API parity.
    pub fn set_activation_policy(self: App, policy: ActivationPolicy) void {
        _ = self;
        _ = policy;
    }

    // No app menu bar on Windows; kept for API parity so shared examples compile.
    pub fn install_edit_menu(self: App) void {
        _ = self;
    }

    // No-op on Windows: the custom shell's WM_DESTROY already posts quit, so
    // closing the window ends run_forever. Kept for API parity.
    pub fn quit_on_last_window_closed(self: App) void {
        _ = self;
    }

    pub fn run_forever(self: App) void {
        _ = self;
        std.debug.assert(loop.gui_thread_id == win32.GetCurrentThreadId());
        var msg: win32.MSG = undefined;
        while (true) {
            const rc = win32.GetMessageW(&msg, null, 0, 0);
            std.debug.assert(rc != -1); // -1 = error (bad msg/hwnd ptr), a programmer bug
            if (rc <= 0) break; // 0 = WM_QUIT
            if (msg.hwnd == null and msg.message == loop.WM_VSYNC) {
                // Skip a residual vsync tick once the window is going away.
                if (!loop.quitting) {
                    pump_input();
                    // pump_input can dispatch a caption close (WM_NCLBUTTONUP ->
                    // DestroyWindow -> WM_DESTROY), which sets quitting; re-check so
                    // a tick never paints a window that is already going away.
                    if (!loop.quitting) {
                        const token: usize = @intCast(msg.wParam);
                        if (loop.get_vsync_slot(token)) |slot| {
                            if (slot.running.load(.seq_cst)) {
                                if (slot.callback) |cb| cb(slot.context);
                            }
                        }
                    }
                }
                continue;
            }
            _ = win32.TranslateMessage(&msg);
            _ = win32.DispatchMessageW(&msg);
        }
    }

    pub fn quit(self: App) void {
        _ = self;
        win32.PostQuitMessage(0);
    }
};

// A posted WM_VSYNC outranks queued input in GetMessage, so an animating window
// (which requests a repaint every vsync) floods WM_VSYNC and starves mouse +
// keyboard messages: the window keeps painting but never dequeues a click, and
// even the close button stops responding. Pump pending input ahead of each
// paint so input is never starved. Narrow ranges (keys, non-client + client
// mouse) so only real input is pulled forward, not WM_COMMAND/WM_SYSCOMMAND.
const INPUT_DRAIN_MAX: u32 = 256;

fn pump_input() void {
    std.debug.assert(loop.gui_thread_id != 0); // GUI-thread only
    pump_input_range(win32.WM_KEYFIRST, win32.WM_KEYLAST);
    pump_input_range(win32.WM_NCMOUSEFIRST, win32.WM_NCMOUSELAST);
    pump_input_range(win32.WM_MOUSEFIRST, win32.WM_MOUSELAST);
}

fn pump_input_range(message_min: win32.UINT, message_max: win32.UINT) void {
    std.debug.assert(message_min <= message_max);
    var msg: win32.MSG = undefined;
    var drained: u32 = 0;
    while (drained < INPUT_DRAIN_MAX) : (drained += 1) {
        if (win32.PeekMessageW(&msg, null, message_min, message_max, win32.PM_REMOVE) == 0) break;
        _ = win32.TranslateMessage(&msg);
        _ = win32.DispatchMessageW(&msg);
    }
    std.debug.assert(drained <= INPUT_DRAIN_MAX);
}
