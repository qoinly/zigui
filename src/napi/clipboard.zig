// Plain-text clipboard, plus an external-change poll for a remote-control loop.
const p = @import("platform.zig");
const impl = p.domain("clipboard");

pub fn read(buf: []u8) []const u8 {
    if (@hasDecl(impl, "read")) return impl.read(buf);
    p.unsupported("clipboard.read");
}
pub fn write(text: []const u8) void {
    if (@hasDecl(impl, "write")) impl.write(text) else p.unsupported("clipboard.write");
}
pub fn changed() bool {
    if (@hasDecl(impl, "changed")) return impl.changed();
    p.unsupported("clipboard.changed");
}
