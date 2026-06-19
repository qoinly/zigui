const builtin = @import("builtin");

// Android is os.tag == .linux, abi == .android; its app model (NativeActivity
// lifecycle, no main()) is distinct from the desktop Linux arm, so it gets its
// own file picked at comptime ahead of the os.tag switch.
const impl = if (builtin.abi.isAndroid())
    @import("platform/android/app.zig")
else switch (builtin.os.tag) {
    .macos => @import("platform/macos/app.zig"),
    .ios => @import("platform/ios/app.zig"),
    .windows => @import("platform/windows/app.zig"),
    .linux => @import("platform/linux/app.zig"),
    else => @compileError("zigui: unsupported OS for app"),
};

pub const App = impl.App;
pub const ActivationPolicy = impl.ActivationPolicy;
pub const Error = impl.Error;
