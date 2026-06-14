const std = @import("std");
const builtin = @import("builtin");
const geometry = @import("geometry.zig");
const color = @import("color.zig");
const primitives = @import("primitives.zig");

const Allocator = std.mem.Allocator;
const MonochromeSprite = primitives.MonochromeSprite;

pub const FontId = u32;
pub const GlyphId = u32;

pub const FontWeight = enum(u16) {
    thin = 100,
    extra_light = 200,
    light = 300,
    normal = 400,
    medium = 500,
    semi_bold = 600,
    bold = 700,
    extra_bold = 800,
    black = 900,

    pub fn to_f32(self: FontWeight) f32 {
        return @floatFromInt(@intFromEnum(self));
    }
};

pub const TextDecoration = enum {
    none,
    underline,
    strikethrough,
    underline_wavy,
};

pub const TextOverflow = union(enum) {
    wrap,
    ellipsis: []const u8,
    truncate,

    pub const default_ellipsis = "...";

    pub fn is_ellipsis(self: TextOverflow) bool {
        return switch (self) {
            .ellipsis => true,
            else => false,
        };
    }
};

pub const WhiteSpace = enum { normal, nowrap };

pub const FontMetrics = struct {
    units_per_em: u32,
    ascent: f32,
    descent: f32,
    line_gap: f32,
    cap_height: f32,
    x_height: f32,
};

pub const LineLayout = struct {
    width: f32,
    ascent: f32,
    descent: f32,
    // Glyph-ink extent above/below the baseline (points). Tracks real drawn
    // ink, not the font line box, so centering on it is exact for any casing.
    ink_ascent: f32,
    ink_descent: f32,
    runs: []const ShapedRun,
};

pub const ShapedLine = struct {
    text: []const u8,
    font_size: f32,
    width: f32,
    ascent: f32,
    descent: f32,
    ink_ascent: f32,
    ink_descent: f32,
    runs: []const ShapedRun,

    pub fn line_height(self: ShapedLine) f32 {
        return self.ascent + self.descent;
    }

    pub fn height(self: ShapedLine, multiplier: f32) f32 {
        return self.line_height() * multiplier;
    }
};

pub const ShapedRun = struct {
    font_id: FontId,
    glyphs: []const ShapedGlyph,
};

pub const ShapedGlyph = struct {
    id: GlyphId,
    position: geometry.Point(f32),
    index: usize,
    is_emoji: bool = false,
};

pub const RenderGlyphParams = struct {
    font_id: FontId,
    glyph_id: GlyphId,
    font_size: f32,
    subpixel_variant: geometry.Point(u8),
    scale_factor: f32,
    is_emoji: bool = false,
};

pub const GlyphBitmap = struct {
    width: u32,
    height: u32,
    data: []const u8,
    is_colored: bool = false, // true = RGBA8, false = alpha8

    pub fn bytes_per_pixel(self: GlyphBitmap) u32 {
        return if (self.is_colored) 4 else 1;
    }

    pub fn bytes_per_row(self: GlyphBitmap) u32 {
        return self.width * self.bytes_per_pixel();
    }
};

pub const GlyphKey = struct {
    font_id: FontId,
    glyph_id: GlyphId,
    font_size_bits: u32,
    subpixel_x: u8,
    subpixel_y: u8,
    is_emoji: bool,

    pub fn from_params(params: RenderGlyphParams) GlyphKey {
        return .{
            .font_id = params.font_id,
            .glyph_id = params.glyph_id,
            .font_size_bits = @bitCast(params.font_size * params.scale_factor),
            .subpixel_x = params.subpixel_variant.x,
            .subpixel_y = params.subpixel_variant.y,
            .is_emoji = params.is_emoji,
        };
    }

    // Seed 0 = glyph domain in the shared atlas; IconSystem uses 1.
    pub fn hash(self: GlyphKey) u64 {
        return std.hash.Wyhash.hash(0, std.mem.asBytes(&self));
    }
};

pub const AtlasTile = struct {
    texture_id: u32,
    bounds: geometry.Bounds(u32),
    raster_origin: geometry.Point(i32),
    is_colored: bool = false,
};

pub const PlatformTextSystem = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        font_id: *const fn (ptr: *anyopaque, family: []const u8, weight: FontWeight) FontId,
        font_metrics: *const fn (ptr: *anyopaque, font_id: FontId, font_size: f32) FontMetrics,
        layout_line: *const fn (
            ptr: *anyopaque,
            text: []const u8,
            font_size: f32,
            font_id: FontId,
        ) LineLayout,
        rasterize_glyph: *const fn (ptr: *anyopaque, params: RenderGlyphParams) ?GlyphBitmap,
        glyph_raster_bounds: *const fn (
            ptr: *anyopaque,
            params: RenderGlyphParams,
        ) geometry.Bounds(i32),
    };

    pub fn font_id(self: PlatformTextSystem, family: []const u8, weight: FontWeight) FontId {
        return self.vtable.font_id(self.ptr, family, weight);
    }

    pub fn font_metrics(self: PlatformTextSystem, id: FontId, font_size: f32) FontMetrics {
        return self.vtable.font_metrics(self.ptr, id, font_size);
    }

    pub fn layout_line(
        self: PlatformTextSystem,
        text: []const u8,
        font_size: f32,
        id: FontId,
    ) LineLayout {
        return self.vtable.layout_line(self.ptr, text, font_size, id);
    }

    pub fn rasterize_glyph(self: PlatformTextSystem, params: RenderGlyphParams) ?GlyphBitmap {
        return self.vtable.rasterize_glyph(self.ptr, params);
    }

    pub fn glyph_raster_bounds(
        self: PlatformTextSystem,
        params: RenderGlyphParams,
    ) geometry.Bounds(i32) {
        return self.vtable.glyph_raster_bounds(self.ptr, params);
    }
};

pub const TextStyle = struct {
    color: ?color.Rgba = null,
    font_size: ?f32 = null,
    font_weight: ?FontWeight = null,
    line_height: ?f32 = null,
    font_family: ?[]const u8 = null,
    decoration: ?TextDecoration = null,
    decoration_color: ?color.Rgba = null,
    overflow: ?TextOverflow = null,
    white_space: ?WhiteSpace = null,
    line_clamp: ?u32 = null,

    pub fn merge_with(self: TextStyle, inherited: TextStyle) TextStyle {
        var result: TextStyle = .{};
        inline for (@typeInfo(TextStyle).@"struct".fields) |field| {
            @field(result, field.name) =
                @field(self, field.name) orelse @field(inherited, field.name);
        }
        return result;
    }

    pub const default_style = TextStyle{
        .color = color.Rgba.white,
        .font_size = 14.0,
        .font_weight = .normal,
        .line_height = 1.3,
        .font_family = null,
        .decoration = .none,
        .decoration_color = null,
        .overflow = .wrap,
        .white_space = .normal,
        .line_clamp = null,
    };
};

// Android (os.tag == .linux) cannot dlopen the private system freetype/harfbuzz,
// so it rasterizes through android.graphics instead; the GPU atlas below is
// backend-neutral and stays shared with Linux.
const NativeText = if (builtin.abi.isAndroid())
    @import("platform/android/text_system.zig").AndroidTextSystem
else switch (builtin.os.tag) {
    .macos => @import("platform/macos/text_system.zig").MacTextSystem,
    .windows => @import("platform/windows/text_system.zig").WinTextSystem,
    .linux => @import("platform/linux/text_system.zig").LinuxTextSystem,
    else => @compileError("zigui: unsupported OS for TextSystem"),
};

const NativeAtlas = switch (builtin.os.tag) {
    .macos => @import("platform/macos/mono_atlas.zig").MetalMonoAtlas,
    .windows => @import("platform/windows/atlas.zig").WinMonoAtlas,
    .linux => @import("platform/linux/atlas.zig").LinuxMonoAtlas,
    else => @compileError("zigui: unsupported OS for mono atlas"),
};

pub const MonoAtlas = NativeAtlas;

const UNSET_FONT_ID: FontId = std.math.maxInt(FontId);

// layout_line returns runs/glyphs in reused scratch buffers, so this cache
// must own copies. Most labels are static across frames, so caching turns
// near-all per-frame reshaping into a hash hit.
const ShapeKey = struct { text: []const u8, size: f32, fid: FontId };

const ShapeKeyCtx = struct {
    pub fn hash(_: ShapeKeyCtx, k: ShapeKey) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(k.text);
        h.update(std.mem.asBytes(&k.size));
        h.update(std.mem.asBytes(&k.fid));
        return h.final();
    }
    pub fn eql(_: ShapeKeyCtx, a: ShapeKey, b: ShapeKey) bool {
        return a.fid == b.fid and a.size == b.size and std.mem.eql(u8, a.text, b.text);
    }
};

const ShapeEntry = struct {
    text: []u8, // owned; also the key's text backing
    runs: []ShapedRun, // owned
    glyphs: []ShapedGlyph, // owned backing for every run's glyph slice
    width: f32,
    ascent: f32,
    descent: f32,
    ink_ascent: f32,
    ink_descent: f32,
};

const ShapeCache = std.HashMap(
    ShapeKey,
    ShapeEntry,
    ShapeKeyCtx,
    std.hash_map.default_max_load_percentage,
);
// Clear wholesale past this many unique strings; dynamic text like counters
// would otherwise grow the cache without limit.
const SHAPE_CACHE_CAP: usize = 4096;

pub const TextSystem = struct {
    allocator: Allocator,
    native: NativeText,
    atlas: NativeAtlas,
    default_font_id: FontId = UNSET_FONT_ID,
    shape_cache: ShapeCache,

    pub fn init(allocator: Allocator, device: *anyopaque) TextSystem {
        return .{
            .allocator = allocator,
            .native = NativeText.init(allocator),
            .atlas = NativeAtlas.init(allocator, device),
            .shape_cache = ShapeCache.init(allocator),
        };
    }

    pub fn deinit(self: *TextSystem) void {
        self.clear_shape_cache();
        self.shape_cache.deinit();
        self.atlas.deinit();
        self.native.deinit();
    }

    fn clear_shape_cache(self: *TextSystem) void {
        var it = self.shape_cache.iterator();
        while (it.next()) |e| {
            self.allocator.free(e.value_ptr.glyphs);
            self.allocator.free(e.value_ptr.runs);
            self.allocator.free(e.value_ptr.text);
        }
        self.shape_cache.clearRetainingCapacity();
    }

    pub fn platform(self: *TextSystem) PlatformTextSystem {
        return self.native.platform_text_system();
    }

    pub fn ensure_default_font(self: *TextSystem) void {
        if (self.default_font_id == UNSET_FONT_ID) {
            self.default_font_id = self.platform().font_id(".AppleSystemUIFont", .normal);
        }
    }

    pub fn shape_text(
        self: *TextSystem,
        text: []const u8,
        font_size: f32,
        font_id: ?FontId,
    ) ShapedLine {
        std.debug.assert(font_size > 0);
        self.ensure_default_font();
        const fid = font_id orelse self.default_font_id;

        if (self.shape_cache.getPtr(.{ .text = text, .size = font_size, .fid = fid })) |e| {
            return .{
                .text = e.text,
                .font_size = font_size,
                .width = e.width,
                .ascent = e.ascent,
                .descent = e.descent,
                .ink_ascent = e.ink_ascent,
                .ink_descent = e.ink_descent,
                .runs = e.runs,
            };
        }

        const layout = self.platform().layout_line(text, font_size, fid);

        const cached = self.cache_line(text, font_size, fid, layout) catch {
            // Alloc failed: hand back the scratch-backed layout. Valid only
            // until the next shape call, which is how the caller consumes it.
            return .{
                .text = text,
                .font_size = font_size,
                .width = layout.width,
                .ascent = layout.ascent,
                .descent = layout.descent,
                .ink_ascent = layout.ink_ascent,
                .ink_descent = layout.ink_descent,
                .runs = layout.runs,
            };
        };
        return cached;
    }

    fn cache_line(
        self: *TextSystem,
        text: []const u8,
        font_size: f32,
        fid: FontId,
        layout: LineLayout,
    ) !ShapedLine {
        if (self.shape_cache.count() >= SHAPE_CACHE_CAP) self.clear_shape_cache();

        var total: usize = 0;
        for (layout.runs) |r| total += r.glyphs.len;

        const glyphs = try self.allocator.alloc(ShapedGlyph, total);
        errdefer self.allocator.free(glyphs);
        const runs = try self.allocator.alloc(ShapedRun, layout.runs.len);
        errdefer self.allocator.free(runs);
        const owned_text = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(owned_text);

        var gi: usize = 0;
        for (layout.runs, 0..) |r, i| {
            const start = gi;
            @memcpy(glyphs[start .. start + r.glyphs.len], r.glyphs);
            gi += r.glyphs.len;
            runs[i] = .{ .font_id = r.font_id, .glyphs = glyphs[start..gi] };
        }
        std.debug.assert(gi == total);

        try self.shape_cache.put(.{ .text = owned_text, .size = font_size, .fid = fid }, .{
            .text = owned_text,
            .runs = runs,
            .glyphs = glyphs,
            .width = layout.width,
            .ascent = layout.ascent,
            .descent = layout.descent,
            .ink_ascent = layout.ink_ascent,
            .ink_descent = layout.ink_descent,
        });

        return .{
            .text = owned_text,
            .font_size = font_size,
            .width = layout.width,
            .ascent = layout.ascent,
            .descent = layout.descent,
            .ink_ascent = layout.ink_ascent,
            .ink_descent = layout.ink_descent,
            .runs = runs,
        };
    }

    pub fn get_font_id(self: *TextSystem, family: []const u8, weight: FontWeight) FontId {
        return self.platform().font_id(family, weight);
    }

    pub fn get_font_metrics(self: *TextSystem, font_id: FontId, font_size: f32) FontMetrics {
        return self.platform().font_metrics(font_id, font_size);
    }

    pub fn mono_atlas_texture(self: *TextSystem) ?*anyopaque {
        return self.atlas.get_texture();
    }

    pub fn mono_atlas(self: *TextSystem) *NativeAtlas {
        return &self.atlas;
    }

    // origin_{x,y} = baseline position in point coords (top-left viewport).
    pub fn sprites_for_line(
        self: *TextSystem,
        line: ShapedLine,
        origin_x: f32,
        origin_y: f32,
        rgba: color.Rgba,
        scale_factor: f32,
        sprites: *std.ArrayListUnmanaged(MonochromeSprite),
        out_allocator: Allocator,
    ) !void {
        std.debug.assert(scale_factor > 0);
        const atlas_size_px: f32 = @floatFromInt(self.atlas.get_texture_size());

        for (line.runs) |run| {
            for (run.glyphs) |g| {
                const params = RenderGlyphParams{
                    .font_id = run.font_id,
                    .glyph_id = g.id,
                    .font_size = line.font_size,
                    .subpixel_variant = .{ .x = 0, .y = 0 },
                    .scale_factor = scale_factor,
                    .is_emoji = false,
                };
                const key_hash = GlyphKey.from_params(params).hash();

                var tile = self.atlas.get(key_hash);
                if (tile == null) {
                    const bitmap = self.platform().rasterize_glyph(params);
                    const bounds = self.platform().glyph_raster_bounds(params);
                    tile = self.atlas.get_or_insert(key_hash, bitmap, bounds.origin);
                }

                const t = tile orelse continue;

                const tw_px: f32 = @floatFromInt(t.bounds.size.width);
                const th_px: f32 = @floatFromInt(t.bounds.size.height);
                const ox_px: f32 = @floatFromInt(t.bounds.origin.x);
                const oy_px: f32 = @floatFromInt(t.bounds.origin.y);

                const sprite_w = tw_px / scale_factor;
                const sprite_h = th_px / scale_factor;

                const raster_x_pt: f32 = @as(f32, @floatFromInt(t.raster_origin.x)) / scale_factor;
                const raster_y_pt: f32 = @as(f32, @floatFromInt(t.raster_origin.y)) / scale_factor;

                var sx = origin_x + g.position.x + raster_x_pt;
                var sy = origin_y + raster_y_pt;
                // At 1x a fractional position drags the glyph through the
                // linear sampler half a pixel out of phase - visible blur. At
                // 2x+ subpixel placement is finer than the eye; leave it.
                if (scale_factor == 1.0) {
                    sx = @round(sx);
                    sy = @round(sy);
                }

                try sprites.append(out_allocator, .{
                    .position = .{ sx, sy },
                    .size = .{ sprite_w, sprite_h },
                    .uv_origin = .{ ox_px / atlas_size_px, oy_px / atlas_size_px },
                    .uv_size = .{ tw_px / atlas_size_px, th_px / atlas_size_px },
                    .sprite_color = .{ rgba.r, rgba.g, rgba.b, rgba.a },
                });
            }
        }
    }
};

test "FontWeight toF32" {
    try std.testing.expect(FontWeight.normal.to_f32() == 400);
    try std.testing.expect(FontWeight.bold.to_f32() == 700);
}

test "TextStyle.mergeWith inherits when null" {
    const a: TextStyle = .{ .font_size = 16 };
    const b: TextStyle = .{ .font_size = 14, .font_weight = .bold };
    const m = a.merge_with(b);
    try std.testing.expect(m.font_size.? == 16);
    try std.testing.expect(m.font_weight.? == .bold);
}

test "GlyphKey.fromParams bit-casts font_size" {
    const params = RenderGlyphParams{
        .font_id = 1,
        .glyph_id = 42,
        .font_size = 16.0,
        .subpixel_variant = .{ .x = 0, .y = 0 },
        .scale_factor = 2.0,
        .is_emoji = false,
    };
    const key = GlyphKey.from_params(params);
    try std.testing.expect(key.font_id == 1 and key.glyph_id == 42);
    try std.testing.expect(key.font_size_bits == @as(u32, @bitCast(@as(f32, 32.0))));
}
