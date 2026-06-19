// Runtime permissions: poll granted()/status() each frame, request() while not granted.
const p = @import("platform.zig");
const impl = p.domain("permissions");

// granted is the binary fast poll; status splits a denial into never-asked, askable,
// and "don't ask again" (the last only Settings can grant). The order matches the
// platform's 0..3 code.
pub const Status = enum { granted, not_requested, declined, declined_permanent };

pub fn granted(name: []const u8) bool {
    if (@hasDecl(impl, "granted")) return impl.granted(name);
    p.unsupported("permissions.granted");
}
pub fn status(name: []const u8) Status {
    if (@hasDecl(impl, "status_code")) return @enumFromInt(impl.status_code(name));
    p.unsupported("permissions.status");
}
pub fn request(name: []const u8) void {
    if (@hasDecl(impl, "request")) impl.request(name) else p.unsupported("permissions.request");
}
// The permissions the manifest declares, read at runtime: a screen drives off the
// manifest instead of hardcoding names. The names are copied into scratch; the
// returned slices point into it.
pub fn declared(out: [][]const u8, scratch: []u8) [][]const u8 {
    if (@hasDecl(impl, "declared")) return impl.declared(out, scratch);
    p.unsupported("permissions.declared");
}
