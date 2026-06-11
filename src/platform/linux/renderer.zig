// Renderer surface for the renderer facade, the windows/window.zig precedent:
// the types exist so root and the test build compile on Linux, and init reports
// Unsupported - nothing draws through this file.

const std = @import("std");

pub const max_frames_in_flight: u32 = 3;

pub const ClearColor = extern struct {
    r: f64,
    g: f64,
    b: f64,
    a: f64,

    pub fn init(r: f32, g: f32, b: f32, a: f32) ClearColor {
        std.debug.assert(a >= 0);
        std.debug.assert(a <= 1);
        return .{ .r = r, .g = g, .b = b, .a = a };
    }
};

pub const Renderer = struct {
    target: ?*anyopaque = null,

    pub const Error = error{Unsupported};

    pub fn init(target: *anyopaque) Error!Renderer {
        _ = target;
        return error.Unsupported;
    }

    pub fn deinit(self: *Renderer) void {
        _ = self;
    }

    pub const Nv12Textures = struct {
        luma: *anyopaque,
        chroma: ?*anyopaque,
        cv_luma: *anyopaque,
        cv_chroma: ?*anyopaque,
        width: u32,
        height: u32,
    };

    // The frame-import surface FrameSource drives. No frame is ever importable
    // here (init never succeeds), so import returns null and the ref-counting
    // entry points are inert.
    pub fn import_nv12(self: *Renderer, pixel_buffer: *anyopaque) ?Nv12Textures {
        _ = self;
        std.debug.assert(@intFromPtr(pixel_buffer) != 0);
        return null;
    }

    pub fn flush_texture_cache(self: *Renderer) void {
        _ = self;
    }

    pub fn release_cv_texture(ref: *anyopaque) void {
        std.debug.assert(@intFromPtr(ref) != 0);
    }

    pub fn retain_surface(pixel_buffer: *anyopaque) void {
        std.debug.assert(@intFromPtr(pixel_buffer) != 0);
    }

    pub fn release_surface(pixel_buffer: *anyopaque) void {
        std.debug.assert(@intFromPtr(pixel_buffer) != 0);
    }

    pub fn request_redraw(self: *Renderer) void {
        _ = self;
    }

    pub fn get_device(self: *Renderer) *anyopaque {
        std.debug.assert(self.target == null);
        unreachable; // init never succeeds, so no caller can hold a Renderer
    }
};
