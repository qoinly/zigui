// Runtime permissions: poll granted() each frame, request() while it is false.
const p = @import("platform.zig");
const impl = p.domain("permissions");

pub fn granted(name: []const u8) bool {
    if (@hasDecl(impl, "granted")) return impl.granted(name);
    p.unsupported("permissions.granted");
}
pub fn request(name: []const u8) void {
    if (@hasDecl(impl, "request")) impl.request(name) else p.unsupported("permissions.request");
}
