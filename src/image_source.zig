const std = @import("std");
const renderer = @import("renderer.zig");
const image = @import("image/image.zig");

pub const Rgba = image.Rgba;
pub const DecodeError = image.Error;

// A static image on the GPU, modelled on FrameSource but for one non-changing RGBA texture:
// the pixels are decoded/uploaded once and the CPU copy is dropped, so it stays memory-light.
// Must not move after the first draw (the node holds a pointer into it); keep it App-owned.
pub const ImageSource = struct {
    gpa: std.mem.Allocator,
    bgra: ?[]u8, // owned; freed after the GPU upload
    width: u32,
    height: u32,
    tex: ?*anyopaque = null, // backend texture handle (created lazily on the render thread)

    // Decode encoded bytes (PNG or baseline JPEG) into an image source.
    pub fn decode(gpa: std.mem.Allocator, bytes: []const u8) DecodeError!ImageSource {
        const img = try image.decode(gpa, bytes);
        defer img.deinit(gpa);
        return init_rgba(gpa, img.pixels, img.width, img.height);
    }

    // Take already-decoded 8-bit RGBA pixels (width*height*4). Copies into a BGRA buffer the
    // GPU upload wants; `rgba` is not retained.
    pub fn init_rgba(gpa: std.mem.Allocator, rgba: []const u8, width: u32, height: u32) DecodeError!ImageSource {
        const n = @as(usize, width) * height * 4;
        if (rgba.len < n) return error.InvalidPng;
        const bgra = try gpa.alloc(u8, n);
        var i: usize = 0;
        while (i < n) : (i += 4) {
            bgra[i] = rgba[i + 2]; // B
            bgra[i + 1] = rgba[i + 1]; // G
            bgra[i + 2] = rgba[i]; // R
            bgra[i + 3] = rgba[i + 3]; // A
        }
        return .{ .gpa = gpa, .bgra = bgra, .width = width, .height = height };
    }

    // Frees the CPU copy and destroys the GPU texture. Call it when the image is no longer on
    // screen (the App owns the lifetime).
    pub fn deinit(self: *ImageSource) void {
        if (self.tex) |t| renderer.Renderer.destroy_image_texture(t);
        if (self.bgra) |b| self.gpa.free(b);
        self.* = undefined;
    }

    // Render-thread: create the GPU texture on first use, then drop the CPU pixels. Returns the
    // sampleable texture handle, or null while it cannot be created.
    pub fn acquire(self: *ImageSource, r: *renderer.Renderer) ?*anyopaque {
        if (self.tex == null) {
            const b = self.bgra orelse return null;
            self.tex = r.create_image_texture(b, self.width, self.height) orelse return null;
            self.gpa.free(b);
            self.bgra = null;
        }
        return renderer.Renderer.image_texture_view(self.tex.?);
    }

    pub fn dims(self: *const ImageSource) [2]f32 {
        return .{ @floatFromInt(self.width), @floatFromInt(self.height) };
    }
};
