const std = @import("std");

// Decoded 8-bit RGBA image, the common output of the PNG and JPEG decoders.
pub const Rgba = struct {
    width: u32,
    height: u32,
    pixels: []u8, // width*height*4, RGBA8; caller frees with the decoding allocator

    pub fn deinit(self: Rgba, gpa: std.mem.Allocator) void {
        gpa.free(self.pixels);
    }
};
