const builtin = @import("builtin");

const impl = switch (builtin.os.tag) {
    .macos => @import("platform/macos/metal.zig"),
    .windows => @import("platform/windows/d3d11_renderer.zig"),
    else => @compileError("zigui: unsupported OS for renderer"),
};

pub const Renderer = impl.Renderer;
pub const ClearColor = if (builtin.os.tag == .macos) impl.MTLClearColor else impl.ClearColor;
