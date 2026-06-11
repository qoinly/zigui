// FreeType binding: glyph rasterization only - shaping is HarfBuzz's job. The
// FaceRec/GlyphSlotRec/SizeRec layouts are PREFIXES of the real structs: every
// field up to the last one read is declared in ABI order, and the structs are
// only ever used behind pointers FreeType owns, so the omitted private tail is
// never touched. That layout has been frozen public ABI for decades.

const std = @import("std");

pub const Error = error{LibraryLoadFailed};

pub const Library = opaque {};

pub const Vector = extern struct { x: c_long, y: c_long };
pub const BBox = extern struct { x_min: c_long, y_min: c_long, x_max: c_long, y_max: c_long };
pub const Generic = extern struct { data: ?*anyopaque, finalizer: ?*anyopaque };

pub const GlyphMetrics = extern struct {
    width: c_long,
    height: c_long,
    hori_bearing_x: c_long,
    hori_bearing_y: c_long,
    hori_advance: c_long,
    vert_bearing_x: c_long,
    vert_bearing_y: c_long,
    vert_advance: c_long,
};

pub const Bitmap = extern struct {
    rows: c_uint,
    width: c_uint,
    pitch: c_int,
    buffer: ?[*]u8,
    num_grays: c_ushort,
    pixel_mode: u8,
    palette_mode: u8,
    palette: ?*anyopaque,
};

pub const GlyphSlot = extern struct {
    library: *Library,
    face: *Face,
    next: ?*GlyphSlot,
    glyph_index: c_uint,
    generic: Generic,
    metrics: GlyphMetrics,
    linear_hori_advance: c_long,
    linear_vert_advance: c_long,
    advance: Vector,
    format: c_uint,
    bitmap: Bitmap,
    bitmap_left: c_int,
    bitmap_top: c_int,
};

pub const SizeMetrics = extern struct {
    x_ppem: c_ushort,
    y_ppem: c_ushort,
    x_scale: c_long,
    y_scale: c_long,
    ascender: c_long,
    descender: c_long,
    height: c_long,
    max_advance: c_long,
};

pub const Size = extern struct {
    face: *Face,
    generic: Generic,
    metrics: SizeMetrics,
};

pub const Face = extern struct {
    num_faces: c_long,
    face_index: c_long,
    face_flags: c_long,
    style_flags: c_long,
    num_glyphs: c_long,
    family_name: ?[*:0]u8,
    style_name: ?[*:0]u8,
    num_fixed_sizes: c_int,
    available_sizes: ?*anyopaque,
    num_charmaps: c_int,
    charmaps: ?*anyopaque,
    generic: Generic,
    bbox: BBox,
    units_per_em: c_ushort,
    ascender: c_short,
    descender: c_short,
    height: c_short,
    max_advance_width: c_short,
    max_advance_height: c_short,
    underline_position: c_short,
    underline_thickness: c_short,
    glyph: ?*GlyphSlot,
    size: ?*Size,
    charmap: ?*anyopaque,
};

pub const LOAD_DEFAULT: i32 = 0;
pub const LOAD_RENDER: i32 = 4;
pub const RENDER_MODE_NORMAL: c_uint = 0;
pub const PIXEL_MODE_GRAY: u8 = 2;

extern "c" fn dlopen(file: [*:0]const u8, mode: c_int) ?*anyopaque;
extern "c" fn dlsym(handle: ?*anyopaque, name: [*:0]const u8) ?*anyopaque;
const RTLD_NOW: c_int = 2;

const Fns = struct {
    FT_Init_FreeType: *const fn (*?*Library) callconv(.c) c_int,
    FT_Done_FreeType: *const fn (*Library) callconv(.c) c_int,
    FT_New_Face: *const fn (*Library, [*:0]const u8, c_long, *?*Face) callconv(.c) c_int,
    FT_Done_Face: *const fn (*Face) callconv(.c) c_int,
    FT_Set_Char_Size: *const fn (*Face, c_long, c_long, c_uint, c_uint) callconv(.c) c_int,
    FT_Load_Glyph: *const fn (*Face, c_uint, i32) callconv(.c) c_int,
    FT_Render_Glyph: *const fn (*GlyphSlot, c_uint) callconv(.c) c_int,
};

var fns: Fns = undefined;
var g_library: ?*Library = null;
var g_loaded: bool = false;

pub fn load() Error!void {
    if (g_loaded) return;
    const handle = dlopen("libfreetype.so.6", RTLD_NOW) orelse return error.LibraryLoadFailed;
    inline for (@typeInfo(Fns).@"struct".fields) |field| {
        const sym = dlsym(handle, field.name) orelse return error.LibraryLoadFailed;
        @field(fns, field.name) = @ptrCast(@alignCast(sym));
    }
    var library: ?*Library = null;
    if (fns.FT_Init_FreeType(&library) != 0) return error.LibraryLoadFailed;
    g_library = library;
    g_loaded = true;
    std.debug.assert(g_library != null);
}

pub fn new_face(path: [*:0]const u8, face_index: i32) ?*Face {
    std.debug.assert(g_loaded);
    std.debug.assert(path[0] != 0);
    var face: ?*Face = null;
    if (fns.FT_New_Face(g_library.?, path, face_index, &face) != 0) return null;
    return face;
}

pub fn done_face(face: *Face) void {
    std.debug.assert(g_loaded);
    _ = fns.FT_Done_Face(face);
}

// size_px may be fractional; 26.6 fixed point at 72 dpi makes 1 pt == 1 px.
pub fn set_pixel_size(face: *Face, size_px: f32) bool {
    std.debug.assert(g_loaded);
    std.debug.assert(size_px > 0);
    const size_26_6: c_long = @intFromFloat(size_px * 64.0);
    return fns.FT_Set_Char_Size(face, 0, size_26_6, 72, 72) == 0;
}

pub fn load_and_render(face: *Face, glyph_index: u32) ?*GlyphSlot {
    std.debug.assert(g_loaded);
    if (fns.FT_Load_Glyph(face, glyph_index, LOAD_RENDER) != 0) return null;
    const slot = face.glyph orelse return null;
    std.debug.assert(slot.bitmap.pixel_mode == PIXEL_MODE_GRAY or slot.bitmap.rows == 0);
    return slot;
}

pub fn load_only(face: *Face, glyph_index: u32) ?*GlyphSlot {
    std.debug.assert(g_loaded);
    if (fns.FT_Load_Glyph(face, glyph_index, LOAD_DEFAULT) != 0) return null;
    return face.glyph;
}
