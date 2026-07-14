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
    // Frame demand the GUI thread publishes after each tick: 0 = keep vsync
    // pacing (animating / follow-up frame pending), -1 = fully idle, >0 = a
    // scheduled redraw this many ms out. Starts at 0 so a fresh link paces at
    // vsync until its first tick reports.
    demand_ms: std.atomic.Value(i32) = std.atomic.Value(i32).init(0),
    // Auto-reset; snaps the vsync thread out of its idle wait when input lands,
    // a redraw is requested, or the link stops. Created once per slot and kept
    // for process life (16 handles at most), so no close/wait race exists.
    wake_event: ?win32.HANDLE = null,
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
        slot.demand_ms.store(0, .seq_cst);
        // A null event just disables the idle wait for this slot (pure vsync
        // pacing), so creation failure degrades to the old behavior.
        if (slot.wake_event == null) slot.wake_event = win32.CreateEventW(null, win32.FALSE, win32.FALSE, null);
        return i + 1;
    }
    return null;
}

pub fn get_vsync_slot(token: usize) ?*VsyncSlot {
    std.debug.assert(token != 0);
    return maybe_vsync_slot(token);
}

pub fn maybe_vsync_slot(token: usize) ?*VsyncSlot {
    if (token == 0 or token > MAX_VSYNC_LINKS) return null;
    return &vsync_slots[token - 1];
}

pub fn free_vsync_slot(token: usize) void {
    std.debug.assert(token != 0);
    const slot = get_vsync_slot(token) orelse return;
    slot.running.store(false, .seq_cst);
    if (slot.wake_event) |ev| _ = win32.SetEvent(ev); // snap an idle wait so the thread exits now
    slot.callback = null;
    slot.context = null;
}

pub fn stop_all_vsync() void {
    std.debug.assert(vsync_slots.len == MAX_VSYNC_LINKS);
    for (&vsync_slots) |*slot| {
        slot.running.store(false, .seq_cst);
        if (slot.wake_event) |ev| _ = win32.SetEvent(ev);
    }
}

// Adaptive idle poll. When enabled (the default) and the last tick reported
// nothing animating, the vsync thread parks on the slot's wake event - up to
// the cap, or the next scheduled redraw - instead of pacing on DwmFlush. That
// cuts idle wakeups from refresh rate (165/s on a fast panel, x2 threads) to a
// few per second. Input and redraw requests set the event, so the first frame
// after a wake still lands within one compositor frame. The interval clamp
// matches the X11 loop so it can never be tuned into a busy-spin.
const IDLE_CAP_FLOOR_MS: u32 = 32;
const IDLE_CAP_CEIL_MS: u32 = 10_000;
pub var adaptive_poll = std.atomic.Value(bool).init(true);
pub var idle_cap_ms = std.atomic.Value(u32).init(250);

pub fn set_idle_poll(enabled: bool, interval_ms: u32) void {
    adaptive_poll.store(enabled, .seq_cst);
    idle_cap_ms.store(std.math.clamp(interval_ms, IDLE_CAP_FLOOR_MS, IDLE_CAP_CEIL_MS), .seq_cst);
    // A cadence change (or re-enable) applies on the next wait; end the current
    // one so a long cap never holds a shorter new one hostage.
    wake_all();
}

// The GUI thread publishes each tick's frame demand for that window's vsync
// thread, keyed by the display-link context (the tick's RunState). Ticks are
// serialized on the GUI thread, so each publish covers exactly its window.
pub fn publish_demand(ctx: *anyopaque, demand_ms: i32) void {
    for (&vsync_slots) |*slot| {
        if (slot.context != @as(?*anyopaque, ctx)) continue;
        slot.demand_ms.store(demand_ms, .seq_cst);
        return;
    }
}

// Wake every idle vsync wait: a redraw was requested or a background job
// finished, and the tick that serves it must not wait out the idle interval.
// SetEvent on an already-set event is a no-op, so dirty-marking paths call this
// unconditionally; a stale wake costs one dirty-checked tick.
pub fn wake_all() void {
    for (&vsync_slots) |*slot| {
        if (slot.callback == null) continue;
        if (slot.wake_event) |ev| _ = win32.SetEvent(ev);
    }
}
