// Internal glue between the app message loop (consumer) and display-link vsync
// threads (producers). Threads only signal; registered paint callbacks run on
// the GUI thread inside run_forever, keeping all D3D11 + HWND work single-threaded.

const std = @import("std");
const win32 = @import("win32.zig");

pub const WM_VSYNC: win32.UINT = win32.WM_APP + 1;
pub const MAX_VSYNC_LINKS: usize = 16;

pub const VsyncCallback = *const fn (?*anyopaque) callconv(.c) void;

pub const VsyncSlot = struct {
    callback: ?VsyncCallback = null,
    context: ?*anyopaque = null,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

pub var gui_thread_id: win32.DWORD = 0;
pub var vsync_slots: [MAX_VSYNC_LINKS]VsyncSlot = init: {
    var slots: [MAX_VSYNC_LINKS]VsyncSlot = undefined;
    for (&slots) |*slot| slot.* = .{};
    break :init slots;
};
// Set while the Win32 modal resize/move loop runs. Paint is driven synchronously
// from WM_SIZE then, so the vsync thread must stop posting WM_VSYNC: a posted
// message outranks input in GetMessage, and the flood would starve the mouse-move
// input that drives the resize, making the drag stutter.
pub var resizing: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
// Set on WM_DESTROY: stops the vsync thread flooding WM_VSYNC (so WM_QUIT is not
// starved) and tells the loop to skip painting a window that is going away.
pub var quitting: bool = false;

pub fn alloc_vsync_slot(callback: VsyncCallback, context: ?*anyopaque) ?usize {
    std.debug.assert(@intFromPtr(callback) != 0);
    for (&vsync_slots, 0..) |*slot, i| {
        if (slot.callback != null) continue;
        std.debug.assert(!slot.running.load(.seq_cst));
        slot.callback = callback;
        slot.context = context;
        return i + 1;
    }
    return null;
}

pub fn get_vsync_slot(token: usize) ?*VsyncSlot {
    if (token == 0 or token > MAX_VSYNC_LINKS) return null;
    return &vsync_slots[token - 1];
}

pub fn free_vsync_slot(token: usize) void {
    const slot = get_vsync_slot(token) orelse return;
    slot.running.store(false, .seq_cst);
    slot.callback = null;
    slot.context = null;
}

pub fn stop_all_vsync() void {
    for (&vsync_slots) |*slot| {
        slot.running.store(false, .seq_cst);
    }
}
