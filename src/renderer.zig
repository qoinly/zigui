const builtin = @import("builtin");

const impl = switch (builtin.os.tag) {
    .macos, .ios => @import("platform/macos/metal.zig"),
    .windows => @import("platform/windows/d3d11_renderer.zig"),
    .linux => @import("platform/linux/vulkan_renderer.zig"),
    else => @compileError("zigui: unsupported OS for renderer"),
};

// iOS shares the Metal backend, so it shares its clear-color and surface shapes.
const metal = builtin.os.tag == .macos or builtin.os.tag == .ios;

pub const Renderer = impl.Renderer;
pub const ClearColor = if (metal) impl.MTLClearColor else impl.ClearColor;
// Metal feeds CVPixelBuffers straight from the decoder, so it has no
// renderer-owned surface type.
pub const FrameSurface = if (metal) void else impl.FrameSurface;

// Drawables the backend keeps in flight; the external-frame texture ring sizes
// itself off this so it never overwrites a slot the GPU is still reading.
pub const max_frames_in_flight = impl.max_frames_in_flight;
