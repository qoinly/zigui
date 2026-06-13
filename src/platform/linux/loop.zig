// Internal glue between run_forever's poll loop (consumer) and display links
// (producers). Everything is single-threaded: ticks run inline from the poll
// loop between dispatch rounds, so all Vulkan + Wayland work stays on the one
// thread - the windows loop.zig contract without the thread hop.

const std = @import("std");

pub const MAX_VSYNC_LINKS: u32 = 16;

pub const VsyncCallback = *const fn (?*anyopaque) callconv(.c) void;

pub const VsyncSlot = struct {
    callback: ?VsyncCallback = null,
    context: ?*anyopaque = null,
    running: bool = false,
};

pub var vsync_slots: [MAX_VSYNC_LINKS]VsyncSlot = [_]VsyncSlot{.{}} ** MAX_VSYNC_LINKS;

pub fn alloc_vsync_slot(callback: VsyncCallback, context: ?*anyopaque) ?u32 {
    std.debug.assert(@intFromPtr(callback) != 0);
    var index: u32 = 0;
    while (index < MAX_VSYNC_LINKS) : (index += 1) {
        const slot = &vsync_slots[index];
        if (slot.callback != null) continue;
        std.debug.assert(!slot.running);
        slot.callback = callback;
        slot.context = context;
        return index + 1;
    }
    return null;
}

pub fn get_vsync_slot(token: u32) ?*VsyncSlot {
    std.debug.assert(token != 0);
    if (token > MAX_VSYNC_LINKS) return null;
    return &vsync_slots[token - 1];
}

pub fn free_vsync_slot(token: u32) void {
    std.debug.assert(token != 0);
    const slot = get_vsync_slot(token) orelse return;
    slot.running = false;
    slot.callback = null;
    slot.context = null;
}

pub fn tick_all() void {
    std.debug.assert(vsync_slots.len == MAX_VSYNC_LINKS);
    for (&vsync_slots) |*slot| {
        if (!slot.running) continue;
        if (slot.callback) |cb| cb(slot.context);
    }
}
