// iOS native-api aggregate: the APIs this target supports (UIKit/Foundation via the
// shared objc runtime). The facade compile-errors on any napi call not exposed here.
pub const haptics = @import("haptics.zig");
pub const clipboard = @import("clipboard.zig");
pub const links = @import("links.zig");
pub const device = @import("device.zig");
pub const picker = @import("picker.zig");
