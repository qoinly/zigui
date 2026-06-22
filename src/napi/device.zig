// Device status: battery charge/charging and the active network. Read-only queries
// an app polls each frame; a miss reads as the safe default (0% / not charging /
// offline / none).
const p = @import("platform.zig");
const impl = p.domain("device");

pub const Network = enum { none, wifi, cellular, other };

// Battery charge in [0,100]; 0 when the level is unknown.
pub fn battery_level() u8 {
    if (@hasDecl(impl, "battery_level")) return impl.battery_level();
    p.unsupported("device.battery_level");
}
// Whether the battery is charging right now.
pub fn charging() bool {
    if (@hasDecl(impl, "charging")) return impl.charging();
    p.unsupported("device.charging");
}
// Whether the active network can reach the internet.
pub fn online() bool {
    if (@hasDecl(impl, "online")) return impl.online();
    p.unsupported("device.online");
}
// The active network's transport, or .none when offline.
pub fn network() Network {
    if (@hasDecl(impl, "network_code")) return @enumFromInt(impl.network_code());
    p.unsupported("device.network");
}
// The running app's own version string (iOS CFBundleShortVersionString, Android
// versionName) copied into buf; empty when unavailable.
pub fn app_version(buf: []u8) []const u8 {
    if (@hasDecl(impl, "app_version")) return impl.app_version(buf);
    p.unsupported("device.app_version");
}
