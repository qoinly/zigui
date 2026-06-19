// Display properties this desktop backs. keep_awake reuses the shell's idle-sleep
// inhibitor; status-bar tint and immersive have no desktop equivalent (absent here,
// so the facade compile-errors if a caller uses them on windows).
const cs = @import("../custom_shell.zig");
pub fn keep_awake(on: bool) void {
    cs.set_keep_awake(on);
}
