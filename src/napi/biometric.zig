// Biometric authentication (fingerprint / face). authenticate raises the system
// prompt; the app polls result on later frames for the terminal outcome.
const p = @import("platform.zig");
const impl = p.domain("biometric");

pub const Outcome = enum { success, failed };

// Whether the device has an enrolled biometric to prompt for.
pub fn available() bool {
    if (@hasDecl(impl, "available")) return impl.available();
    p.unsupported("biometric.available");
}
// Raise the system biometric prompt with a title and subtitle. The outcome arrives
// asynchronously - poll result on later frames.
pub fn authenticate(title: []const u8, subtitle: []const u8) void {
    if (@hasDecl(impl, "authenticate")) {
        impl.authenticate(title, subtitle);
    } else p.unsupported("biometric.authenticate");
}
// The last prompt's terminal outcome, read once; null until one arrives.
pub fn result() ?Outcome {
    if (@hasDecl(impl, "take_result")) {
        const code = impl.take_result() orelse return null;
        return if (code == 1) .success else .failed;
    }
    p.unsupported("biometric.result");
}
