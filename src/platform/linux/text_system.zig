// Linux text system: fontconfig finds the font file, HarfBuzz shapes in design
// units (the DWrite-path arithmetic: scale = font_size / upem applied here),
// FreeType rasterizes. Mirrors the WinTextSystem contract - reused scratch
// buffers, one run per line, ink extents from glyph black boxes so centering
// matches the macOS CTLineGetImageBounds behavior.

const std = @import("std");
const ts = @import("../../text_system.zig");
const geometry = @import("../../geometry.zig");
const fc = @import("fontconfig.zig");
const ft = @import("freetype.zig");
const hb = @import("harfbuzz.zig");

const Allocator = std.mem.Allocator;

const FALLBACK_FAMILY = "sans-serif";
const EMOJI_FAMILY = "emoji"; // fontconfig generic -> the system color-emoji font (e.g. Noto Color Emoji)
const GRINNING_FACE: u32 = 0x1F600; // probe codepoint to confirm a real emoji font resolved

// Toggle ligatures/contextual-alternates for all shaping (off = grid-safe for a
// mono editor). Set once at startup before any text is shaped.
pub fn set_ligatures(on: bool) void {
    hb.disable_liga = !on;
}

// Register a bundled font FILE (process-global) so it matches by its family name.
pub fn register_app_font(path: []const u8) bool {
    var buf: [4096]u8 = undefined;
    if (path.len >= buf.len) return false;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return fc.add_app_font(@ptrCast(&buf));
}
const MAX_GLYPHS = 4096; // shaped-run cap; a longer line is truncated, not crashed
const MAX_GLYPH_PIXELS = 1024 * 1024; // one rasterized glyph's pixel budget

const FontEntry = struct {
    ft_face: *ft.Face,
    hb_font: *hb.Font,
    units_per_em: f32,
    ascent: f32, // design units, positive up
    descent: f32, // design units, positive down
    line_gap: f32,
    cap_height: f32,
    x_height: f32,
    size_px: f32 = 0, // last FT_Set_Char_Size, to skip redundant resizes
    strike_ppem: f32 = 0, // >0 for a bitmap-strike (color emoji) font: its native ppem, to scale from
};

pub const LinuxTextSystem = struct {
    allocator: Allocator,
    loaded: bool = false,
    hb_buffer: ?*hb.Buffer = null,

    fonts: std.ArrayListUnmanaged(FontEntry) = .empty,
    font_cache: std.StringHashMapUnmanaged(ts.FontId) = .empty,

    run_buffer: std.ArrayListUnmanaged(ts.ShapedRun) = .empty,
    glyph_buffer: std.ArrayListUnmanaged(ts.ShapedGlyph) = .empty,
    bitmap_buffer: std.ArrayListUnmanaged(u8) = .empty,

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        var self = Self{ .allocator = allocator };
        fc.load() catch return self;
        ft.load() catch return self;
        hb.load() catch return self;
        self.hb_buffer = hb.buffer_create() orelse return self;
        self.loaded = true;
        return self;
    }

    pub fn deinit(self: *Self) void {
        var it = self.font_cache.keyIterator();
        while (it.next()) |k| self.allocator.free(k.*);
        self.font_cache.deinit(self.allocator);
        for (self.fonts.items) |entry| {
            hb.font_destroy(entry.hb_font);
            ft.done_face(entry.ft_face);
        }
        self.fonts.deinit(self.allocator);
        self.run_buffer.deinit(self.allocator);
        self.glyph_buffer.deinit(self.allocator);
        self.bitmap_buffer.deinit(self.allocator);
        if (self.hb_buffer) |buffer| hb.buffer_destroy(buffer);
    }

    pub fn platform_text_system(self: *Self) ts.PlatformTextSystem {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = ts.PlatformTextSystem.VTable{
        .font_id = font_id_impl,
        .font_metrics = font_metrics_impl,
        .layout_line = layout_line_impl,
        .rasterize_glyph = rasterize_glyph_impl,
        .glyph_raster_bounds = glyph_raster_bounds_impl,
    };

    fn font_id_impl(ptr: *anyopaque, family: []const u8, weight: ts.FontWeight) ts.FontId {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.get_or_create_font(family, weight);
    }

    fn get_or_create_font(self: *Self, family: []const u8, weight: ts.FontWeight) ts.FontId {
        if (!self.loaded) return 0;
        // The macOS system-font name reaches this backend through shared kit
        // defaults; fontconfig's substitution owns the real default pick.
        const lookup = if (family.len == 0 or std.mem.eql(u8, family, ".AppleSystemUIFont"))
            FALLBACK_FAMILY
        else
            family;

        var key_buf: [256]u8 = undefined;
        std.debug.assert(lookup.len < key_buf.len - 12);
        const key = std.fmt.bufPrint(
            &key_buf,
            "{s}:{d}",
            .{ lookup, @intFromEnum(weight) },
        ) catch unreachable;
        if (self.font_cache.get(key)) |id| return id;

        const entry = self.create_font(lookup, weight) orelse
            self.create_font(FALLBACK_FAMILY, weight) orelse return 0;

        const id: ts.FontId = @intCast(self.fonts.items.len);
        self.fonts.append(self.allocator, entry) catch {
            hb.font_destroy(entry.hb_font);
            ft.done_face(entry.ft_face);
            return 0;
        };
        const owned_key = self.allocator.dupe(u8, key) catch return id;
        self.font_cache.put(self.allocator, owned_key, id) catch self.allocator.free(owned_key);
        return id;
    }

    fn create_font(self: *Self, family: []const u8, weight: ts.FontWeight) ?FontEntry {
        std.debug.assert(self.loaded);
        var family_z: [256]u8 = undefined;
        if (family.len >= family_z.len) return null;
        @memcpy(family_z[0..family.len], family);
        family_z[family.len] = 0;

        const matched = fc.match(@ptrCast(&family_z), @intFromEnum(weight)) orelse return null;
        defer matched.deinit();

        const ft_face = ft.new_face(matched.path.ptr, matched.index) orelse return null;
        const hb_pair = hb.font_from_file(matched.path.ptr, @intCast(matched.index)) orelse {
            ft.done_face(ft_face);
            return null;
        };
        std.debug.assert(hb_pair.upem > 0);
        const upem: f32 = @floatFromInt(hb_pair.upem);

        var cap: i32 = 0;
        if (!hb.metric_position(hb_pair.font, hb.METRICS_TAG_CAP_HEIGHT, &cap))
            cap = @intFromFloat(upem * 0.7);
        var x_height: i32 = 0;
        if (!hb.metric_position(hb_pair.font, hb.METRICS_TAG_X_HEIGHT, &x_height))
            x_height = @intFromFloat(upem * 0.5);

        return .{
            .ft_face = ft_face,
            .hb_font = hb_pair.font,
            .units_per_em = upem,
            .ascent = @floatFromInt(ft_face.ascender),
            .descent = @floatFromInt(-@as(i32, ft_face.descender)),
            .line_gap = @max(0, @as(f32, @floatFromInt(ft_face.height)) -
                @as(f32, @floatFromInt(ft_face.ascender - ft_face.descender))),
            .cap_height = @floatFromInt(cap),
            .x_height = @floatFromInt(x_height),
        };
    }

    fn font_metrics_impl(ptr: *anyopaque, font_id: ts.FontId, font_size: f32) ts.FontMetrics {
        const self: *Self = @ptrCast(@alignCast(ptr));
        std.debug.assert(font_id < self.fonts.items.len);
        std.debug.assert(font_size > 0);
        const e = self.fonts.items[font_id];
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

    // Accumulator threaded through the per-font segments of one line (positions/ink in points).
    const LineAcc = struct { pen_pt: f32 = 0, ink_top_pt: f32 = 0, ink_bottom_pt: f32 = 0 };

    // Shape one same-font run of the line and append its glyphs (+ a run) to the buffers, advancing
    // the pen in points. `byte_base` maps segment-local clusters back to the whole line (caret math).
    fn shape_segment(self: *Self, seg: []const u8, entry: FontEntry, run_font_id: ts.FontId, font_size: f32, byte_base: usize, acc: *LineAcc) void {
        if (seg.len == 0) return;
        const scale = font_size / entry.units_per_em;
        const shaped = hb.shape(entry.hb_font, self.hb_buffer.?, seg) orelse return;
        const run_start = self.glyph_buffer.items.len;
        var i: u32 = 0;
        while (i < shaped.len and self.glyph_buffer.items.len < MAX_GLYPHS) : (i += 1) {
            const info = shaped.infos[i];
            const pos = shaped.positions[i];
            self.glyph_buffer.append(self.allocator, .{
                .id = info.codepoint, // post-shaping this is the glyph id, not a char
                .position = .{ .x = acc.pen_pt + @as(f32, @floatFromInt(pos.x_offset)) * scale, .y = 0 },
                .index = @intCast(byte_base + info.cluster),
                .is_emoji = false, // color routing keys off the run's font in the rasterizer, not this
            }) catch break;
            acc.pen_pt += @as(f32, @floatFromInt(pos.x_advance)) * scale;
            var extents: hb.GlyphExtents = undefined;
            if (hb.glyph_extents(entry.hb_font, info.codepoint, &extents)) {
                const bottom = -(extents.y_bearing + extents.height);
                acc.ink_top_pt = @max(acc.ink_top_pt, @as(f32, @floatFromInt(extents.y_bearing)) * scale);
                acc.ink_bottom_pt = @max(acc.ink_bottom_pt, @as(f32, @floatFromInt(bottom)) * scale);
            }
        }
        if (self.glyph_buffer.items.len > run_start) {
            self.run_buffer.append(self.allocator, .{ .font_id = run_font_id, .glyphs = self.glyph_buffer.items[run_start..] }) catch {};
        }
    }

    fn layout_line_impl(
        ptr: *anyopaque,
        text: []const u8,
        font_size: f32,
        font_id: ts.FontId,
    ) ts.LineLayout {
        const self: *Self = @ptrCast(@alignCast(ptr));
        std.debug.assert(font_size > 0);
        if (!self.loaded or font_id >= self.fonts.items.len) return empty_layout();
        const primary = self.fonts.items[font_id]; // a copy: safe across the get_or_create_font realloc below

        // The emoji fallback font (lazily created + cached). get_or_create_font may grow self.fonts,
        // but `primary` is a copy and font_id stays a valid index, so both survive the realloc.
        const emoji_id = self.get_or_create_font(EMOJI_FAMILY, .normal);
        const has_emoji = emoji_id != font_id and emoji_id < self.fonts.items.len and
            hb.has_glyph(self.fonts.items[emoji_id].hb_font, GRINNING_FACE);
        const emoji = if (has_emoji) self.fonts.items[emoji_id] else primary;

        self.glyph_buffer.clearRetainingCapacity();
        self.run_buffer.clearRetainingCapacity();
        // Reserve up front so run glyph-slices stay valid as later segments append (no realloc).
        self.glyph_buffer.ensureTotalCapacity(self.allocator, MAX_GLYPHS) catch return empty_layout();

        var acc: LineAcc = .{};
        // Split the line into maximal runs the primary font covers vs the emoji font, shaping each with
        // its own font. Whitespace/control stay on the primary font (it covers them; no run split).
        var seg_start: usize = 0;
        var seg_primary = true;
        var have_seg = false;
        var off: usize = 0;
        while (off < text.len) {
            const len = std.unicode.utf8ByteSequenceLength(text[off]) catch 1;
            const end = @min(off + len, text.len);
            const cp = std.unicode.utf8Decode(text[off..end]) catch {
                off += 1;
                continue;
            };
            const use_primary = cp <= 0x20 or !has_emoji or hb.has_glyph(primary.hb_font, cp);
            if (!have_seg) {
                seg_primary = use_primary;
                seg_start = off;
                have_seg = true;
            } else if (use_primary != seg_primary) {
                self.shape_segment(text[seg_start..off], if (seg_primary) primary else emoji, if (seg_primary) font_id else emoji_id, font_size, seg_start, &acc);
                seg_start = off;
                seg_primary = use_primary;
            }
            off = end;
        }
        if (have_seg) {
            self.shape_segment(text[seg_start..], if (seg_primary) primary else emoji, if (seg_primary) font_id else emoji_id, font_size, seg_start, &acc);
        }
        if (self.run_buffer.items.len == 0) return whitespace_layout(primary, font_size);

        const p_scale = font_size / primary.units_per_em;
        const ink_ascent = if (acc.ink_top_pt > 0) acc.ink_top_pt else primary.cap_height * p_scale;
        const ink_descent = if (acc.ink_bottom_pt > 0) acc.ink_bottom_pt else 0;
        std.debug.assert(ink_ascent >= 0);
        std.debug.assert(ink_descent >= 0);
        return .{
            .width = acc.pen_pt,
            .ascent = primary.ascent * p_scale,
            .descent = primary.descent * p_scale,
            .ink_ascent = ink_ascent,
            .ink_descent = ink_descent,
            .runs = self.run_buffer.items,
        };
    }

    // Whitespace-only and unshapeable lines keep real line metrics so stacked
    // rows do not collapse; cap height stands in for the missing black box.
    fn whitespace_layout(e: FontEntry, font_size: f32) ts.LineLayout {
        std.debug.assert(font_size > 0);
        std.debug.assert(e.units_per_em > 0);
        const scale = font_size / e.units_per_em;
        return .{
            .width = 0,
            .ascent = e.ascent * scale,
            .descent = e.descent * scale,
            .ink_ascent = e.cap_height * scale,
            .ink_descent = 0,
            .runs = &.{},
        };
    }

    fn empty_layout() ts.LineLayout {
        return .{
            .width = 0,
            .ascent = 0,
            .descent = 0,
            .ink_ascent = 0,
            .ink_descent = 0,
            .runs = &.{},
        };
    }

    fn sized_face(self: *Self, params: ts.RenderGlyphParams) ?*ft.Face {
        std.debug.assert(params.font_size > 0);
        std.debug.assert(params.scale_factor > 0);
        if (!self.loaded or params.font_id >= self.fonts.items.len) return null;
        const e = &self.fonts.items[params.font_id];
        const px = params.font_size * params.scale_factor;
        if (e.strike_ppem > 0) return e.ft_face; // a bitmap-strike font is fixed; rasterize scales it
        if (e.size_px != px) {
            if (ft.set_pixel_size(e.ft_face, px)) {
                e.size_px = px;
            } else {
                // No scalable outline (color-bitmap font): select its single strike and remember its
                // ppem so the rasterizer can scale the strike bitmap down to the requested size.
                const ppem = ft.select_strike(e.ft_face, 0);
                if (ppem == 0) return null;
                e.strike_ppem = ppem;
            }
        }
        return e.ft_face;
    }

    // How much to shrink a bitmap-strike glyph (native strike ppem -> requested px); 1.0 for scalable.
    fn color_scale(e: *const FontEntry, params: ts.RenderGlyphParams) f32 {
        if (e.strike_ppem <= 0) return 1.0;
        return (params.font_size * params.scale_factor) / e.strike_ppem;
    }

    fn rasterize_glyph_impl(ptr: *anyopaque, params: ts.RenderGlyphParams) ?ts.GlyphBitmap {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const face = self.sized_face(params) orelse return null;
        const slot = ft.load_and_render(face, params.glyph_id) orelse return null;
        const w = slot.bitmap.width;
        const h = slot.bitmap.rows;
        if (w == 0 or h == 0) return null;
        std.debug.assert(@as(u64, w) * @as(u64, h) <= MAX_GLYPH_PIXELS);
        std.debug.assert(slot.bitmap.pitch > 0);
        const src = slot.bitmap.buffer orelse return null;
        const pitch: u32 = @intCast(slot.bitmap.pitch);

        // A color-bitmap glyph (emoji) comes back as premultiplied BGRA at the font's native strike
        // size; box-downscale it to the requested px and repack BGRA -> RGBA for the color atlas.
        if (slot.bitmap.pixel_mode == ft.PIXEL_MODE_BGRA) {
            const scale = color_scale(&self.fonts.items[params.font_id], params);
            const nw: u32 = @max(1, @as(u32, @intFromFloat(@round(@as(f32, @floatFromInt(w)) * scale))));
            const nh: u32 = @max(1, @as(u32, @intFromFloat(@round(@as(f32, @floatFromInt(h)) * scale))));
            self.bitmap_buffer.resize(self.allocator, nw * nh * 4) catch return null;
            const dst = self.bitmap_buffer.items;
            var dy: u32 = 0;
            while (dy < nh) : (dy += 1) {
                const sy0 = (dy * h) / nh;
                const sy1 = @min(h, @max(sy0 + 1, ((dy + 1) * h) / nh));
                var dx: u32 = 0;
                while (dx < nw) : (dx += 1) {
                    const sx0 = (dx * w) / nw;
                    const sx1 = @min(w, @max(sx0 + 1, ((dx + 1) * w) / nw));
                    var r: u32 = 0;
                    var g: u32 = 0;
                    var bl: u32 = 0;
                    var a: u32 = 0;
                    var cnt: u32 = 0;
                    var sy = sy0;
                    while (sy < sy1) : (sy += 1) {
                        var sx = sx0;
                        while (sx < sx1) : (sx += 1) {
                            const s = src[sy * pitch + sx * 4 ..];
                            bl += s[0];
                            g += s[1];
                            r += s[2];
                            a += s[3];
                            cnt += 1;
                        }
                    }
                    if (cnt == 0) cnt = 1;
                    const d = dst[(dy * nw + dx) * 4 ..];
                    d[0] = @intCast(r / cnt); // R <- B (channel-swapped average)
                    d[1] = @intCast(g / cnt);
                    d[2] = @intCast(bl / cnt);
                    d[3] = @intCast(a / cnt);
                }
            }
            return .{ .width = nw, .height = nh, .data = dst, .is_colored = true };
        }

        self.bitmap_buffer.resize(self.allocator, w * h) catch return null;
        const dst = self.bitmap_buffer.items;
        var row: u32 = 0;
        while (row < h) : (row += 1) {
            @memcpy(dst[row * w ..][0..w], src[row * pitch ..][0..w]);
        }
        return .{ .width = w, .height = h, .data = dst, .is_colored = false };
    }

    fn glyph_raster_bounds_impl(
        ptr: *anyopaque,
        params: ts.RenderGlyphParams,
    ) geometry.Bounds(i32) {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const face = self.sized_face(params) orelse return geometry.Bounds(i32).init(0, 0, 0, 0);
        // Render (not just load) so left/top match the rasterized bitmap exactly;
        // metrics-derived rounding can differ by a pixel and make glyphs jitter.
        const slot = ft.load_and_render(face, params.glyph_id) orelse
            return geometry.Bounds(i32).init(0, 0, 0, 0);
        // A color strike bitmap is scaled down at raster time; scale its placement to match.
        if (slot.bitmap.pixel_mode == ft.PIXEL_MODE_BGRA) {
            const scale = color_scale(&self.fonts.items[params.font_id], params);
            const rnd = struct {
                fn f(v: f32) i32 {
                    return @intFromFloat(@round(v));
                }
            }.f;
            return geometry.Bounds(i32).init(
                rnd(@as(f32, @floatFromInt(slot.bitmap_left)) * scale),
                rnd(-@as(f32, @floatFromInt(slot.bitmap_top)) * scale),
                rnd(@as(f32, @floatFromInt(slot.bitmap.width)) * scale),
                rnd(@as(f32, @floatFromInt(slot.bitmap.rows)) * scale),
            );
        }
        return geometry.Bounds(i32).init(
            slot.bitmap_left,
            -slot.bitmap_top,
            @intCast(slot.bitmap.width),
            @intCast(slot.bitmap.rows),
        );
    }
};
