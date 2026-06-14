// windows native-api aggregate: the APIs this desktop supports. The facade compile-
// errors on any napi call a target's aggregate does not expose.
pub const display = @import("display.zig");
pub const clipboard = @import("clipboard.zig");
