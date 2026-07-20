const std = @import("std");

// A tiny PNG decoder (no external deps). Produces 8-bit RGBA. Supports the common
// non-interlaced 8-bit color types (grayscale, RGB, palette, gray+alpha, RGBA) with
// tRNS transparency; interlaced and 16-bit PNGs are reported Unsupported for now.

pub const Rgba = @import("pixels.zig").Rgba;

pub const Error = error{ InvalidPng, Unsupported } || std.mem.Allocator.Error;

const signature = "\x89PNG\r\n\x1a\n";

pub fn decode(gpa: std.mem.Allocator, bytes: []const u8) Error!Rgba {
    if (bytes.len < 8 or !std.mem.eql(u8, bytes[0..8], signature)) return error.InvalidPng;

    var width: u32 = 0;
    var height: u32 = 0;
    var bit_depth: u8 = 0;
    var color_type: u8 = 0;
    var interlace: u8 = 0;
    var palette: []const u8 = &.{}; // RGB triples
    var trns: []const u8 = &.{}; // per-palette alpha, or a single transparent color
    var idat: std.ArrayList(u8) = .empty;
    defer idat.deinit(gpa);

    var i: usize = 8;
    while (i + 8 <= bytes.len) {
        const len = readU32(bytes[i..][0..4]);
        const kind = bytes[i + 4 ..][0..4];
        i += 8;
        if (len > bytes.len - i or bytes.len - i - len < 4) return error.InvalidPng;
        const data = bytes[i..][0..len];
        i += len + 4; // skip the trailing CRC
        if (eq(kind, "IHDR")) {
            if (len < 13) return error.InvalidPng;
            width = readU32(data[0..4]);
            height = readU32(data[4..8]);
            bit_depth = data[8];
            color_type = data[9];
            interlace = data[12];
        } else if (eq(kind, "PLTE")) {
            palette = data;
        } else if (eq(kind, "tRNS")) {
            trns = data;
        } else if (eq(kind, "IDAT")) {
            try idat.appendSlice(gpa, data);
        } else if (eq(kind, "IEND")) {
            break;
        }
    }

    if (width == 0 or height == 0 or width > 1 << 16 or height > 1 << 16) return error.InvalidPng;
    if (interlace != 0) return error.Unsupported;
    if (bit_depth != 8) return error.Unsupported;
    const channels: u32 = switch (color_type) {
        0 => 1, // grayscale
        2 => 3, // rgb
        3 => 1, // palette index
        4 => 2, // gray + alpha
        6 => 4, // rgba
        else => return error.Unsupported,
    };

    const stride = width * channels;
    const raw_len = (stride + 1) * height; // each scanline is prefixed with a filter byte

    var in: std.Io.Reader = .fixed(idat.items);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var dec = std.compress.flate.Decompress.init(&in, .zlib, &window);
    const raw = dec.reader.allocRemaining(gpa, .limited(raw_len + 64)) catch return error.InvalidPng;
    defer gpa.free(raw);
    if (raw.len < raw_len) return error.InvalidPng;

    const rows = try gpa.alloc(u8, stride * height);
    defer gpa.free(rows);
    try unfilter(raw, rows, height, stride, channels);

    const out = try gpa.alloc(u8, width * height * 4);
    errdefer gpa.free(out);
    try expand_rgba(rows, out, width, height, color_type, palette, trns);
    return .{ .width = width, .height = height, .pixels = out };
}

// Reverse the per-scanline PNG filters into contiguous unfiltered rows.
fn unfilter(raw: []const u8, out: []u8, height: u32, stride: u32, channels: u32) Error!void {
    const bpp = channels; // 8-bit: bytes per pixel == channels
    var y: u32 = 0;
    var src: usize = 0;
    while (y < height) : (y += 1) {
        const filter = raw[src];
        src += 1;
        const row = out[y * stride ..][0..stride];
        const prev: ?[]const u8 = if (y == 0) null else out[(y - 1) * stride ..][0..stride];
        var x: u32 = 0;
        while (x < stride) : (x += 1) {
            const cur = raw[src + x];
            const a: u32 = if (x >= bpp) row[x - bpp] else 0; // left
            const b: u32 = if (prev) |p| p[x] else 0; // up
            const c: u32 = if (prev != null and x >= bpp) prev.?[x - bpp] else 0; // up-left
            row[x] = switch (filter) {
                0 => cur,
                1 => cur +% @as(u8, @truncate(a)),
                2 => cur +% @as(u8, @truncate(b)),
                3 => cur +% @as(u8, @truncate((a + b) / 2)),
                4 => cur +% @as(u8, @truncate(paeth(a, b, c))),
                else => return error.InvalidPng,
            };
        }
        src += stride;
    }
}

fn paeth(a: u32, b: u32, c: u32) u32 {
    const p = @as(i32, @intCast(a)) + @as(i32, @intCast(b)) - @as(i32, @intCast(c));
    const pa = @abs(p - @as(i32, @intCast(a)));
    const pb = @abs(p - @as(i32, @intCast(b)));
    const pc = @abs(p - @as(i32, @intCast(c)));
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

fn expand_rgba(rows: []const u8, out: []u8, width: u32, height: u32, color_type: u8, palette: []const u8, trns: []const u8) Error!void {
    const n = width * height;
    switch (color_type) {
        6 => @memcpy(out, rows[0 .. n * 4]), // already RGBA
        2 => { // RGB -> RGBA
            var p: usize = 0;
            while (p < n) : (p += 1) {
                out[p * 4 + 0] = rows[p * 3 + 0];
                out[p * 4 + 1] = rows[p * 3 + 1];
                out[p * 4 + 2] = rows[p * 3 + 2];
                out[p * 4 + 3] = 255;
            }
        },
        0 => { // grayscale -> RGBA
            var p: usize = 0;
            while (p < n) : (p += 1) {
                const g = rows[p];
                out[p * 4 + 0] = g;
                out[p * 4 + 1] = g;
                out[p * 4 + 2] = g;
                out[p * 4 + 3] = 255;
            }
        },
        4 => { // gray + alpha -> RGBA
            var p: usize = 0;
            while (p < n) : (p += 1) {
                const g = rows[p * 2];
                out[p * 4 + 0] = g;
                out[p * 4 + 1] = g;
                out[p * 4 + 2] = g;
                out[p * 4 + 3] = rows[p * 2 + 1];
            }
        },
        3 => { // palette index -> RGBA
            if (palette.len < 3) return error.InvalidPng;
            var p: usize = 0;
            while (p < n) : (p += 1) {
                const idx: usize = rows[p];
                if (idx * 3 + 2 >= palette.len) return error.InvalidPng;
                out[p * 4 + 0] = palette[idx * 3 + 0];
                out[p * 4 + 1] = palette[idx * 3 + 1];
                out[p * 4 + 2] = palette[idx * 3 + 2];
                out[p * 4 + 3] = if (idx < trns.len) trns[idx] else 255;
            }
        },
        else => return error.Unsupported,
    }
}

fn readU32(b: *const [4]u8) u32 {
    return std.mem.readInt(u32, b, .big);
}
fn eq(a: *const [4]u8, comptime b: *const [4:0]u8) bool {
    return std.mem.eql(u8, a, b);
}

// --- tests ----------------------------------------------------------------

const testing = std.testing;

test "png: decode an 8-bit RGB image written by PIL matches the source pixels" {
    // A 3x2 PNG produced by PIL with known pixels (see the generator in the test data).
    const bytes = @embedFile("testdata/rgb_3x2.png");
    const img = try decode(testing.allocator, bytes);
    defer img.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 3), img.width);
    try testing.expectEqual(@as(u32, 2), img.height);
    // pixel (0,0) = red, (1,0) = green, (2,0) = blue, (0,1) = white, opaque.
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, img.pixels[0..4]);
    try testing.expectEqualSlices(u8, &.{ 0, 255, 0, 255 }, img.pixels[4..8]);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, img.pixels[8..12]);
    try testing.expectEqualSlices(u8, &.{ 255, 255, 255, 255 }, img.pixels[12..16]);
}

test "png: decode an RGBA image preserves the alpha channel" {
    const img = try decode(testing.allocator, @embedFile("testdata/rgba_2x1.png"));
    defer img.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 2), img.width);
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, img.pixels[0..4]);
    try testing.expectEqualSlices(u8, &.{ 0, 255, 0, 128 }, img.pixels[4..8]);
}
