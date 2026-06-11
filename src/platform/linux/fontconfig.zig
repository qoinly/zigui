// fontconfig binding: family name + weight in, font file path + face index out.
// Loaded with dlopen like the other Linux bindings; only the match path the
// text system speaks is declared.

const std = @import("std");

pub const Config = opaque {};
pub const Pattern = opaque {};

pub const FcResult = c_int;
pub const RESULT_MATCH: FcResult = 0;
pub const MATCH_PATTERN: c_int = 0;

pub const Error = error{LibraryLoadFailed};

extern "c" fn dlopen(file: [*:0]const u8, mode: c_int) ?*anyopaque;
extern "c" fn dlsym(handle: ?*anyopaque, name: [*:0]const u8) ?*anyopaque;
const RTLD_NOW: c_int = 2;

const Fns = struct {
    FcInitLoadConfigAndFonts: *const fn () callconv(.c) ?*Config,
    FcPatternCreate: *const fn () callconv(.c) ?*Pattern,
    FcPatternDestroy: *const fn (*Pattern) callconv(.c) void,
    FcPatternAddString: *const fn (*Pattern, [*:0]const u8, [*:0]const u8) callconv(.c) c_int,
    FcPatternAddInteger: *const fn (*Pattern, [*:0]const u8, c_int) callconv(.c) c_int,
    FcConfigSubstitute: *const fn (?*Config, *Pattern, c_int) callconv(.c) c_int,
    FcDefaultSubstitute: *const fn (*Pattern) callconv(.c) void,
    FcFontMatch: *const fn (?*Config, *Pattern, *FcResult) callconv(.c) ?*Pattern,
    FcPatternGetString: *const fn (
        *Pattern,
        [*:0]const u8,
        c_int,
        *?[*:0]u8,
    ) callconv(.c) FcResult,
    FcPatternGetInteger: *const fn (*Pattern, [*:0]const u8, c_int, *c_int) callconv(.c) FcResult,
};

var fns: Fns = undefined;
var g_config: ?*Config = null;
var g_loaded: bool = false;

pub fn load() Error!void {
    if (g_loaded) return;
    const handle = dlopen("libfontconfig.so.1", RTLD_NOW) orelse return error.LibraryLoadFailed;
    inline for (@typeInfo(Fns).@"struct".fields) |field| {
        const sym = dlsym(handle, field.name) orelse return error.LibraryLoadFailed;
        @field(fns, field.name) = @ptrCast(@alignCast(sym));
    }
    g_config = fns.FcInitLoadConfigAndFonts() orelse return error.LibraryLoadFailed;
    g_loaded = true;
    std.debug.assert(g_config != null);
}

// OpenType weight (100..900) to the fontconfig scale (0..210).
fn fc_weight(opentype_weight: u16) c_int {
    std.debug.assert(opentype_weight >= 100);
    std.debug.assert(opentype_weight <= 900);
    return switch (opentype_weight / 100) {
        1 => 0, // thin
        2 => 40, // extralight
        3 => 50, // light
        4 => 80, // regular
        5 => 100, // medium
        6 => 180, // demibold
        7 => 200, // bold
        8 => 205, // extrabold
        else => 210, // black
    };
}

pub const Match = struct {
    path: [:0]const u8, // borrowed from the pattern; copy before destroy is called
    index: i32,
    pattern: *Pattern,

    pub fn deinit(self: Match) void {
        std.debug.assert(g_loaded);
        fns.FcPatternDestroy(self.pattern);
    }
};

// family must be NUL-terminated; fontconfig substitution turns an unknown
// family into the configured default, so this only fails without any font.
pub fn match(family: [*:0]const u8, opentype_weight: u16) ?Match {
    std.debug.assert(g_loaded);
    std.debug.assert(family[0] != 0);
    const pattern = fns.FcPatternCreate() orelse return null;
    defer fns.FcPatternDestroy(pattern);
    _ = fns.FcPatternAddString(pattern, "family", family);
    _ = fns.FcPatternAddInteger(pattern, "weight", fc_weight(opentype_weight));
    _ = fns.FcConfigSubstitute(g_config, pattern, MATCH_PATTERN);
    fns.FcDefaultSubstitute(pattern);

    var result: FcResult = RESULT_MATCH;
    const found = fns.FcFontMatch(g_config, pattern, &result) orelse return null;
    var path: ?[*:0]u8 = null;
    if (fns.FcPatternGetString(found, "file", 0, &path) != RESULT_MATCH or path == null) {
        fns.FcPatternDestroy(found);
        return null;
    }
    var index: c_int = 0;
    if (fns.FcPatternGetInteger(found, "index", 0, &index) != RESULT_MATCH) index = 0;
    return .{ .path = std.mem.span(path.?), .index = index, .pattern = found };
}
