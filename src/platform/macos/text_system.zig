const std = @import("std");
const objc = @import("objc.zig");
const text_system = @import("../../text_system.zig");
const geometry = @import("../../geometry.zig");

const Allocator = std.mem.Allocator;
const FontId = text_system.FontId;
const GlyphId = text_system.GlyphId;
const FontWeight = text_system.FontWeight;
const FontMetrics = text_system.FontMetrics;
const LineLayout = text_system.LineLayout;
const ShapedRun = text_system.ShapedRun;
const ShapedGlyph = text_system.ShapedGlyph;
const RenderGlyphParams = text_system.RenderGlyphParams;
const GlyphBitmap = text_system.GlyphBitmap;
const PlatformTextSystem = text_system.PlatformTextSystem;

const c = @import("core_text.zig");

const CFStringRef = c.CFStringRef;
const CFDictionaryRef = c.CFDictionaryRef;
const CTFontRef = c.CTFontRef;
const CTRunRef = c.CTRunRef;
const CGFloat = c.CGFloat;
const CGGlyph = c.CGGlyph;
const CGPoint = c.CGPoint;
const CGRect = c.CGRect;
const CFIndex = c.CFIndex;
const CFRange = c.CFRange;

const MAX_GLYPHS_PER_RUN: usize = 256;

// Register a bundled font FILE (process scope) so CTFontCreateWithName resolves it
// by the family name in its name table.
pub fn register_app_font(path: []const u8) bool {
    const url = c.CFURLCreateFromFileSystemRepresentation(null, path.ptr, @intCast(path.len), 0) orelse
        return false;
    defer c.CFRelease(url);
    return c.CTFontManagerRegisterFontsForURL(url, c.kCTFontManagerScopeProcess, null) != 0;
}

pub const MacTextSystem = struct {
    allocator: Allocator,
    fonts: std.ArrayListUnmanaged(CTFontRef) = .empty,
    font_cache: std.StringHashMapUnmanaged(FontId) = .empty,
    run_buffer: std.ArrayListUnmanaged(ShapedRun) = .empty,
    glyph_buffer: std.ArrayListUnmanaged(ShapedGlyph) = .empty,
    bitmap_buffer: std.ArrayListUnmanaged(u8) = .empty,

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        for (self.fonts.items) |font| c.CFRelease(font);
        self.fonts.deinit(self.allocator);

        var it = self.font_cache.keyIterator();
        while (it.next()) |key| self.allocator.free(key.*);
        self.font_cache.deinit(self.allocator);

        self.run_buffer.deinit(self.allocator);
        self.glyph_buffer.deinit(self.allocator);
        self.bitmap_buffer.deinit(self.allocator);
    }

    pub fn platform_text_system(self: *Self) PlatformTextSystem {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn font_id_impl(ptr: *anyopaque, family: []const u8, weight: FontWeight) FontId {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.get_or_create_font(family, weight);
    }

    fn font_metrics_impl(ptr: *anyopaque, font_id: FontId, font_size: f32) FontMetrics {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.get_font_metrics(font_id, font_size);
    }

    fn layout_line_impl(
        ptr: *anyopaque,
        text: []const u8,
        font_size: f32,
        font_id: FontId,
    ) LineLayout {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.layout_line(text, font_size, font_id);
    }

    fn rasterize_glyph_impl(ptr: *anyopaque, params: RenderGlyphParams) ?GlyphBitmap {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.rasterize_glyph(params);
    }

    fn glyph_raster_bounds_impl(ptr: *anyopaque, params: RenderGlyphParams) geometry.Bounds(i32) {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.get_glyph_raster_bounds(params);
    }

    const vtable = PlatformTextSystem.VTable{
        .font_id = font_id_impl,
        .font_metrics = font_metrics_impl,
        .layout_line = layout_line_impl,
        .rasterize_glyph = rasterize_glyph_impl,
        .glyph_raster_bounds = glyph_raster_bounds_impl,
    };

    fn get_or_create_font(self: *Self, family: []const u8, weight: FontWeight) FontId {
        var key_buf: [256]u8 = undefined;
        const key_len = @min(family.len, 240);
        @memcpy(key_buf[0..key_len], family[0..key_len]);
        const weight_str = @tagName(weight);
        @memcpy(key_buf[key_len .. key_len + weight_str.len], weight_str);
        const cache_key = key_buf[0 .. key_len + weight_str.len];

        if (self.font_cache.get(cache_key)) |font_id| return font_id;

        const family_str = create_cf_string(family);
        defer c.CFRelease(family_str);

        const base_font = blk: {
            if (std.mem.eql(u8, family, "SF Mono")) {
                if (monospaced_system_font(12.0)) |mono| break :blk mono;
            }
            const font = c.CTFontCreateWithName(family_str, 12.0, null);
            break :blk if (font != null)
                font
            else
                c.CTFontCreateUIFontForLanguage(c.kCTFontUIFontSystem, 12.0, null);
        };

        const weighted_font = apply_font_weight(base_font, weight);
        c.CFRelease(base_font);

        self.fonts.append(self.allocator, weighted_font) catch return 0;
        const font_id: FontId = @intCast(self.fonts.items.len - 1);

        const duped_key = self.allocator.dupe(u8, cache_key) catch return font_id;
        self.font_cache.put(self.allocator, duped_key, font_id) catch {
            self.allocator.free(duped_key);
        };

        return font_id;
    }

    fn get_font_metrics(self: *Self, font_id: FontId, font_size: f32) FontMetrics {
        if (font_id >= self.fonts.items.len) {
            return .{
                .units_per_em = 1000,
                .ascent = font_size * 0.8,
                .descent = font_size * 0.2,
                .line_gap = 0,
                .cap_height = font_size * 0.7,
                .x_height = font_size * 0.5,
            };
        }

        const base_font = self.fonts.items[font_id];
        const font = c.CTFontCreateCopyWithAttributes(base_font, font_size, null, null);
        defer c.CFRelease(font);

        return .{
            .units_per_em = @intCast(c.CTFontGetUnitsPerEm(font)),
            .ascent = @floatCast(c.CTFontGetAscent(font)),
            .descent = @floatCast(c.CTFontGetDescent(font)),
            .line_gap = @floatCast(c.CTFontGetLeading(font)),
            .cap_height = @floatCast(c.CTFontGetCapHeight(font)),
            .x_height = @floatCast(c.CTFontGetXHeight(font)),
        };
    }

    fn layout_line(self: *Self, text: []const u8, font_size: f32, font_id: FontId) LineLayout {
        self.run_buffer.clearRetainingCapacity();
        self.glyph_buffer.clearRetainingCapacity();
        const ink_fallback = font_size * 0.7;

        if (text.len == 0 or font_id >= self.fonts.items.len) {
            return .{
                .width = 0,
                .ascent = font_size * 0.8,
                .descent = font_size * 0.2,
                .ink_ascent = ink_fallback,
                .ink_descent = 0,
                .runs = &.{},
            };
        }

        const base_font = self.fonts.items[font_id];
        const font = c.CTFontCreateCopyWithAttributes(base_font, font_size, null, null);
        defer c.CFRelease(font);

        const cf_string = create_cf_string(text);
        defer c.CFRelease(cf_string);

        const attrs = create_attributes_dict(font);
        defer c.CFRelease(attrs);

        const attr_string = c.CFAttributedStringCreate(null, cf_string, attrs);
        defer c.CFRelease(attr_string);

        const line = c.CTLineCreateWithAttributedString(attr_string);
        defer c.CFRelease(line);

        var ascent: CGFloat = 0;
        var descent: CGFloat = 0;
        var leading: CGFloat = 0;
        const width = c.CTLineGetTypographicBounds(line, &ascent, &descent, &leading);

        // Ink rect is baseline-relative, y-up. Blank/whitespace-only lines
        // yield CGRectNull (non-finite); fall back to a cap-ish extent so
        // centering math can't produce NaN.
        const ink = c.CTLineGetImageBounds(line, null);
        var ink_top: f32 = @floatCast(ink.origin.y + ink.size.height);
        var ink_bot: f32 = @floatCast(-ink.origin.y);
        if (!std.math.isFinite(ink_top) or !std.math.isFinite(ink_bot)) {
            ink_top = ink_fallback;
            ink_bot = 0;
        }

        const glyph_runs = c.CTLineGetGlyphRuns(line);
        const run_count = c.CFArrayGetCount(glyph_runs);
        std.debug.assert(run_count >= 0);

        // Each run stores a slice INTO glyph_buffer, so a later run's append must
        // not realloc and dangle an earlier run's slice (multi-run = font-fallback
        // lines). Reserve the whole line's glyphs up front so no append moves it.
        var total_glyphs: usize = 0;
        var rc: CFIndex = 0;
        while (rc < run_count) : (rc += 1) {
            const run: CTRunRef = @ptrCast(@constCast(c.CFArrayGetValueAtIndex(glyph_runs, rc)));
            total_glyphs += @intCast(c.CTRunGetGlyphCount(run));
        }
        self.glyph_buffer.ensureUnusedCapacity(self.allocator, total_glyphs) catch {
            return .{
                .width = @floatCast(width),
                .ascent = @floatCast(ascent),
                .descent = @floatCast(descent),
                .ink_ascent = ink_top,
                .ink_descent = ink_bot,
                .runs = &.{},
            };
        };

        var i: CFIndex = 0;
        while (i < run_count) : (i += 1) {
            const run: CTRunRef = @ptrCast(@constCast(c.CFArrayGetValueAtIndex(glyph_runs, i)));
            self.extract_glyphs_from_run(run, font_id);
        }

        return .{
            .width = @floatCast(width),
            .ascent = @floatCast(ascent),
            .descent = @floatCast(descent),
            .ink_ascent = ink_top,
            .ink_descent = ink_bot,
            .runs = self.run_buffer.items,
        };
    }

    fn extract_glyphs_from_run(self: *Self, run: CTRunRef, default_font_id: FontId) void {
        const glyph_count = c.CTRunGetGlyphCount(run);
        if (glyph_count == 0) return;

        const run_attrs = c.CTRunGetAttributes(run);
        const font_attr = c.CFDictionaryGetValue(run_attrs, c.kCTFontAttributeName);
        const run_font: CTFontRef = @ptrCast(@constCast(font_attr));

        var actual_font_id = default_font_id;
        if (run_font != null) actual_font_id = self.get_or_register_font(run_font);

        var glyphs_buf: [MAX_GLYPHS_PER_RUN]CGGlyph = undefined;
        var positions_buf: [MAX_GLYPHS_PER_RUN]CGPoint = undefined;
        var indices_buf: [MAX_GLYPHS_PER_RUN]CFIndex = undefined;

        // one font run never approaches the cap in practice; @min keeps release safe
        std.debug.assert(glyph_count <= MAX_GLYPHS_PER_RUN);
        const count: usize = @intCast(@min(glyph_count, MAX_GLYPHS_PER_RUN));
        const range = CFRange{ .location = 0, .length = @intCast(count) };

        c.CTRunGetGlyphs(run, range, &glyphs_buf);
        c.CTRunGetPositions(run, range, &positions_buf);
        c.CTRunGetStringIndices(run, range, &indices_buf);

        const glyph_start = self.glyph_buffer.items.len;

        for (0..count) |j| {
            // OOM drops glyph, soft fail.
            self.glyph_buffer.append(self.allocator, .{
                .id = glyphs_buf[j],
                .position = .{
                    .x = @floatCast(positions_buf[j].x),
                    .y = @floatCast(positions_buf[j].y),
                },
                .index = @intCast(indices_buf[j]),
                .is_emoji = false,
            }) catch {};
        }

        const glyph_end = self.glyph_buffer.items.len;
        if (glyph_end > glyph_start) {
            self.run_buffer.append(self.allocator, .{
                .font_id = actual_font_id,
                .glyphs = self.glyph_buffer.items[glyph_start..glyph_end],
            }) catch {};
        }
    }

    fn get_or_register_font(self: *Self, font: CTFontRef) FontId {
        // PostScript name is size-independent, so dedup off the original font and
        // only pay the normalized CTFontCreateCopyWithAttributes copy on a miss.
        // (The old pointer-equality loop never matched - the copy was fresh each call.)
        const font_name = c.CTFontCopyPostScriptName(font);
        if (font_name != null) {
            defer c.CFRelease(font_name);

            var name_buf: [256]u8 = undefined;
            if (c.CFStringGetCString(font_name, &name_buf, 256, c.kCFStringEncodingUTF8) != 0) {
                const name_len = std.mem.indexOfScalar(u8, &name_buf, 0) orelse 256;
                const name_slice = name_buf[0..name_len];

                if (self.font_cache.get(name_slice)) |existing_id| return existing_id;

                const base_font = c.CTFontCreateCopyWithAttributes(font, 12.0, null, null);
                self.fonts.append(self.allocator, base_font) catch {
                    c.CFRelease(base_font);
                    return 0;
                };
                const font_id: FontId = @intCast(self.fonts.items.len - 1);

                const duped_key = self.allocator.dupe(u8, name_slice) catch return font_id;
                self.font_cache.put(self.allocator, duped_key, font_id) catch {
                    self.allocator.free(duped_key);
                };

                return font_id;
            }
        }

        // Nameless font: store a normalized copy unconditionally.
        const base_font = c.CTFontCreateCopyWithAttributes(font, 12.0, null, null);
        self.fonts.append(self.allocator, base_font) catch {
            c.CFRelease(base_font);
            return 0;
        };
        return @intCast(self.fonts.items.len - 1);
    }

    fn get_glyph_raster_bounds(self: *Self, params: RenderGlyphParams) geometry.Bounds(i32) {
        if (params.font_id >= self.fonts.items.len) return .{};

        const base_font = self.fonts.items[params.font_id];
        const scaled_size = params.font_size * params.scale_factor;
        const font = c.CTFontCreateCopyWithAttributes(base_font, scaled_size, null, null);
        defer c.CFRelease(font);

        const glyph_arr: [1]CGGlyph = .{@intCast(params.glyph_id)};
        var bounds_arr: [1]CGRect = undefined;
        _ = c.CTFontGetBoundingRectsForGlyphs(
            font,
            c.kCTFontOrientationDefault,
            &glyph_arr,
            &bounds_arr,
            1,
        );
        const bounds = bounds_arr[0];

        const subpixel_x: f32 = @as(f32, @floatFromInt(params.subpixel_variant.x)) / 4.0;
        const subpixel_y: f32 = @as(f32, @floatFromInt(params.subpixel_variant.y)) / 4.0;

        const x: i32 = @intFromFloat(@floor(bounds.origin.x + subpixel_x));
        const y: i32 = @intFromFloat(@floor(-bounds.origin.y - bounds.size.height + subpixel_y));
        const w: i32 = @intFromFloat(@ceil(bounds.size.width + 1));
        const h: i32 = @intFromFloat(@ceil(bounds.size.height + 1));

        return geometry.Bounds(i32).init(x, y, w, h);
    }

    fn rasterize_glyph(self: *Self, params: RenderGlyphParams) ?GlyphBitmap {
        if (params.font_id >= self.fonts.items.len) return null;
        if (params.is_emoji) return null; // color path deferred

        const bounds = self.get_glyph_raster_bounds(params);
        const width: u32 = @intCast(@max(0, bounds.size.width));
        const height: u32 = @intCast(@max(0, bounds.size.height));
        if (width == 0 or height == 0) return null;

        const base_font = self.fonts.items[params.font_id];
        const scaled_size = params.font_size * params.scale_factor;
        const font = c.CTFontCreateCopyWithAttributes(base_font, scaled_size, null, null);
        defer c.CFRelease(font);

        return self.rasterize_monochrome_glyph(params, font, bounds, width, height);
    }

    fn rasterize_monochrome_glyph(
        self: *Self,
        params: RenderGlyphParams,
        font: CTFontRef,
        bounds: geometry.Bounds(i32),
        width: u32,
        height: u32,
    ) ?GlyphBitmap {
        const byte_count = width * height;
        self.bitmap_buffer.clearRetainingCapacity();
        self.bitmap_buffer.resize(self.allocator, byte_count) catch return null;
        @memset(self.bitmap_buffer.items, 0);

        const color_space = c.CGColorSpaceCreateDeviceGray();
        defer c.CGColorSpaceRelease(color_space);

        const context = c.CGBitmapContextCreate(
            self.bitmap_buffer.items.ptr,
            width,
            height,
            8,
            width,
            color_space,
            0, // kCGImageAlphaNone - pure grayscale (alpha = coverage)
        );
        if (context == null) return null;
        defer c.CGContextRelease(context);

        c.CGContextSetGrayFillColor(context, 1.0, 1.0);
        c.CGContextSetAllowsAntialiasing(context, 1);
        c.CGContextSetShouldAntialias(context, 1);
        c.CGContextSetAllowsFontSubpixelPositioning(context, 1);
        c.CGContextSetShouldSubpixelPositionFonts(context, 1);
        c.CGContextSetShouldSmoothFonts(context, 0); // grayscale atlas

        const subpixel_x: f32 = @as(f32, @floatFromInt(params.subpixel_variant.x)) / 4.0;
        const subpixel_y: f32 = @as(f32, @floatFromInt(params.subpixel_variant.y)) / 4.0;

        const draw_x: CGFloat = -@as(CGFloat, @floatFromInt(bounds.origin.x)) + subpixel_x;
        const height_f: CGFloat = @floatFromInt(height);
        const origin_y_f: CGFloat = @floatFromInt(bounds.origin.y);
        const draw_y: CGFloat = height_f + origin_y_f + subpixel_y;

        const glyphs: [1]CGGlyph = .{@intCast(params.glyph_id)};
        const positions: [1]CGPoint = .{.{ .x = draw_x, .y = draw_y }};

        c.CTFontDrawGlyphs(font, &glyphs, &positions, 1, context);

        return .{
            .width = width,
            .height = height,
            .data = self.bitmap_buffer.items,
            .is_colored = false,
        };
    }
};

fn create_cf_string(str: []const u8) CFStringRef {
    return c.CFStringCreateWithBytes(
        null,
        str.ptr,
        @intCast(str.len),
        c.kCFStringEncodingUTF8,
        0,
    );
}

// Off = grid-safe for a mono editor (a "=>" ligature would collapse two cells
// into one glyph and desync the caret). Set once at startup.
var disable_liga: bool = false;

pub fn set_ligatures(on: bool) void {
    disable_liga = !on;
}

fn create_attributes_dict(font: CTFontRef) CFDictionaryRef {
    if (disable_liga) {
        // kCTLigatureAttributeName = 0 turns off standard ligatures (Geist Mono's
        // "=>" etc. are `liga`, not `calt`, so this covers them).
        const zero: c_int = 0;
        const num = c.CFNumberCreate(null, c.kCFNumberIntType, &zero);
        defer if (num) |n| c.CFRelease(n);
        var keys = [_]?*const anyopaque{ c.kCTFontAttributeName, c.kCTLigatureAttributeName };
        var values = [_]?*const anyopaque{ font, num };
        return c.CFDictionaryCreate(
            null,
            @ptrCast(&keys),
            @ptrCast(&values),
            2,
            &c.kCFTypeDictionaryKeyCallBacks,
            &c.kCFTypeDictionaryValueCallBacks,
        );
    }
    var keys = [_]?*const anyopaque{c.kCTFontAttributeName};
    var values = [_]?*const anyopaque{font};

    return c.CFDictionaryCreate(
        null,
        @ptrCast(&keys),
        @ptrCast(&values),
        1,
        &c.kCFTypeDictionaryKeyCallBacks,
        &c.kCFTypeDictionaryValueCallBacks,
    );
}

// SF Mono is the system monospaced font, not a registered family name, so
// CTFontCreateWithName substitutes a proportional face. The supported path is
// +[NSFont monospacedSystemFontOfSize:weight:], toll-free bridged to CTFont.
fn monospaced_system_font(size: CGFloat) CTFontRef {
    const cls = objc.get_class("NSFont") orelse return null;
    const font = objc.msg_send(
        CTFontRef,
        cls,
        "monospacedSystemFontOfSize:weight:",
        .{ size, @as(CGFloat, 0.0) },
    );
    if (font) |f| return c.CFRetain(f); // autoreleased return; own it like the CT creators
    return null;
}

fn apply_font_weight(font: CTFontRef, weight: FontWeight) CTFontRef {
    if (weight == .normal) {
        _ = c.CFRetain(font);
        return font;
    }

    const weight_value = ct_weight_from_font_weight(weight);
    const weight_num = c.CFNumberCreate(null, c.kCFNumberFloat64Type, &weight_value);
    defer c.CFRelease(weight_num);

    var trait_keys = [_]?*const anyopaque{c.kCTFontWeightTrait};
    var trait_values = [_]?*const anyopaque{weight_num};

    const traits_dict = c.CFDictionaryCreate(
        null,
        @ptrCast(&trait_keys),
        @ptrCast(&trait_values),
        1,
        &c.kCFTypeDictionaryKeyCallBacks,
        &c.kCFTypeDictionaryValueCallBacks,
    );
    defer c.CFRelease(traits_dict);

    var attr_keys = [_]?*const anyopaque{c.kCTFontTraitsAttribute};
    var attr_values = [_]?*const anyopaque{traits_dict};

    const attrs_dict = c.CFDictionaryCreate(
        null,
        @ptrCast(&attr_keys),
        @ptrCast(&attr_values),
        1,
        &c.kCFTypeDictionaryKeyCallBacks,
        &c.kCFTypeDictionaryValueCallBacks,
    );
    defer c.CFRelease(attrs_dict);

    const desc = c.CTFontDescriptorCreateWithAttributes(attrs_dict);
    defer c.CFRelease(desc);

    return c.CTFontCreateCopyWithAttributes(font, c.CTFontGetSize(font), null, desc);
}

// CoreText weight: -1.0 thin .. 1.0 black.
fn ct_weight_from_font_weight(weight: FontWeight) CGFloat {
    return switch (weight) {
        .thin => -0.8,
        .extra_light => -0.6,
        .light => -0.4,
        .normal => 0.0,
        .medium => 0.23,
        .semi_bold => 0.3,
        .bold => 0.4,
        .extra_bold => 0.56,
        .black => 0.8,
    };
}
