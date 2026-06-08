// DirectWrite bindings: factory + font collection/family/font/fontface +
// glyph-run analysis, enough to look up a system font, shape one line (glyph
// indices + design advances), read metrics, and rasterize a glyph to a
// grayscale coverage mask. Vtable prefixes are typed only through the methods
// the text system calls; earlier slots are pointer-sized placeholders.

const win32 = @import("win32.zig");
const com = @import("com.zig");

const HRESULT = win32.HRESULT;
const GUID = win32.GUID;
const BOOL = win32.BOOL;
const RECT = win32.RECT;

pub const DWRITE_FACTORY_TYPE_SHARED: u32 = 0;

pub const DWRITE_FONT_WEIGHT_NORMAL: u32 = 400;
pub const DWRITE_FONT_STRETCH_NORMAL: u32 = 5;
pub const DWRITE_FONT_STYLE_NORMAL: u32 = 0;

pub const DWRITE_RENDERING_MODE_NATURAL: u32 = 4;
pub const DWRITE_MEASURING_MODE_NATURAL: u32 = 0;

pub const DWRITE_TEXTURE_CLEARTYPE_3x1: u32 = 1;

pub const IID_IDWriteFactory = com.guid(
    0xb859ee5a,
    0xd838,
    0x4b5b,
    0xa2,
    0xe8,
    0x1a,
    0xdc,
    0x7d,
    0x93,
    0xdb,
    0x48,
);

pub const DWRITE_FONT_METRICS = extern struct {
    designUnitsPerEm: u16,
    ascent: u16,
    descent: u16,
    lineGap: i16,
    capHeight: u16,
    xHeight: u16,
    underlinePosition: i16,
    underlineThickness: u16,
    strikethroughPosition: i16,
    strikethroughThickness: u16,
};

pub const DWRITE_GLYPH_METRICS = extern struct {
    leftSideBearing: i32,
    advanceWidth: u32,
    rightSideBearing: i32,
    topSideBearing: i32,
    advanceHeight: u32,
    bottomSideBearing: i32,
    verticalOriginY: i32,
};

pub const DWRITE_GLYPH_OFFSET = extern struct {
    advanceOffset: f32,
    ascenderOffset: f32,
};

pub const DWRITE_GLYPH_RUN = extern struct {
    fontFace: *IDWriteFontFace,
    fontEmSize: f32,
    glyphCount: u32,
    glyphIndices: [*]const u16,
    glyphAdvances: ?[*]const f32,
    glyphOffsets: ?[*]const DWRITE_GLYPH_OFFSET,
    isSideways: BOOL,
    bidiLevel: u32,
};

pub const IDWriteFactory = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*IDWriteFactory) callconv(.winapi) u32,
        GetSystemFontCollection: *const fn (
            *IDWriteFactory,
            *?*IDWriteFontCollection,
            BOOL,
        ) callconv(.winapi) HRESULT,
        CreateCustomFontCollection: *const anyopaque,
        RegisterFontCollectionLoader: *const anyopaque,
        UnregisterFontCollectionLoader: *const anyopaque,
        CreateFontFileReference: *const anyopaque,
        CreateCustomFontFileReference: *const anyopaque,
        CreateFontFace: *const anyopaque,
        CreateRenderingParams: *const anyopaque,
        CreateMonitorRenderingParams: *const anyopaque,
        CreateCustomRenderingParams: *const anyopaque,
        RegisterFontFileLoader: *const anyopaque,
        UnregisterFontFileLoader: *const anyopaque,
        CreateTextFormat: *const anyopaque,
        CreateTypography: *const anyopaque,
        GetGdiInterop: *const anyopaque,
        CreateTextLayout: *const anyopaque,
        CreateGdiCompatibleTextLayout: *const anyopaque,
        CreateEllipsisTrimmingSign: *const anyopaque,
        CreateTextAnalyzer: *const anyopaque,
        CreateNumberSubstitution: *const anyopaque,
        CreateGlyphRunAnalysis: *const fn (
            *IDWriteFactory,
            *const DWRITE_GLYPH_RUN,
            f32,
            ?*const anyopaque,
            u32,
            u32,
            f32,
            f32,
            *?*IDWriteGlyphRunAnalysis,
        ) callconv(.winapi) HRESULT,
    };

    pub fn get_system_font_collection(
        self: *IDWriteFactory,
        out: *?*IDWriteFontCollection,
        check_updates: BOOL,
    ) HRESULT {
        return self.vtable.GetSystemFontCollection(self, out, check_updates);
    }
    pub fn create_glyph_run_analysis(
        self: *IDWriteFactory,
        run: *const DWRITE_GLYPH_RUN,
        pixels_per_dip: f32,
        rendering_mode: u32,
        measuring_mode: u32,
        baseline_x: f32,
        baseline_y: f32,
        out: *?*IDWriteGlyphRunAnalysis,
    ) HRESULT {
        return self.vtable.CreateGlyphRunAnalysis(
            self,
            run,
            pixels_per_dip,
            null,
            rendering_mode,
            measuring_mode,
            baseline_x,
            baseline_y,
            out,
        );
    }
    pub fn release(self: *IDWriteFactory) void {
        _ = self.vtable.Release(self);
    }
};

pub const IDWriteFontCollection = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*IDWriteFontCollection) callconv(.winapi) u32,
        GetFontFamilyCount: *const anyopaque,
        GetFontFamily: *const fn (
            *IDWriteFontCollection,
            u32,
            *?*IDWriteFontFamily,
        ) callconv(.winapi) HRESULT,
        FindFamilyName: *const fn (
            *IDWriteFontCollection,
            [*:0]const u16,
            *u32,
            *BOOL,
        ) callconv(.winapi) HRESULT,
    };

    pub fn find_family_name(
        self: *IDWriteFontCollection,
        name: [*:0]const u16,
        index: *u32,
        exists: *BOOL,
    ) HRESULT {
        return self.vtable.FindFamilyName(self, name, index, exists);
    }
    pub fn get_font_family(
        self: *IDWriteFontCollection,
        index: u32,
        out: *?*IDWriteFontFamily,
    ) HRESULT {
        return self.vtable.GetFontFamily(self, index, out);
    }
    pub fn release(self: *IDWriteFontCollection) void {
        _ = self.vtable.Release(self);
    }
};

pub const IDWriteFontFamily = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*IDWriteFontFamily) callconv(.winapi) u32,
        GetFontCollection: *const anyopaque,
        GetFontCount: *const anyopaque,
        GetFont: *const anyopaque,
        GetFamilyNames: *const anyopaque,
        GetFirstMatchingFont: *const fn (
            *IDWriteFontFamily,
            u32,
            u32,
            u32,
            *?*IDWriteFont,
        ) callconv(.winapi) HRESULT,
    };

    pub fn get_first_matching_font(
        self: *IDWriteFontFamily,
        weight: u32,
        stretch: u32,
        style: u32,
        out: *?*IDWriteFont,
    ) HRESULT {
        return self.vtable.GetFirstMatchingFont(self, weight, stretch, style, out);
    }
    pub fn release(self: *IDWriteFontFamily) void {
        _ = self.vtable.Release(self);
    }
};

pub const IDWriteFont = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*IDWriteFont) callconv(.winapi) u32,
        GetFontFamily: *const anyopaque,
        GetWeight: *const anyopaque,
        GetStretch: *const anyopaque,
        GetStyle: *const anyopaque,
        IsSymbolFont: *const anyopaque,
        GetFaceNames: *const anyopaque,
        GetInformationalStrings: *const anyopaque,
        GetSimulations: *const anyopaque,
        GetMetrics: *const anyopaque,
        HasCharacter: *const anyopaque,
        CreateFontFace: *const fn (*IDWriteFont, *?*IDWriteFontFace) callconv(.winapi) HRESULT,
    };

    pub fn create_font_face(self: *IDWriteFont, out: *?*IDWriteFontFace) HRESULT {
        return self.vtable.CreateFontFace(self, out);
    }
    pub fn release(self: *IDWriteFont) void {
        _ = self.vtable.Release(self);
    }
};

pub const IDWriteFontFace = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*IDWriteFontFace) callconv(.winapi) u32,
        GetType: *const anyopaque,
        GetFiles: *const anyopaque,
        GetIndex: *const anyopaque,
        GetSimulations: *const anyopaque,
        IsSymbolFont: *const anyopaque,
        GetMetrics: *const fn (*IDWriteFontFace, *DWRITE_FONT_METRICS) callconv(.winapi) void,
        GetGlyphCount: *const anyopaque,
        GetDesignGlyphMetrics: *const fn (
            *IDWriteFontFace,
            [*]const u16,
            u32,
            [*]DWRITE_GLYPH_METRICS,
            BOOL,
        ) callconv(.winapi) HRESULT,
        GetGlyphIndices: *const fn (
            *IDWriteFontFace,
            [*]const u32,
            u32,
            [*]u16,
        ) callconv(.winapi) HRESULT,
    };

    pub fn get_metrics(self: *IDWriteFontFace, out: *DWRITE_FONT_METRICS) void {
        self.vtable.GetMetrics(self, out);
    }
    pub fn get_design_glyph_metrics(
        self: *IDWriteFontFace,
        ids: [*]const u16,
        count: u32,
        out: [*]DWRITE_GLYPH_METRICS,
    ) HRESULT {
        return self.vtable.GetDesignGlyphMetrics(self, ids, count, out, win32.FALSE);
    }
    pub fn get_glyph_indices(
        self: *IDWriteFontFace,
        codepoints: [*]const u32,
        count: u32,
        out: [*]u16,
    ) HRESULT {
        return self.vtable.GetGlyphIndices(self, codepoints, count, out);
    }
    pub fn release(self: *IDWriteFontFace) void {
        _ = self.vtable.Release(self);
    }
};

pub const IDWriteGlyphRunAnalysis = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*IDWriteGlyphRunAnalysis) callconv(.winapi) u32,
        GetAlphaTextureBounds: *const fn (
            *IDWriteGlyphRunAnalysis,
            u32,
            *RECT,
        ) callconv(.winapi) HRESULT,
        CreateAlphaTexture: *const fn (
            *IDWriteGlyphRunAnalysis,
            u32,
            *const RECT,
            [*]u8,
            u32,
        ) callconv(.winapi) HRESULT,
    };

    pub fn get_alpha_texture_bounds(
        self: *IDWriteGlyphRunAnalysis,
        texture_type: u32,
        out: *RECT,
    ) HRESULT {
        return self.vtable.GetAlphaTextureBounds(self, texture_type, out);
    }
    pub fn create_alpha_texture(
        self: *IDWriteGlyphRunAnalysis,
        texture_type: u32,
        bounds: *const RECT,
        buf: [*]u8,
        size: u32,
    ) HRESULT {
        return self.vtable.CreateAlphaTexture(self, texture_type, bounds, buf, size);
    }
    pub fn release(self: *IDWriteGlyphRunAnalysis) void {
        _ = self.vtable.Release(self);
    }
};

pub extern "dwrite" fn DWriteCreateFactory(
    factory_type: u32,
    iid: *const GUID,
    factory: *?*anyopaque,
) callconv(.winapi) HRESULT;
