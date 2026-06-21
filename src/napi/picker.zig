// The system file picker. open_file launches it; pending() reports whether a pick is in
// flight (drive a spinner off it - and, since a spinner keeps the loop animating, the
// result lands the moment the pick finishes); take_file yields the chosen file's name
// plus a local path (the picker imports a copy the app can read) once, a few frames
// later. The returned slices live until the next open_file/take_file.
const p = @import("platform.zig");
const impl = p.domain("picker");

pub const PickedFile = @import("picker_types.zig").PickedFile;

pub fn open_file() void {
    if (@hasDecl(impl, "open_file")) impl.open_file() else p.unsupported("picker.open_file");
}
pub fn pending() bool {
    if (@hasDecl(impl, "pending")) return impl.pending();
    p.unsupported("picker.pending");
}
pub fn take_file() ?PickedFile {
    if (@hasDecl(impl, "take_file")) return impl.take_file();
    p.unsupported("picker.take_file");
}
