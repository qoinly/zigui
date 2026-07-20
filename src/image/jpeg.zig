const std = @import("std");

// A baseline (sequential, Huffman) JPEG decoder — no external deps. Handles grayscale
// and YCbCr with 4:4:4 / 4:2:2 / 4:2:0 subsampling and restart markers. Progressive and
// arithmetic-coded JPEGs are reported Unsupported.

pub const Rgba = @import("pixels.zig").Rgba;
pub const Error = error{ InvalidJpeg, Unsupported } || std.mem.Allocator.Error;

const zigzag = [64]u8{
    0,  1,  8,  16, 9,  2,  3,  10,
    17, 24, 32, 25, 18, 11, 4,  5,
    12, 19, 26, 33, 40, 48, 41, 34,
    27, 20, 13, 6,  7,  14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36,
    29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46,
    53, 60, 61, 54, 47, 55, 62, 63,
};

const Huff = struct {
    // Canonical Huffman per JPEG Annex F: mincode/maxcode/valptr keyed by code length.
    mincode: [17]i32 = @splat(0),
    maxcode: [18]i32 = @splat(-1),
    valptr: [17]u16 = @splat(0),
    symbols: [256]u8 = @splat(0),
    present: bool = false,

    fn build(self: *Huff, counts: []const u8, syms: []const u8) void {
        @memcpy(self.symbols[0..syms.len], syms);
        var code: i32 = 0;
        var k: u16 = 0;
        var len: u8 = 1;
        while (len <= 16) : (len += 1) {
            const c = counts[len - 1];
            if (c == 0) {
                self.maxcode[len] = -1;
            } else {
                self.valptr[len] = k;
                self.mincode[len] = code;
                code += c;
                k += c;
                self.maxcode[len] = code - 1;
            }
            code <<= 1;
        }
        self.present = true;
    }

    fn decode(self: *const Huff, br: *BitReader) Error!u8 {
        var code: i32 = 0;
        var len: u8 = 1;
        while (len <= 16) : (len += 1) {
            code = (code << 1) | br.bit();
            if (self.maxcode[len] >= 0 and code <= self.maxcode[len]) {
                const idx = self.valptr[len] + @as(u16, @intCast(code - self.mincode[len]));
                return self.symbols[idx];
            }
        }
        return error.InvalidJpeg;
    }
};

const BitReader = struct {
    data: []const u8,
    pos: usize = 0,
    acc: u32 = 0,
    n: u5 = 0,
    hit_marker: bool = false,

    fn bit(self: *BitReader) i32 {
        if (self.n == 0) {
            if (self.pos >= self.data.len) {
                self.hit_marker = true;
                return 0;
            }
            var b = self.data[self.pos];
            self.pos += 1;
            if (b == 0xFF) {
                // 0xFF00 is a stuffed literal 0xFF; 0xFFxx (xx!=0) is a marker: stop.
                const next: u8 = if (self.pos < self.data.len) self.data[self.pos] else 0;
                if (next == 0) {
                    self.pos += 1;
                } else {
                    self.hit_marker = true;
                    b = 0;
                }
            }
            self.acc = b;
            self.n = 8;
        }
        self.n -= 1;
        return @intCast((self.acc >> @intCast(self.n)) & 1);
    }

    fn receive(self: *BitReader, s: u8) i32 {
        var v: i32 = 0;
        var i: u8 = 0;
        while (i < s) : (i += 1) v = (v << 1) | self.bit();
        return v;
    }

    // JPEG EXTEND: turn `s` received bits into a signed coefficient.
    fn extend(v: i32, s: u8) i32 {
        if (s == 0) return 0;
        const vt = @as(i32, 1) << @intCast(s - 1);
        return if (v < vt) v - (@as(i32, 1) << @intCast(s)) + 1 else v;
    }

    fn realign(self: *BitReader) void {
        self.n = 0;
        self.acc = 0;
    }
};

const Component = struct {
    id: u8 = 0,
    h: u8 = 1,
    v: u8 = 1,
    quant: u8 = 0,
    dc_table: u8 = 0,
    ac_table: u8 = 0,
    pred: i32 = 0,
    bpl: u32 = 0, // blocks per line
    plane: []u8 = &.{}, // (bpl*8) x (bpc*8) samples
    pw: u32 = 0,
    ph: u32 = 0,
};

pub fn decode(gpa: std.mem.Allocator, bytes: []const u8) Error!Rgba {
    if (bytes.len < 2 or bytes[0] != 0xFF or bytes[1] != 0xD8) return error.InvalidJpeg;

    var quant: [4][64]u16 = @splat(@splat(0));
    var dc_huff: [4]Huff = @splat(.{});
    var ac_huff: [4]Huff = @splat(.{});
    var comps: [4]Component = @splat(.{});
    var ncomp: u8 = 0;
    var width: u32 = 0;
    var height: u32 = 0;
    var restart: u32 = 0;

    var i: usize = 2;
    while (i + 4 <= bytes.len) {
        if (bytes[i] != 0xFF) {
            i += 1;
            continue;
        }
        const marker = bytes[i + 1];
        i += 2;
        if (marker == 0xD9) break; // EOI
        if (marker == 0x01 or (marker >= 0xD0 and marker <= 0xD7)) continue; // standalone
        const seg_len = readU16(bytes[i..][0..2]);
        if (seg_len < 2 or i + seg_len > bytes.len) return error.InvalidJpeg;
        const seg = bytes[i + 2 .. i + seg_len];

        switch (marker) {
            0xDB => try read_dqt(seg, &quant),
            0xC0 => { // SOF0 baseline
                if (seg.len < 6) return error.InvalidJpeg;
                if (seg[0] != 8) return error.Unsupported;
                height = readU16(seg[1..3]);
                width = readU16(seg[3..5]);
                ncomp = seg[5];
                if (ncomp == 0 or ncomp > 4 or seg.len < 6 + @as(usize, ncomp) * 3) return error.InvalidJpeg;
                var c: u8 = 0;
                while (c < ncomp) : (c += 1) {
                    const o = 6 + @as(usize, c) * 3;
                    comps[c] = .{ .id = seg[o], .h = @intCast(seg[o + 1] >> 4), .v = @intCast(seg[o + 1] & 0xF), .quant = seg[o + 2] };
                }
            },
            0xC2, 0xC1, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB => return error.Unsupported, // progressive / other
            0xC4 => try read_dht(seg, &dc_huff, &ac_huff),
            0xDD => restart = readU16(seg[0..2]),
            0xDA => { // SOS: the scan follows immediately after this segment
                try read_sos(seg, comps[0..ncomp]);
                const scan_start = i + seg_len;
                const scan = bytes[scan_start..];
                try decode_scan(gpa, scan, comps[0..ncomp], &dc_huff, &ac_huff, &quant, width, height, restart);
                return finish(gpa, comps[0..ncomp], width, height);
            },
            else => {}, // APPn, COM, etc.
        }
        i += seg_len;
    }
    return error.InvalidJpeg;
}

fn read_dqt(seg: []const u8, quant: *[4][64]u16) Error!void {
    var p: usize = 0;
    while (p < seg.len) {
        const pq = seg[p] >> 4;
        const tq = seg[p] & 0xF;
        p += 1;
        if (tq > 3) return error.InvalidJpeg;
        var k: usize = 0;
        while (k < 64) : (k += 1) {
            if (pq == 0) {
                if (p >= seg.len) return error.InvalidJpeg;
                quant[tq][k] = seg[p];
                p += 1;
            } else {
                if (p + 1 >= seg.len) return error.InvalidJpeg;
                quant[tq][k] = readU16(seg[p..][0..2]);
                p += 2;
            }
        }
    }
}

fn read_dht(seg: []const u8, dc: *[4]Huff, ac: *[4]Huff) Error!void {
    var p: usize = 0;
    while (p + 17 <= seg.len) {
        const class = seg[p] >> 4;
        const id = seg[p] & 0xF;
        p += 1;
        if (id > 3) return error.InvalidJpeg;
        const counts = seg[p..][0..16];
        p += 16;
        var total: usize = 0;
        for (counts) |c| total += c;
        if (p + total > seg.len) return error.InvalidJpeg;
        const syms = seg[p..][0..total];
        p += total;
        if (class == 0) dc[id].build(counts, syms) else ac[id].build(counts, syms);
    }
}

fn read_sos(seg: []const u8, comps: []Component) Error!void {
    if (seg.len < 1) return error.InvalidJpeg;
    const ns = seg[0];
    if (@as(usize, ns) * 2 + 1 > seg.len) return error.InvalidJpeg;
    var s: u8 = 0;
    while (s < ns) : (s += 1) {
        const cid = seg[1 + @as(usize, s) * 2];
        const tables = seg[2 + @as(usize, s) * 2];
        for (comps) |*c| {
            if (c.id == cid) {
                c.dc_table = @intCast(tables >> 4);
                c.ac_table = @intCast(tables & 0xF);
            }
        }
    }
}

fn decode_scan(gpa: std.mem.Allocator, scan: []const u8, comps: []Component, dc: *[4]Huff, ac: *[4]Huff, quant: *[4][64]u16, width: u32, height: u32, restart: u32) Error!void {
    var max_h: u8 = 1;
    var max_v: u8 = 1;
    for (comps) |c| {
        max_h = @max(max_h, c.h);
        max_v = @max(max_v, c.v);
    }
    const mcus_x = ceil_div(width, @as(u32, 8) * max_h);
    const mcus_y = ceil_div(height, @as(u32, 8) * max_v);

    for (comps) |*c| {
        c.bpl = mcus_x * c.h;
        c.pw = c.bpl * 8;
        c.ph = mcus_y * c.v * 8;
        c.plane = try gpa.alloc(u8, c.pw * c.ph);
        c.pred = 0;
    }

    var br: BitReader = .{ .data = scan };
    var block: [64]i32 = undefined;
    var mcu: u32 = 0;
    const total_mcus = mcus_x * mcus_y;
    while (mcu < total_mcus) : (mcu += 1) {
        if (restart != 0 and mcu != 0 and mcu % restart == 0) {
            br.realign();
            // skip the RSTn marker in the stream
            skip_restart(&br);
            for (comps) |*c| c.pred = 0;
        }
        const mx = mcu % mcus_x;
        const my = mcu / mcus_x;
        for (comps) |*c| {
            var by: u8 = 0;
            while (by < c.v) : (by += 1) {
                var bx: u8 = 0;
                while (bx < c.h) : (bx += 1) {
                    try decode_block(&br, &block, c, dc, ac, &quant[c.quant]);
                    const px = (mx * c.h + bx) * 8;
                    const py = (my * c.v + by) * 8;
                    place_block(&block, c.plane, c.pw, px, py);
                }
            }
        }
    }
}

fn decode_block(br: *BitReader, out: *[64]i32, c: *Component, dc: *[4]Huff, ac: *[4]Huff, q: *const [64]u16) Error!void {
    var coef: [64]i32 = @splat(0);
    // DC
    const t = try dc[c.dc_table].decode(br);
    const diff = BitReader.extend(br.receive(t), t);
    c.pred += diff;
    coef[0] = c.pred * q[0];
    // AC
    var k: usize = 1;
    while (k < 64) {
        const rs = try ac[c.ac_table].decode(br);
        const run = rs >> 4;
        const size = rs & 0xF;
        if (size == 0) {
            if (run != 15) break; // EOB
            k += 16;
            continue;
        }
        k += run;
        if (k >= 64) break;
        const val = BitReader.extend(br.receive(size), size);
        coef[zigzag[k]] = val * q[k];
        k += 1;
    }
    idct(&coef, out);
}

// Separable float inverse DCT with level shift + clamp to 0..255 (stored back in i32).
var cos_table: [8][8]f32 = undefined;
var cos_ready = false;

fn ensure_cos() void {
    if (cos_ready) return;
    var x: usize = 0;
    while (x < 8) : (x += 1) {
        var u: usize = 0;
        while (u < 8) : (u += 1) {
            const cu: f32 = if (u == 0) 0.70710678 else 1.0;
            cos_table[x][u] = cu * @cos(@as(f32, @floatFromInt((2 * x + 1) * u)) * std.math.pi / 16.0);
        }
    }
    cos_ready = true;
}

fn idct(in: *const [64]i32, out: *[64]i32) void {
    ensure_cos();
    var tmp: [64]f32 = undefined;
    // rows
    var y: usize = 0;
    while (y < 8) : (y += 1) {
        var x: usize = 0;
        while (x < 8) : (x += 1) {
            var s: f32 = 0;
            var u: usize = 0;
            while (u < 8) : (u += 1) s += cos_table[x][u] * @as(f32, @floatFromInt(in[y * 8 + u]));
            tmp[y * 8 + x] = s * 0.5;
        }
    }
    // columns
    var x: usize = 0;
    while (x < 8) : (x += 1) {
        y = 0;
        while (y < 8) : (y += 1) {
            var s: f32 = 0;
            var u: usize = 0;
            while (u < 8) : (u += 1) s += cos_table[y][u] * tmp[u * 8 + x];
            const v = s * 0.5 + 128.0;
            out[y * 8 + x] = @intFromFloat(std.math.clamp(v, 0.0, 255.0));
        }
    }
}

fn place_block(block: *const [64]i32, plane: []u8, pw: u32, px: u32, py: u32) void {
    var y: u32 = 0;
    while (y < 8) : (y += 1) {
        var x: u32 = 0;
        while (x < 8) : (x += 1) {
            plane[(py + y) * pw + (px + x)] = @intCast(block[y * 8 + x]);
        }
    }
}

fn skip_restart(br: *BitReader) void {
    // advance to just past an RSTn marker (0xFFD0..D7)
    while (br.pos + 1 < br.data.len) {
        if (br.data[br.pos] == 0xFF and br.data[br.pos + 1] >= 0xD0 and br.data[br.pos + 1] <= 0xD7) {
            br.pos += 2;
            return;
        }
        br.pos += 1;
    }
}

fn finish(gpa: std.mem.Allocator, comps: []Component, width: u32, height: u32) Error!Rgba {
    defer for (comps) |c| gpa.free(c.plane);
    const out = try gpa.alloc(u8, width * height * 4);
    errdefer gpa.free(out);

    var max_h: u8 = 1;
    var max_v: u8 = 1;
    for (comps) |c| {
        max_h = @max(max_h, c.h);
        max_v = @max(max_v, c.v);
    }

    var py: u32 = 0;
    while (py < height) : (py += 1) {
        var px: u32 = 0;
        while (px < width) : (px += 1) {
            const o = (py * width + px) * 4;
            if (comps.len == 1) {
                const g = sample(comps[0], max_h, max_v, px, py);
                out[o] = g;
                out[o + 1] = g;
                out[o + 2] = g;
                out[o + 3] = 255;
            } else {
                const yy: f32 = @floatFromInt(sample(comps[0], max_h, max_v, px, py));
                const cb: f32 = @as(f32, @floatFromInt(sample(comps[1], max_h, max_v, px, py))) - 128.0;
                const cr: f32 = @as(f32, @floatFromInt(sample(comps[2], max_h, max_v, px, py))) - 128.0;
                out[o] = clamp8(yy + 1.402 * cr);
                out[o + 1] = clamp8(yy - 0.344136 * cb - 0.714136 * cr);
                out[o + 2] = clamp8(yy + 1.772 * cb);
                out[o + 3] = 255;
            }
        }
    }
    return .{ .width = width, .height = height, .pixels = out };
}

fn sample(c: Component, max_h: u8, max_v: u8, px: u32, py: u32) u8 {
    const sx = px * c.h / max_h;
    const sy = py * c.v / max_v;
    return c.plane[@min(sy, c.ph - 1) * c.pw + @min(sx, c.pw - 1)];
}

fn clamp8(v: f32) u8 {
    return @intFromFloat(std.math.clamp(v, 0.0, 255.0));
}

fn readU16(b: *const [2]u8) u16 {
    return std.mem.readInt(u16, b, .big);
}
fn ceil_div(a: u32, b: u32) u32 {
    return (a + b - 1) / b;
}

// --- tests ----------------------------------------------------------------

const testing = std.testing;

test "jpeg: decode a baseline JPEG written by PIL is approximately the source colors" {
    const img = try decode(testing.allocator, @embedFile("testdata/rgb_16.jpg"));
    defer img.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 16), img.width);
    try testing.expectEqual(@as(u32, 16), img.height);
    // top-left block is red, top-right is green, bottom-left blue (JPEG is lossy → tolerance).
    try near(img.pixels, img.width, 2, 2, .{ 255, 0, 0 });
    try near(img.pixels, img.width, 13, 2, .{ 0, 255, 0 });
    try near(img.pixels, img.width, 2, 13, .{ 0, 0, 255 });
}

test "jpeg: decode a multi-MCU image tiles the blocks correctly" {
    const img = try decode(testing.allocator, @embedFile("testdata/quad_48x32.jpg"));
    defer img.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 48), img.width);
    try testing.expectEqual(@as(u32, 32), img.height);
    try near(img.pixels, img.width, 6, 5, .{ 255, 0, 0 }); // TL red
    try near(img.pixels, img.width, 40, 5, .{ 0, 255, 0 }); // TR green
    try near(img.pixels, img.width, 6, 26, .{ 0, 0, 255 }); // BL blue
    try near(img.pixels, img.width, 40, 26, .{ 200, 200, 0 }); // BR yellow
}

fn near(px: []const u8, w: u32, x: u32, y: u32, want: [3]u8) !void {
    const o = (y * w + x) * 4;
    var ch: usize = 0;
    while (ch < 3) : (ch += 1) {
        const got: i32 = px[o + ch];
        if (@abs(got - @as(i32, want[ch])) > 40) return error.TestUnexpectedResult;
    }
}
