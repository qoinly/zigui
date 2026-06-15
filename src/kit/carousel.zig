// The onboarding carousel state + gesture machine. The carousel pages across N
// full-width slides; the caller owns this state (one per carousel) so two never
// clobber each other, the same contract as ScrollState / SliderState. The node tree
// (slides, dots, Skip / Next / Finish) is built by zigui.carousel; this file holds
// only the state and the drag/advance callbacks the hit-test routes input through.

const std = @import("std");

pub const CarouselState = struct {
    index: usize = 0, // the settled slide
    // The live horizontal offset in px relative to `index` (0 = settled on it). While
    // dragging it follows the finger; on release/advance it eases back to 0.
    dx: f32 = 0,
    dragging: bool = false,
    drag_start: f32 = 0,
    // Snapshotted by zigui.carousel each render so the input callbacks (which fire
    // between frames) have the geometry to map a raw drag to a slide.
    width: f32 = 0,
    count: usize = 1,
};

// A drag move - and the initial press, which is the first call after the hit-test
// captures this as the drag target. The press records the start; later moves track
// the offset, resisted past the first/last slide so an over-drag springs back.
pub fn on_drag(ctx: ?*anyopaque, x: f32, y: f32) void {
    _ = y;
    const s: *CarouselState = @ptrCast(@alignCast(ctx.?));
    std.debug.assert(s.width > 0); // a render set the geometry before any drag
    std.debug.assert(s.count >= 1);
    if (!s.dragging) {
        s.dragging = true;
        s.drag_start = x;
        s.dx = 0;
        return;
    }
    var d = x - s.drag_start;
    if (s.index == 0 and d > 0) d *= 0.3; // resist before the first slide
    if (s.index + 1 >= s.count and d < 0) d *= 0.3; // resist past the last
    s.dx = d;
}

// Release: a drag past a third of the width advances to the neighbour (the visual
// stays continuous - dx carries +/- width, then eases to 0 next frames); a shorter
// drag springs back to the current slide.
pub fn on_release(ctx: ?*anyopaque) void {
    const s: *CarouselState = @ptrCast(@alignCast(ctx.?));
    std.debug.assert(s.width > 0); // a render set the geometry before any release
    std.debug.assert(s.index < s.count);
    s.dragging = false;
    const threshold = s.width / 3;
    if (s.dx <= -threshold and s.index + 1 < s.count) {
        s.index += 1;
        s.dx += s.width;
    } else if (s.dx >= threshold and s.index > 0) {
        s.index -= 1;
        s.dx -= s.width;
    }
}

// The Next button: advance one slide with the same continuity as a drag-advance.
pub fn go_next(ctx: ?*anyopaque) void {
    const s: *CarouselState = @ptrCast(@alignCast(ctx.?));
    std.debug.assert(s.width > 0); // a render set the geometry before any tap
    std.debug.assert(s.index < s.count);
    if (s.index + 1 < s.count) {
        s.index += 1;
        s.dx += s.width;
    }
}
