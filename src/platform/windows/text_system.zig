// WinTextSystem: the MacTextSystem analogue over DirectWrite. Shaping is a plain
// per-codepoint advance walk - enough for UI labels, not real text layout. Glyph
// coverage arrives as cleartype-3x1 subpixel and is averaged to grayscale, since
// the atlas is single-channel alpha.

const std = @import("std");
const win32 = @import("win32.zig");
const com = @import("com.zig");
const dwrite = @import("dwrite.zig");
const ts = @import("../../text_system.zig");
const geometry = @import("../../geometry.zig");

const Allocator = std.mem.Allocator;
const FontId = ts.FontId;
const FontWeight = ts.FontWeight;
const FontMetrics = ts.FontMetrics;
const LineLayout = ts.LineLayout;
const ShapedRun = ts.ShapedRun;
const ShapedGlyph = ts.ShapedGlyph;
const RenderGlyphParams = ts.RenderGlyphParams;
const GlyphBitmap = ts.GlyphBitmap;
const PlatformTextSystem = ts.PlatformTextSystem;

const FALLBACK_FAMILY = "Segoe UI";
const MAX_GLYPHS = 4096; // shaped-run cap; a longer line is truncated, not crashed
const MAX_GLYPH_PIXELS = 1024 * 1024; // one rasterized glyph's pixel budget

const FontEntry = struct {
    face: *dwrite.IDWriteFontFace,
    units_per_em: f32,
    ascent: f32,
    descent: f32,
    line_gap: f32,
    cap_height: f32,
    x_height: f32,
};

pub const WinTextSystem = struct {
    allocator: Allocator,
    factory: ?*dwrite.IDWriteFactory = null,
    collection: ?*dwrite.IDWriteFontCollection = null,

    fonts: std.ArrayListUnmanaged(FontEntry) = .empty,
    font_cache: std.StringHashMapUnmanaged(FontId) = .empty,

    run_buffer: std.ArrayListUnmanaged(ShapedRun) = .empty,
    glyph_buffer: std.ArrayListUnmanaged(ShapedGlyph) = .empty,
    bitmap_buffer: std.ArrayListUnmanaged(u8) = .empty,
    codepoints: std.ArrayListUnmanaged(u32) = .empty,
    gids: std.ArrayListUnmanaged(u16) = .empty,
    gmetrics: std.ArrayListUnmanaged(dwrite.DWRITE_GLYPH_METRICS) = .empty,

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        var self = Self{ .allocator = allocator };
        var factory: ?*anyopaque = null;
        if (com.succeeded(dwrite.DWriteCreateFactory(
            dwrite.DWRITE_FACTORY_TYPE_SHARED,
            &dwrite.IID_IDWriteFactory,
            &factory,
        ))) {
            self.factory = @ptrCast(@alignCast(factory.?));
            var collection: ?*dwrite.IDWriteFontCollection = null;
            if (com.succeeded(self.factory.?.get_system_font_collection(
                &collection,
                win32.FALSE,
            ))) {
                self.collection = collection;
            }
        }
        return self;
    }

    pub fn deinit(self: *Self) void {
        var it = self.font_cache.keyIterator();
        while (it.next()) |k| self.allocator.free(k.*);
        self.font_cache.deinit(self.allocator);
        for (self.fonts.items) |entry| entry.face.release();
        self.fonts.deinit(self.allocator);
        self.run_buffer.deinit(self.allocator);
        self.glyph_buffer.deinit(self.allocator);
        self.bitmap_buffer.deinit(self.allocator);
        self.codepoints.deinit(self.allocator);
        self.gids.deinit(self.allocator);
        self.gmetrics.deinit(self.allocator);
        if (self.collection) |c| c.release();
        if (self.factory) |f| f.release();
    }

    pub fn platform_text_system(self: *Self) PlatformTextSystem {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = PlatformTextSystem.VTable{
        .font_id = font_id_impl,
        .font_metrics = font_metrics_impl,
        .layout_line = layout_line_impl,
        .rasterize_glyph = rasterize_glyph_impl,
        .glyph_raster_bounds = glyph_raster_bounds_impl,
    };

    fn font_id_impl(ptr: *anyopaque, family: []const u8, weight: FontWeight) FontId {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.get_or_create_font(family, weight);
    }

    fn font_metrics_impl(ptr: *anyopaque, font_id: FontId, font_size: f32) FontMetrics {
        const self: *Self = @ptrCast(@alignCast(ptr));
        std.debug.assert(font_id < self.fonts.items.len);
        const e = self.fonts.items[font_id];
        std.debug.assert(e.units_per_em > 0);
        const scale = font_size / e.units_per_em;
        return .{
            .units_per_em = @intFromFloat(e.units_per_em),
            .ascent = e.ascent * scale,
            .descent = e.descent * scale,
            .line_gap = e.line_gap * scale,
            .cap_height = e.cap_height * scale,
            .x_height = e.x_height * scale,
        };
    }

    fn layout_line_impl(
        ptr: *anyopaque,
        text: []const u8,
        font_size: f32,
        font_id: FontId,
    ) LineLayout {
        const self: *Self = @ptrCast(@alignCast(ptr));
        std.debug.assert(font_id < self.fonts.items.len);
        const e = self.fonts.items[font_id];
        std.debug.assert(e.units_per_em > 0);
        const scale = font_size / e.units_per_em;

        self.shape_codepoints(text, e.face) catch {};
        const n = self.gids.items.len;
        std.debug.assert(n <= MAX_GLYPHS);

        self.glyph_buffer.clearRetainingCapacity();
        var pen_x: f32 = 0;
        // Tight ink extent above/below the baseline across the line's glyphs, in
        // design units (scaled to px after the walk). The Mac backend reads this
        // from CTLineGetImageBounds; here it comes from each glyph's black-box side
        // bearings, so centered_top centers identically on both platforms. Copying
        // the font ascent/descent (the line box) instead pushes short labels off
        // center.
        var ink_top: f32 = 0;
        var ink_bottom: f32 = 0;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            self.glyph_buffer.append(self.allocator, .{
                .id = self.gids.items[i],
                .position = .{ .x = pen_x, .y = 0 },
                .index = i,
                .is_emoji = false,
            }) catch break;
            const gm = self.gmetrics.items[i];
            pen_x += @as(f32, @floatFromInt(gm.advanceWidth)) * scale;
            const advance_height: i32 = @intCast(gm.advanceHeight);
            const glyph_top: i32 = gm.verticalOriginY - gm.topSideBearing;
            const glyph_bottom: i32 = advance_height - gm.verticalOriginY - gm.bottomSideBearing;
            ink_top = @max(ink_top, @as(f32, @floatFromInt(glyph_top)));
            ink_bottom = @max(ink_bottom, @as(f32, @floatFromInt(glyph_bottom)));
        }

        self.run_buffer.clearRetainingCapacity();
        self.run_buffer.append(self.allocator, .{
            .font_id = font_id,
            .glyphs = self.glyph_buffer.items,
        }) catch {};

        const ascent = e.ascent * scale;
        const descent = e.descent * scale;
        // Whitespace-only lines have no black box; fall back to cap height so
        // centering does not collapse the baseline onto the region center.
        const ink_ascent = if (ink_top > 0) ink_top * scale else e.cap_height * scale;
        const ink_descent = if (ink_bottom > 0) ink_bottom * scale else 0;
        std.debug.assert(ink_ascent >= 0);
        std.debug.assert(ink_descent >= 0);
        return .{
            .width = pen_x,
            .ascent = ascent,
            .descent = descent,
            .ink_ascent = ink_ascent,
            .ink_descent = ink_descent,
            .runs = self.run_buffer.items,
        };
    }

    fn rasterize_glyph_impl(ptr: *anyopaque, params: RenderGlyphParams) ?GlyphBitmap {
        const self: *Self = @ptrCast(@alignCast(ptr));
        var rect: win32.RECT = undefined;
        const analysis = self.glyph_analysis(params, &rect) orelse return null;
        defer analysis.release();

        const w: u32 = @intCast(@max(rect.right - rect.left, 0));
        const h: u32 = @intCast(@max(rect.bottom - rect.top, 0));
        if (w == 0 or h == 0) return null;
        std.debug.assert(@as(u64, w) * @as(u64, h) <= MAX_GLYPH_PIXELS);

        const rgb_len = w * h * 3;
        self.bitmap_buffer.resize(self.allocator, rgb_len) catch return null;
        const buf = self.bitmap_buffer.items;
        if (com.failed(analysis.create_alpha_texture(
            dwrite.DWRITE_TEXTURE_CLEARTYPE_3x1,
            &rect,
            buf.ptr,
            rgb_len,
        ))) {
            return null;
        }

        // Folded into the front of the same buffer: dst index <= src index always
        // holds for 3:1 compression, so the in-place overwrite is safe.
        var p: u32 = 0;
        while (p < w * h) : (p += 1) {
            const r: u32 = buf[p * 3];
            const g: u32 = buf[p * 3 + 1];
            const b: u32 = buf[p * 3 + 2];
            buf[p] = @intCast((r + g + b) / 3);
        }

        return .{
            .width = w,
            .height = h,
            .data = buf[0 .. w * h],
            .is_colored = false,
        };
    }

    fn glyph_raster_bounds_impl(ptr: *anyopaque, params: RenderGlyphParams) geometry.Bounds(i32) {
        const self: *Self = @ptrCast(@alignCast(ptr));
        var rect: win32.RECT = undefined;
        const analysis = self.glyph_analysis(params, &rect) orelse
            return geometry.Bounds(i32).init(0, 0, 0, 0);
        defer analysis.release();
        return geometry.Bounds(i32).init(
            rect.left,
            rect.top,
            rect.right - rect.left,
            rect.bottom - rect.top,
        );
    }

    fn glyph_analysis(
        self: *Self,
        params: RenderGlyphParams,
        out_rect: *win32.RECT,
    ) ?*dwrite.IDWriteGlyphRunAnalysis {
        const factory = self.factory orelse return null;
        if (params.font_id >= self.fonts.items.len) return null;
        const face = self.fonts.items[params.font_id].face;

        var ids = [_]u16{@intCast(params.glyph_id)};
        const run = dwrite.DWRITE_GLYPH_RUN{
            .fontFace = face,
            .fontEmSize = params.font_size * params.scale_factor,
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
        if (com.failed(a.get_alpha_texture_bounds(dwrite.DWRITE_TEXTURE_CLEARTYPE_3x1, out_rect))) {
            a.release();
            return null;
        }
        return a;
    }

    fn shape_codepoints(self: *Self, text: []const u8, face: *dwrite.IDWriteFontFace) !void {
        // Any failure route must leave the buffers empty, never the previous run's
        // glyphs, so the caller (which reads gids.len after `catch {}`) draws
        // nothing. errdefer covers the error returns; the void UTF-8 exit clears
        // explicitly since errdefer does not fire on a non-error return.
        errdefer {
            self.gids.clearRetainingCapacity();
            self.gmetrics.clearRetainingCapacity();
        }
        self.codepoints.clearRetainingCapacity();
        const view = std.unicode.Utf8View.init(text) catch {
            self.gids.clearRetainingCapacity();
            self.gmetrics.clearRetainingCapacity();
            return;
        };
        var it = view.iterator();
        // Cap the shaped run: a UI line past MAX_GLYPHS is degraded (truncated),
        // not crashed, matching the renderer's drop-overflow behavior.
        while (it.nextCodepoint()) |cp| {
            if (self.codepoints.items.len >= MAX_GLYPHS) break;
            try self.codepoints.append(self.allocator, cp);
        }

        const n = self.codepoints.items.len;
        std.debug.assert(n <= MAX_GLYPHS);
        try self.gids.resize(self.allocator, n);
        try self.gmetrics.resize(self.allocator, n);
        if (n == 0) return;
        const gi = face.get_glyph_indices(
            self.codepoints.items.ptr,
            @intCast(n),
            self.gids.items.ptr,
        );
        const gm = face.get_design_glyph_metrics(
            self.gids.items.ptr,
            @intCast(n),
            self.gmetrics.items.ptr,
        );
        // A failed shape leaves indeterminate gid/metric buffers; errdefer empties
        // them so the caller renders nothing rather than garbage glyphs.
        if (com.failed(gi) or com.failed(gm)) {
            return error.ShapeFailed;
        }
    }

    fn get_or_create_font(self: *Self, family: []const u8, weight: FontWeight) FontId {
        const lookup = if (family.len == 0 or std.mem.eql(u8, family, ".AppleSystemUIFont"))
            FALLBACK_FAMILY
        else
            family;

        var key_buf: [256]u8 = undefined;
        // The key must always carry the weight, else two weights of a long family
        // name collide. Font family names are far under this bound.
        std.debug.assert(lookup.len < key_buf.len - 12);
        const key = std.fmt.bufPrint(
            &key_buf,
            "{s}:{d}",
            .{ lookup, @intFromEnum(weight) },
        ) catch unreachable;
        if (self.font_cache.get(key)) |id| return id;

        const entry = self.create_face(lookup, weight) orelse
            self.create_face(FALLBACK_FAMILY, weight);
        const face = entry orelse return 0;

        const id: FontId = @intCast(self.fonts.items.len);
        self.fonts.append(self.allocator, face) catch {
            face.face.release();
            return 0;
        };
        const owned_key = self.allocator.dupe(u8, key) catch return id;
        self.font_cache.put(self.allocator, owned_key, id) catch self.allocator.free(owned_key);
        return id;
    }

    fn create_face(self: *Self, family: []const u8, weight: FontWeight) ?FontEntry {
        const collection = self.collection orelse return null;

        var wbuf: [128]u16 = undefined;
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
            @intFromEnum(weight),
            dwrite.DWRITE_FONT_STRETCH_NORMAL,
            dwrite.DWRITE_FONT_STYLE_NORMAL,
            &font_obj,
        ))) return null;
        const font = font_obj orelse return null;
        defer font.release();

        var face_obj: ?*dwrite.IDWriteFontFace = null;
        if (com.failed(font.create_font_face(&face_obj))) return null;
        const face = face_obj orelse return null;

        var m: dwrite.DWRITE_FONT_METRICS = undefined;
        face.get_metrics(&m);
        return .{
            .face = face,
            .units_per_em = @floatFromInt(m.designUnitsPerEm),
            .ascent = @floatFromInt(m.ascent),
            .descent = @floatFromInt(m.descent),
            .line_gap = @floatFromInt(m.lineGap),
            .cap_height = @floatFromInt(m.capHeight),
            .x_height = @floatFromInt(m.xHeight),
        };
    }
};
