// Fold posture of a foldable device, read from the platform hinge-angle sensor (on
// Android, Sensor.TYPE_HINGE_ANGLE). A view uses it to adapt layout to the fold: `flat`
// is open/normal, `half` is propped open (tabletop / book posture). Devices with no hinge
// sensor stay `flat`, so non-foldables and desktop behave exactly as before. Cross-platform
// and dependency-free: the android bridge feeds `on_angle`, nothing else writes it.

pub const Posture = enum { flat, half, closed };

var g_present: bool = false;
var g_angle: f32 = 180; // degrees: 0 = closed, 180 = flat open

// The hinge-angle sensor bridge calls this with the latest reading. Some devices and
// emulators report an invalid sentinel (e.g. -1e30 "no reading") rather than a real angle;
// ignore anything outside a plausible hinge range so posture stays flat there instead of
// flipping on garbage.
pub fn on_angle(angle: f32) void {
    if (!(angle >= 0 and angle <= 360)) return;
    g_present = true;
    g_angle = angle;
}

// Whether a hinge-angle sensor has reported at least once (i.e. this is a foldable).
pub fn present() bool {
    return g_present;
}

pub fn posture() Posture {
    if (!g_present) return .flat;
    if (g_angle <= 30) return .closed;
    if (g_angle < 150) return .half;
    return .flat;
}
