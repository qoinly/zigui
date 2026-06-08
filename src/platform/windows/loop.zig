// Internal glue between the app message loop (consumer) and the display-link
// vsync thread (producer). The vsync thread only signals; the registered paint
// callback runs on the GUI thread inside run_forever, keeping all D3D11 + HWND
// work single-threaded. State is global because there is one window per process
// (the macOS backend assumes the same).

const std = @import("std");
const win32 = @import("win32.zig");

pub const WM_VSYNC: win32.UINT = win32.WM_APP + 1;

pub var gui_thread_id: win32.DWORD = 0;
// vsync_ctx is an opaque caller token: stored as-is and handed straight back to
// vsync_cb, never cast here (only the callback's owner knows its real type).
pub var vsync_cb: ?*const fn (?*anyopaque) callconv(.c) void = null;
pub var vsync_ctx: ?*anyopaque = null;
pub var vsync_running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
// Set while the Win32 modal resize/move loop runs. Paint is driven synchronously
// from WM_SIZE then, so the vsync thread must stop posting WM_VSYNC: a posted
// message outranks input in GetMessage, and the flood would starve the mouse-move
// input that drives the resize, making the drag stutter.
pub var resizing: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
// Set on WM_DESTROY: stops the vsync thread flooding WM_VSYNC (so WM_QUIT is not
// starved) and tells the loop to skip painting a window that is going away.
pub var quitting: bool = false;
