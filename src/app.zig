const builtin = @import("builtin");

const impl = switch (builtin.os.tag) {
    .macos => @import("platform/macos/app.zig"),
    .windows => @import("platform/windows/app.zig"),
    else => @compileError("zigui: unsupported OS for app"),
};

pub const App = impl.App;
pub const ActivationPolicy = impl.ActivationPolicy;
pub const Error = impl.Error;
