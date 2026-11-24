// Local secret store: a stable per-alias key, hardware-sealed where the platform
// offers it (Android Keystore). An app uses it to hold the master key for its own
// encrypted storage without ever persisting that key in the clear.
const p = @import("platform.zig");
const impl = p.domain("secure");

// A stable 32-byte key for `alias`, created on first use and returned unchanged after.
// Writes the key into `out` and returns true; false when the platform could not provide
// one (no secure store, or it failed), so the caller keeps secrets unavailable rather
// than using an unstable key.
pub fn get_or_create_key(alias: []const u8, out: *[32]u8) bool {
    if (@hasDecl(impl, "get_or_create_key")) return impl.get_or_create_key(alias, out);
    p.unsupported("secure.get_or_create_key");
}
