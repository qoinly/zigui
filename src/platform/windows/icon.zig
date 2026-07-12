// WinIconSystem: the MacIconSystem analogue. macOS draws SF Symbols; Windows maps
// each portable Icon to a Segoe Fluent Icons glyph and rasterizes it through
// DirectWrite to a grayscale coverage mask (the same GlyphRunAnalysis path the
// text system uses). Self-contained: owns its factory + the icon font face, so
// IconSystem can build it from an allocator alone.
//
// name_for returns the glyph as a UTF-8 codepoint string ("" when Segoe has no
// clean match - rasterize then returns null, the engine warns once, and the
// caller can ask for .source = .bundled, which always draws). A font that lacks
// a mapped codepoint yields glyph index 0, also handled as null.

const std = @import("std");
const win32 = @import("win32.zig");
const com = @import("com.zig");
const dwrite = @import("dwrite.zig");
const icon_system = @import("../../icon.zig");
const text_system = @import("../../text_system.zig");

const Allocator = std.mem.Allocator;
const Icon = icon_system.Icon;
const IconParams = icon_system.IconParams;
const PlatformIconSystem = icon_system.PlatformIconSystem;
const GlyphBitmap = text_system.GlyphBitmap;

const MAX_ICON_PIXELS = 512 * 512; // one rasterized icon's pixel budget

const ICON_FAMILY = "Segoe Fluent Icons";
const ICON_FAMILY_FALLBACK = "Segoe MDL2 Assets";

pub const WinIconSystem = struct {
    allocator: Allocator,
    factory: ?*dwrite.IDWriteFactory = null,
    face: ?*dwrite.IDWriteFontFace = null,
    bitmap_buffer: std.ArrayListUnmanaged(u8) = .empty,

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        var self = Self{ .allocator = allocator };
        var factory: ?*anyopaque = null;
        if (com.failed(dwrite.DWriteCreateFactory(
            dwrite.DWRITE_FACTORY_TYPE_SHARED,
            &dwrite.IID_IDWriteFactory,
            &factory,
        ))) return self;
        self.factory = @ptrCast(@alignCast(factory.?));

        var collection: ?*dwrite.IDWriteFontCollection = null;
        if (com.failed(self.factory.?.get_system_font_collection(&collection, win32.FALSE))) {
            return self;
        }
        const coll = collection orelse return self;
        defer coll.release();

        self.face = create_face(coll, ICON_FAMILY) orelse create_face(coll, ICON_FAMILY_FALLBACK);
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.bitmap_buffer.deinit(self.allocator);
        if (self.face) |f| f.release();
        if (self.factory) |f| f.release();
    }

    pub fn platform_icon_system(self: *Self) PlatformIconSystem {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = PlatformIconSystem.VTable{
        .rasterize = rasterize_impl,
    };

    // Segoe Fluent Icons codepoint per portable Icon, as a UTF-8 string. "" means
    // no clean Segoe match - the engine falls back / warns. Distinct, confident
    // glyphs only; an absent codepoint is caught by the glyph-index-0 guard.
    pub fn name_for(self: *Self, ic: Icon) []const u8 {
        _ = self;
        return switch (ic) {
            .close => "\u{E711}", // Cancel
            .close_circle => "", // no clean outline match
            .close_circle_fill => "\u{EB90}", // StatusErrorFull
            .check => "\u{E10B}", // Accept
            .check_circle => "", // no clean outline match
            .check_circle_fill => "\u{EC61}", // CompletedSolid
            .plus => "\u{E710}", // Add
            .plus_square => "", // no clean match
            .minus => "\u{E738}", // Remove
            .chevron_up => "\u{E70E}", // ChevronUp
            .chevron_down => "\u{E70D}", // ChevronDown
            .chevron_left => "\u{E76B}", // ChevronLeft
            .chevron_right => "\u{E76C}", // ChevronRight
            .chevron_up_down => "\u{E8CB}", // Sort
            .arrow_right => "\u{E72A}", // Forward
            .arrow_clockwise => "\u{E72C}", // Refresh
            .arrow_down_circle => "", // no clean circle match
            .arrow_down_to_line => "\u{E896}", // Download
            .search => "\u{E721}", // Search
            .sidebar => "\u{E700}", // GlobalNavButton
            .gear => "\u{E713}", // Settings
            .gear_fill => "", // no distinct fill
            .info => "\u{E946}", // Info
            .warning => "\u{E7BA}", // Warning
            .bold => "\u{E8DD}", // Bold
            .italic => "\u{E8DB}", // Italic
            .underline => "\u{E8DC}", // Underline
            .align_left => "\u{E8E4}", // AlignLeft
            .align_center => "\u{E8E3}", // AlignCenter
            .align_right => "\u{E8E2}", // AlignRight
            .share => "\u{E72D}", // Share
            .save => "\u{E74E}", // Save
            .copy => "\u{E8C8}", // Copy
            .grid => "\u{F0E2}", // GridView
            .layout_grid => "\u{F0E2}", // GridView; Segoe has no distinct layout-grid glyph
            .bell => "\u{E7ED}", // Ringer
            .bell_badge => "", // no distinct badge variant
            .pin => "\u{E718}", // Pin
            .eye => "\u{E7B3}", // RedEye
            .eye_slash => "\u{ED1A}", // Hide
            .calendar => "\u{E787}", // Calendar
            .folder => "\u{E8B7}", // Folder
            .trash => "\u{E74D}", // Delete
            .doc => "\u{E8A5}", // Document
            .envelope => "\u{E715}", // Mail
            .message => "\u{E8BD}", // Message
            .person => "\u{E77B}", // Contact
            .people => "\u{E716}", // People
            .people_fill => "", // no distinct fill
            .creditcard => "\u{E8C7}", // PaymentCard
            .creditcard_fill => "", // no distinct fill
            .heart => "\u{EB51}", // Heart
            .moon => "\u{E708}", // QuietHours
            .sun => "\u{E706}", // Brightness
            .chart_bar => "", // no clean Segoe match
            .dollar_sign => "", // no $ glyph in the icon font
            .bolt => "", // no clean bolt match
            .archive => "\u{E7B8}", // Archive
            .battery => "\u{E83F}", // BatteryFull
            .cpu => "\u{E950}", // System
            .wifi => "\u{E701}", // WiFi
            .hard_drive => "\u{EDA2}", // Harddisk
            .package => "", // no clean Segoe match
            .wrench => "\u{E90F}", // Repair
            .ellipsis => "\u{E712}", // More
            .pencil => "\u{E70F}", // Edit
            .star => "\u{E734}", // FavoriteStar
            .corner_down_left => "", // no clean Segoe match -> bundled Lucide
            .braces => "", // -> bundled Lucide
            .code => "\u{E943}", // Code
            .file_code => "", // -> bundled Lucide
            .markdown => "", // -> bundled Lucide
            .image => "\u{EB9F}", // Photo2
        };
    }

    fn rasterize_impl(ptr: *anyopaque, params: IconParams) ?GlyphBitmap {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.rasterize(params);
    }

    fn rasterize(self: *Self, params: IconParams) ?GlyphBitmap {
        std.debug.assert(params.scale_factor > 0);
        const face = self.face orelse return null;
        const factory = self.factory orelse return null;
        if (params.name.len == 0) return null;

        // name_for hands back one Segoe glyph as UTF-8 (1-4 bytes); decode that
        // leading codepoint. An unmapped icon yields glyph 0 -> null below.
        const seq_len = std.unicode.utf8ByteSequenceLength(params.name[0]) catch return null;
        if (params.name.len < seq_len) return null;
        const cp = std.unicode.utf8Decode(params.name[0..seq_len]) catch return null;
        const codepoint: u32 = cp;
        var gid: u16 = 0;
        _ = face.get_glyph_indices(@ptrCast(&codepoint), 1, @ptrCast(&gid));
        if (gid == 0) return null; // the installed icon font lacks this glyph

        var ids = [_]u16{gid};
        const run = dwrite.DWRITE_GLYPH_RUN{
            .fontFace = face,
            .fontEmSize = params.point_size * params.scale_factor,
            .glyphCount = 1,
            .glyphIndices = &ids,
            .glyphAdvances = null,
            .glyphOffsets = null,
            .isSideways = win32.FALSE,
            .bidiLevel = 0,
        };
        var analysis: ?*dwrite.IDWriteGlyphRunAnalysis = null;
        if (com.failed(factory.create_glyph_run_analysis(
            &run,
            1.0,
            dwrite.DWRITE_RENDERING_MODE_NATURAL,
            dwrite.DWRITE_MEASURING_MODE_NATURAL,
            0,
            0,
            &analysis,
        ))) return null;
        const a = analysis orelse return null;
        defer a.release();

        var rect: win32.RECT = undefined;
        if (com.failed(a.get_alpha_texture_bounds(dwrite.DWRITE_TEXTURE_CLEARTYPE_3x1, &rect))) {
            return null;
        }
        const w: u32 = @intCast(@max(rect.right - rect.left, 0));
        const h: u32 = @intCast(@max(rect.bottom - rect.top, 0));
        if (w == 0 or h == 0) return null;
        std.debug.assert(@as(u64, w) * @as(u64, h) <= MAX_ICON_PIXELS);

        const rgb_len = w * h * 3;
        self.bitmap_buffer.resize(self.allocator, rgb_len) catch return null;
        const buf = self.bitmap_buffer.items;
        const tex_type = dwrite.DWRITE_TEXTURE_CLEARTYPE_3x1;
        if (com.failed(a.create_alpha_texture(tex_type, &rect, buf.ptr, rgb_len))) {
            return null;
        }

        // Average the three subpixel coverages into one grayscale alpha, in place
        // (dst index <= src index), matching the text glyph path.
        var p: u32 = 0;
        while (p < w * h) : (p += 1) {
            const r: u32 = buf[p * 3];
            const g: u32 = buf[p * 3 + 1];
            const b: u32 = buf[p * 3 + 2];
            buf[p] = @intCast((r + g + b) / 3);
        }

        return .{ .width = w, .height = h, .data = buf[0 .. w * h], .is_colored = false };
    }
};

fn create_face(
    collection: *dwrite.IDWriteFontCollection,
    family: []const u8,
) ?*dwrite.IDWriteFontFace {
    std.debug.assert(family.len > 0);
    var wbuf: [64]u16 = undefined;
    const wlen = std.unicode.utf8ToUtf16Le(&wbuf, family) catch return null;
    if (wlen >= wbuf.len) return null;
    wbuf[wlen] = 0;
    const wname: [*:0]const u16 = @ptrCast(&wbuf);

    var index: u32 = 0;
    var exists: win32.BOOL = win32.FALSE;
    if (com.failed(collection.find_family_name(wname, &index, &exists))) return null;
    if (exists == win32.FALSE) return null;

    var family_obj: ?*dwrite.IDWriteFontFamily = null;
    if (com.failed(collection.get_font_family(index, &family_obj))) return null;
    const fam = family_obj orelse return null;
    defer fam.release();

    var font_obj: ?*dwrite.IDWriteFont = null;
    if (com.failed(fam.get_first_matching_font(
        dwrite.DWRITE_FONT_WEIGHT_NORMAL,
        dwrite.DWRITE_FONT_STRETCH_NORMAL,
        dwrite.DWRITE_FONT_STYLE_NORMAL,
        &font_obj,
    ))) return null;
    const font = font_obj orelse return null;
    defer font.release();

    var face_obj: ?*dwrite.IDWriteFontFace = null;
    if (com.failed(font.create_font_face(&face_obj))) return null;
    return face_obj;
}
