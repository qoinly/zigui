const builtin = @import("builtin");

const impl = switch (builtin.os.tag) {
    .macos => @import("platform/macos/metal.zig"),
    .windows => @import("platform/windows/d3d11_renderer.zig"),
    else => @compileError("zigui: unsupported OS for renderer"),
};

pub const Renderer = impl.Renderer;
pub const ClearColor = if (builtin.os.tag == .macos) impl.MTLClearColor else impl.ClearColor;

// Drawables the backend keeps in flight; the external-frame texture ring sizes
// itself off this so it never overwrites a slot the GPU is still reading.
pub const max_frames_in_flight = impl.max_frames_in_flight;
