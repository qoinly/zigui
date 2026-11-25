// Fold posture of a foldable device. On Android it comes from the OEM window-layout
// extension (androidx.window.extensions) - the same source the androidx.window library
// reads, present on foldables and the foldable emulator - reached by reflection, so no
// library is bundled. A view uses it to adapt layout to the fold: `flat` is open/normal,
// `half` is propped open (tabletop / book posture). Non-foldables and desktop stay `flat`,
// so they behave exactly as before. Dependency-free: only the android bridge writes it.
const std = @import("std");
const builtin = @import("builtin");

const is_android = builtin.abi == .android;

pub const Posture = enum { flat, half };

var g_present: bool = false;
var g_half: bool = false;
var g_force: ?Posture = null; // debug-build test override (see poll)

// The window-layout bridge calls this with the FoldingFeature state (STATE_FLAT = 1,
// STATE_HALF_OPENED = 2; 0 = no folding feature this frame, i.e. flat).
pub fn on_state(state: i32) void {
    g_present = true;
    g_half = state == 2;
}

// Whether the window-layout extension has reported at least once (i.e. this is a foldable).
pub fn present() bool {
    return g_present;
}

pub fn posture() Posture {
    if (g_force) |p| return p;
    return if (g_present and g_half) .half else .flat;
}

// Debug builds only: let `adb shell setprop debug.zigui.fold half|flat` force the posture,
// so fold-adaptive layouts can be exercised without a foldable (and on emulators whose
// hinge sensor does not report a usable angle). Called once per render. No-op in release.
pub fn poll() void {
    if (comptime builtin.mode != .debug or !is_android) return;
    var buf: [96]u8 = undefined;
    const n = __system_property_get("debug.zigui.fold", @ptrCast(&buf));
    if (n <= 0) {
        g_force = null;
        return;
    }
    const s = buf[0..@intCast(n)];
    g_force = if (std.mem.indexOf(u8, s, "half") != null)
        .half
    else if (std.mem.indexOf(u8, s, "flat") != null)
        .flat
    else
        null;
}

extern fn __system_property_get(name: [*:0]const u8, value: [*:0]u8) c_int;
