// Touch input. The framework hands an AInputQueue on onInputQueueCreated;
// attaching it to the main thread's ALooper with a callback drains events as the
// looper runs (the same thread the paint loop and Choreographer live on, so the
// dispatch into the PaintContext needs no synchronization).
//
// A single touch maps onto the pointer dispatch the paint loop already registered
// (custom_shell.mouse_dispatch): down -> on_down (which hit-tests and fires the
// click, the desktop press semantics), up/cancel -> on_up then on_exit (touch has
// no hover, so clear the inside state the down set). A move routes through the
// separate touch-move handler instead, which scrolls the region under the finger
// or drags a press-captured control. Event coordinates are surface pixels; divide
// by the surface scale to reach points. Multi-touch, hover, right-click, and the
// wheel have no touch analogue.

const std = @import("std");
const native = @import("native.zig");
const custom_shell = @import("custom_shell.zig");

pub fn on_queue_created(queue: *native.AInputQueue) void {
    std.debug.assert(@intFromPtr(queue) != 0);
    const looper = native.ALooper_forThread() orelse return; // no looper, no input
    // ident is ignored when a callback is supplied; the callback drains the queue,
    // which carries the queue back as its data arg (no global needed).
    native.AInputQueue_attachLooper(queue, looper, 1, drain, @ptrCast(queue));
}

pub fn on_queue_destroyed(queue: *native.AInputQueue) void {
    std.debug.assert(@intFromPtr(queue) != 0);
    native.AInputQueue_detachLooper(queue);
}

// One looper wake drains a finite burst; cap it the way the x11 backend caps its
// own event drain.
const MAX_DRAIN: u32 = 4096;

// The looper calls this when the queue has events; return 1 to stay registered.
fn drain(fd: c_int, events: c_int, data: ?*anyopaque) callconv(.c) c_int {
    _ = fd;
    _ = events;
    const queue: *native.AInputQueue = @ptrCast(@alignCast(data orelse return 1));
    var event: *native.AInputEvent = undefined;
    var guard: u32 = 0;
    while (native.AInputQueue_getEvent(queue, &event) >= 0) : (guard += 1) {
        std.debug.assert(guard < MAX_DRAIN); // a wake's drain is always finite
        // A nonzero pre-dispatch means the queue will redeliver it (e.g. a key to
        // the IME); do not finish it here.
        if (native.AInputQueue_preDispatchEvent(queue, event) != 0) continue;
        const handled = dispatch(event);
        native.AInputQueue_finishEvent(queue, event, @intFromBool(handled));
    }
    return 1;
}

fn dispatch(event: *native.AInputEvent) bool {
    if (native.AInputEvent_getType(event) != native.AINPUT_EVENT_TYPE_MOTION) return false;
    const d = custom_shell.mouse_dispatch() orelse return false;
    const scale: f32 = @floatFromInt(custom_shell.surface_scale());
    std.debug.assert(scale >= 1);
    const x = native.AMotionEvent_getX(event, 0) / scale;
    const y = native.AMotionEvent_getY(event, 0) / scale;
    switch (native.AMotionEvent_getAction(event) & native.AMOTION_EVENT_ACTION_MASK) {
        native.AMOTION_EVENT_ACTION_DOWN => d.on_down(d.ctx, x, y),
        // Unlike the desktop on_drag, a touch move arbitrates scroll vs captured drag.
        native.AMOTION_EVENT_ACTION_MOVE => {
            if (custom_shell.touch_move()) |tm| tm.cb(tm.ctx, x, y);
        },
        native.AMOTION_EVENT_ACTION_UP, native.AMOTION_EVENT_ACTION_CANCEL => {
            d.on_up(d.ctx);
            d.on_exit(d.ctx); // no hover on touch: clear the inside state down set
        },
        else => return false, // POINTER_DOWN/UP (multi-touch) has no single-pointer map
    }
    return true;
}
