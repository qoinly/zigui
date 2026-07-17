const std = @import("std");
const png = @import("png.zig");
const jpeg = @import("jpeg.zig");

pub const Rgba = @import("pixels.zig").Rgba;

pub const Format = enum { png, jpeg, unknown };

pub fn detect(bytes: []const u8) Format {
    if (bytes.len >= 8 and std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n")) return .png;
    if (bytes.len >= 3 and bytes[0] == 0xFF and bytes[1] == 0xD8 and bytes[2] == 0xFF) return .jpeg;
    return .unknown;
}

pub const Error = error{UnknownFormat} || png.Error || jpeg.Error;

// Decode an encoded image (PNG or baseline JPEG) into 8-bit RGBA. Caller frees `pixels`.
pub fn decode(gpa: std.mem.Allocator, bytes: []const u8) Error!Rgba {
    return switch (detect(bytes)) {
        .png => png.decode(gpa, bytes),
        .jpeg => jpeg.decode(gpa, bytes),
        .unknown => error.UnknownFormat,
    };
}

test {
    _ = png;
    _ = jpeg;
}

test "detect routes png and jpeg by magic bytes" {
    try std.testing.expectEqual(Format.png, detect(@embedFile("testdata/rgb_3x2.png")));
    try std.testing.expectEqual(Format.jpeg, detect(@embedFile("testdata/rgb_16.jpg")));
    try std.testing.expectEqual(Format.unknown, detect("not an image"));
}
