// HarfBuzz binding: shaping only, in font design units - the font scale is set
// to units-per-em once at creation, so positions come back unscaled and the
// text system applies font_size / upem itself, the DWrite-path arithmetic.

const std = @import("std");

pub const Error = error{LibraryLoadFailed};

pub const Blob = opaque {};
pub const FontFace = opaque {};
pub const Font = opaque {};
pub const Buffer = opaque {};

pub const GlyphInfo = extern struct {
    codepoint: u32,
    mask: u32,
    cluster: u32,
    var1: u32,
    var2: u32,
};

pub const GlyphPosition = extern struct {
    x_advance: i32,
    y_advance: i32,
    x_offset: i32,
    y_offset: i32,
    @"var": u32,
};

pub const GlyphExtents = extern struct {
    x_bearing: i32,
    y_bearing: i32,
    width: i32,
    height: i32,
};

extern "c" fn dlopen(file: [*:0]const u8, mode: c_int) ?*anyopaque;
extern "c" fn dlsym(handle: ?*anyopaque, name: [*:0]const u8) ?*anyopaque;
const RTLD_NOW: c_int = 2;

const Fns = struct {
    hb_blob_create_from_file: *const fn ([*:0]const u8) callconv(.c) ?*Blob,
    hb_blob_destroy: *const fn (*Blob) callconv(.c) void,
    hb_face_create: *const fn (*Blob, c_uint) callconv(.c) ?*FontFace,
    hb_face_destroy: *const fn (*FontFace) callconv(.c) void,
    hb_face_get_upem: *const fn (*FontFace) callconv(.c) c_uint,
    hb_font_create: *const fn (*FontFace) callconv(.c) ?*Font,
    hb_font_destroy: *const fn (*Font) callconv(.c) void,
    hb_font_set_scale: *const fn (*Font, c_int, c_int) callconv(.c) void,
    hb_font_get_glyph_extents: *const fn (*Font, u32, *GlyphExtents) callconv(.c) c_int,
    hb_buffer_create: *const fn () callconv(.c) ?*Buffer,
    hb_buffer_destroy: *const fn (*Buffer) callconv(.c) void,
    hb_buffer_reset: *const fn (*Buffer) callconv(.c) void,
    hb_buffer_add_utf8: *const fn (*Buffer, [*]const u8, c_int, c_uint, c_int) callconv(.c) void,
    hb_buffer_guess_segment_properties: *const fn (*Buffer) callconv(.c) void,
    hb_shape: *const fn (*Font, *Buffer, ?*const anyopaque, c_uint) callconv(.c) void,
    hb_buffer_get_length: *const fn (*Buffer) callconv(.c) c_uint,
    hb_buffer_get_glyph_infos: *const fn (*Buffer, ?*c_uint) callconv(.c) ?[*]GlyphInfo,
    hb_buffer_get_glyph_positions: *const fn (*Buffer, ?*c_uint) callconv(.c) ?[*]GlyphPosition,
    hb_ot_metrics_get_position: *const fn (*Font, u32, *i32) callconv(.c) c_int,
};

fn tag(a: u8, b: u8, c: u8, d: u8) u32 {
    return @as(u32, a) << 24 | @as(u32, b) << 16 | @as(u32, c) << 8 | d;
}

pub const METRICS_TAG_CAP_HEIGHT: u32 = tag('c', 'p', 'h', 't');
pub const METRICS_TAG_X_HEIGHT: u32 = tag('x', 'h', 'g', 't');

var fns: Fns = undefined;
var g_loaded: bool = false;

pub fn load() Error!void {
    if (g_loaded) return;
    const handle = dlopen("libharfbuzz.so.0", RTLD_NOW) orelse return error.LibraryLoadFailed;
    inline for (@typeInfo(Fns).@"struct".fields) |field| {
        const sym = dlsym(handle, field.name) orelse return error.LibraryLoadFailed;
        @field(fns, field.name) = @ptrCast(@alignCast(sym));
    }
    g_loaded = true;
    std.debug.assert(g_loaded);
}

// Returns a font shaping in design units (scale = upem), plus that upem.
pub fn font_from_file(path: [*:0]const u8, face_index: u32) ?struct { font: *Font, upem: u32 } {
    std.debug.assert(g_loaded);
    std.debug.assert(path[0] != 0);
    const blob = fns.hb_blob_create_from_file(path) orelse return null;
    defer fns.hb_blob_destroy(blob); // face holds its own reference
    const face = fns.hb_face_create(blob, face_index) orelse return null;
    defer fns.hb_face_destroy(face); // font holds its own reference
    const upem = fns.hb_face_get_upem(face);
    if (upem == 0) return null;
    const font = fns.hb_font_create(face) orelse return null;
    fns.hb_font_set_scale(font, @intCast(upem), @intCast(upem));
    return .{ .font = font, .upem = upem };
}

pub fn font_destroy(font: *Font) void {
    std.debug.assert(g_loaded);
    fns.hb_font_destroy(font);
}

pub fn buffer_create() ?*Buffer {
    std.debug.assert(g_loaded);
    return fns.hb_buffer_create();
}

pub fn buffer_destroy(buffer: *Buffer) void {
    std.debug.assert(g_loaded);
    fns.hb_buffer_destroy(buffer);
}

pub const Shaped = struct {
    infos: [*]GlyphInfo,
    positions: [*]GlyphPosition,
    len: u32,
};

// Shapes text into the reused buffer; the returned slices live until the next
// shape call on the same buffer.
pub fn shape(font: *Font, buffer: *Buffer, text: []const u8) ?Shaped {
    std.debug.assert(g_loaded);
    std.debug.assert(text.len <= std.math.maxInt(c_int));
    fns.hb_buffer_reset(buffer);
    fns.hb_buffer_add_utf8(buffer, text.ptr, @intCast(text.len), 0, @intCast(text.len));
    fns.hb_buffer_guess_segment_properties(buffer);
    fns.hb_shape(font, buffer, null, 0);
    const len = fns.hb_buffer_get_length(buffer);
    if (len == 0) return null;
    const infos = fns.hb_buffer_get_glyph_infos(buffer, null) orelse return null;
    const positions = fns.hb_buffer_get_glyph_positions(buffer, null) orelse return null;
    return .{ .infos = infos, .positions = positions, .len = len };
}

pub fn glyph_extents(font: *Font, glyph_id: u32, out: *GlyphExtents) bool {
    std.debug.assert(g_loaded);
    return fns.hb_font_get_glyph_extents(font, glyph_id, out) != 0;
}

// In design units (the font scale set above); false when the font lacks the
// OS/2 metric and the caller falls back to an upem ratio.
pub fn metric_position(font: *Font, metrics_tag: u32, out: *i32) bool {
    std.debug.assert(g_loaded);
    std.debug.assert(metrics_tag != 0);
    return fns.hb_ot_metrics_get_position(font, metrics_tag, out) != 0;
}
