const builtin = @import("builtin");

const impl = switch (builtin.os.tag) {
    .macos => @import("platform/macos/display_link.zig"),
    .windows => @import("platform/windows/display_link.zig"),
    .linux => @import("platform/linux/display_link.zig"),
    else => @compileError("zigui: unsupported OS for display_link"),
};

pub const DisplayLink = impl.DisplayLink;
pub const Error = impl.Error;
pub const PaintCallback = impl.dispatch_function_t;
pub const DisplayId = impl.CGDirectDisplayID;
pub const get_main_display_id = impl.get_main_display_id;
