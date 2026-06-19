// The system document picker. open_file launches it; take_file reads the chosen
// file's text once, a few frames later.
const p = @import("platform.zig");
const impl = p.domain("picker");

pub fn open_file() void {
    if (@hasDecl(impl, "open_file")) impl.open_file() else p.unsupported("picker.open_file");
}
pub fn take_file(buf: []u8) ?[]const u8 {
    if (@hasDecl(impl, "take_file")) return impl.take_file(buf);
    p.unsupported("picker.take_file");
}
