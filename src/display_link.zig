const builtin = @import("builtin");

// Android's vsync source is AChoreographer, not the Linux poll-loop cadence, so
// it gets its own arm ahead of the os.tag switch (Android is os.tag == .linux).
const impl = if (builtin.abi.isAndroid())
    @import("platform/android/display_link.zig")
else switch (builtin.os.tag) {
    .macos => @import("platform/macos/display_link.zig"),
    .ios => @import("platform/ios/display_link.zig"),
    .windows => @import("platform/windows/display_link.zig"),
    .linux => @import("platform/linux/display_link.zig"),
    else => @compileError("zigui: unsupported OS for display_link"),
};

pub const DisplayLink = impl.DisplayLink;
pub const Error = impl.Error;
pub const PaintCallback = impl.dispatch_function_t;
pub const DisplayId = impl.CGDirectDisplayID;
pub const get_main_display_id = impl.get_main_display_id;
