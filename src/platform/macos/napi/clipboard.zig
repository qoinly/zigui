// Clipboard via the shell's platform pasteboard.
const cs = @import("../custom_shell.zig");
pub fn read(buf: []u8) []const u8 {
    return cs.pasteboard_read_into(buf);
}
pub fn write(text: []const u8) void {
    cs.pasteboard_write_string(text);
}
pub fn changed() bool {
    return cs.clipboard_changed_external();
}
