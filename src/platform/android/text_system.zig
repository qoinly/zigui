// Android text via android.graphics (the platform text stack, the way macOS uses
// CoreText and Linux uses FreeType). NDK apps cannot dlopen the private system
// freetype/harfbuzz, so glyphs are rasterized through Paint + Canvas into an
// ALPHA_8 Bitmap, whose coverage bytes are read back with libjnigraphics and
// packed into the shared Vulkan atlas. The glyph id is the Unicode codepoint:
// each codepoint is measured and drawn on its own, so there is no cross-cluster
// shaping (ligatures/kerning) - enough for Latin UI text.
//
// All JNI runs on the NativeActivity main thread (where the paint loop lives), so
// no thread attach is needed. Class/instance handles are global refs cached at
// init; per-glyph String/Bitmap/Canvas are local refs freed immediately.

const std = @import("std");
const ts = @import("../../text_system.zig");
const geometry = @import("../../geometry.zig");
const jni = @import("jni.zig");

const Allocator = std.mem.Allocator;
const MAX_GLYPHS = 4096; // a longer line is truncated, not crashed
const MAX_GLYPH_PIXELS = 1024 * 1024; // one rasterized glyph's pixel budget
const WHITE: jni.jint = @bitCast(@as(u32, 0xFFFFFFFF)); // ALPHA_8 keeps only the alpha

const Refs = struct {
    bitmap_cls: jni.jobject,
    canvas_cls: jni.jobject,
    paint: jni.jobject, // a reused Paint (text size set per call)
    rect: jni.jobject, // a reused Rect for getTextBounds
    fm: jni.jobject, // a reused Paint.FontMetrics
    alpha8: jni.jobject, // Bitmap.Config.ALPHA_8
    set_size: jni.jmethodID,
    measure: jni.jmethodID,
    get_bounds: jni.jmethodID,
    get_fm: jni.jmethodID,
    canvas_ctor: jni.jmethodID,
    draw_text: jni.jmethodID,
    create_bitmap: jni.jmethodID,
    r_left: jni.jfieldID,
    r_top: jni.jfieldID,
    r_right: jni.jfieldID,
    r_bottom: jni.jfieldID,
    fm_ascent: jni.jfieldID,
    fm_descent: jni.jfieldID,
    fm_leading: jni.jfieldID,
};

pub const AndroidTextSystem = struct {
    allocator: Allocator,
    loaded: bool = false,
    env: jni.JNIEnv = undefined,
    refs: Refs = undefined,
    run_buffer: std.ArrayListUnmanaged(ts.ShapedRun) = .empty,
    glyph_buffer: std.ArrayListUnmanaged(ts.ShapedGlyph) = .empty,
    bitmap_buffer: std.ArrayListUnmanaged(u8) = .empty,

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        var self = Self{ .allocator = allocator };
        self.setup() catch return self; // loaded stays false; glyphs degrade to none
        return self;
    }

    fn setup(self: *Self) !void {
        const e = jni.thread_env() orelse return error.NoEnv;
        const t = e.*;

        const paint_cls = t.FindClass(e, "android/graphics/Paint") orelse return error.Jni;
        const canvas_cls = t.FindClass(e, "android/graphics/Canvas") orelse return error.Jni;
        const bitmap_cls = t.FindClass(e, "android/graphics/Bitmap") orelse return error.Jni;
        const config_cls = t.FindClass(e, "android/graphics/Bitmap$Config") orelse return error.Jni;
        const rect_cls = t.FindClass(e, "android/graphics/Rect") orelse return error.Jni;
        const fm_cls = t.FindClass(e, "android/graphics/Paint$FontMetrics") orelse return error.Jni;

        const paint_ctor = t.GetMethodID(e, paint_cls, "<init>", "()V") orelse return error.Jni;
        const set_aa = t.GetMethodID(e, paint_cls, "setAntiAlias", "(Z)V") orelse return error.Jni;
        const set_color = t.GetMethodID(e, paint_cls, "setColor", "(I)V") orelse return error.Jni;
        const rect_ctor = t.GetMethodID(e, rect_cls, "<init>", "()V") orelse return error.Jni;
        const fm_ctor = t.GetMethodID(e, fm_cls, "<init>", "()V") orelse return error.Jni;
        const a8_fid = t.GetStaticFieldID(
            e,
            config_cls,
            "ALPHA_8",
            "Landroid/graphics/Bitmap$Config;",
        ) orelse return error.Jni;
        const a8_local = t.GetStaticObjectField(e, config_cls, a8_fid) orelse return error.Jni;

        // The Paint is configured once: anti-aliased, opaque white so ALPHA_8
        // coverage is the glyph's own alpha.
        const paint_local = t.NewObjectA(e, paint_cls, paint_ctor, null) orelse return error.Jni;
        var on = [_]jni.jvalue{.{ .z = 1 }};
        t.CallVoidMethodA(e, paint_local, set_aa, &on);
        var col = [_]jni.jvalue{.{ .i = WHITE }};
        t.CallVoidMethodA(e, paint_local, set_color, &col);
        const rect_local = t.NewObjectA(e, rect_cls, rect_ctor, null) orelse return error.Jni;
        const fm_local = t.NewObjectA(e, fm_cls, fm_ctor, null) orelse return error.Jni;

        self.refs = .{
            .bitmap_cls = t.NewGlobalRef(e, bitmap_cls) orelse return error.Jni,
            .canvas_cls = t.NewGlobalRef(e, canvas_cls) orelse return error.Jni,
            .paint = t.NewGlobalRef(e, paint_local) orelse return error.Jni,
            .rect = t.NewGlobalRef(e, rect_local) orelse return error.Jni,
            .fm = t.NewGlobalRef(e, fm_local) orelse return error.Jni,
            .alpha8 = t.NewGlobalRef(e, a8_local) orelse return error.Jni,
            .set_size = t.GetMethodID(e, paint_cls, "setTextSize", "(F)V") orelse return error.Jni,
            .measure = t.GetMethodID(e, paint_cls, "measureText", "(Ljava/lang/String;)F") orelse
                return error.Jni,
            .get_bounds = t.GetMethodID(
                e,
                paint_cls,
                "getTextBounds",
                "(Ljava/lang/String;IILandroid/graphics/Rect;)V",
            ) orelse return error.Jni,
            .get_fm = t.GetMethodID(
                e,
                paint_cls,
                "getFontMetrics",
                "(Landroid/graphics/Paint$FontMetrics;)F",
            ) orelse return error.Jni,
            .canvas_ctor = t.GetMethodID(
                e,
                canvas_cls,
                "<init>",
                "(Landroid/graphics/Bitmap;)V",
            ) orelse return error.Jni,
            .draw_text = t.GetMethodID(
                e,
                canvas_cls,
                "drawText",
                "(Ljava/lang/String;FFLandroid/graphics/Paint;)V",
            ) orelse return error.Jni,
            .create_bitmap = t.GetStaticMethodID(
                e,
                bitmap_cls,
                "createBitmap",
                "(IILandroid/graphics/Bitmap$Config;)Landroid/graphics/Bitmap;",
            ) orelse return error.Jni,
            .r_left = t.GetFieldID(e, rect_cls, "left", "I") orelse return error.Jni,
            .r_top = t.GetFieldID(e, rect_cls, "top", "I") orelse return error.Jni,
            .r_right = t.GetFieldID(e, rect_cls, "right", "I") orelse return error.Jni,
            .r_bottom = t.GetFieldID(e, rect_cls, "bottom", "I") orelse return error.Jni,
            .fm_ascent = t.GetFieldID(e, fm_cls, "ascent", "F") orelse return error.Jni,
            .fm_descent = t.GetFieldID(e, fm_cls, "descent", "F") orelse return error.Jni,
            .fm_leading = t.GetFieldID(e, fm_cls, "leading", "F") orelse return error.Jni,
        };
        self.env = e;
        self.loaded = true;
    }

    pub fn deinit(self: *Self) void {
        if (self.loaded) {
            const t = self.env.*;
            t.DeleteGlobalRef(self.env, self.refs.bitmap_cls);
            t.DeleteGlobalRef(self.env, self.refs.canvas_cls);
            t.DeleteGlobalRef(self.env, self.refs.paint);
            t.DeleteGlobalRef(self.env, self.refs.rect);
            t.DeleteGlobalRef(self.env, self.refs.fm);
            t.DeleteGlobalRef(self.env, self.refs.alpha8);
        }
        self.run_buffer.deinit(self.allocator);
        self.glyph_buffer.deinit(self.allocator);
        self.bitmap_buffer.deinit(self.allocator);
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

    // One system font; family/weight (Typeface) is not selected here.
    fn font_id_impl(ptr: *anyopaque, family: []const u8, weight: ts.FontWeight) ts.FontId {
        _ = ptr;
        _ = family;
        _ = weight;
        return 0;
    }

    fn set_text_size(self: *Self, px: f32) void {
        std.debug.assert(px > 0);
        var a = [_]jni.jvalue{.{ .f = px }};
        self.env.*.CallVoidMethodA(self.env, self.refs.paint, self.refs.set_size, &a);
    }

    // Builds a Java String for one codepoint (standard UTF-8 == JNI modified UTF-8
    // for the BMP, which is the supported range). Caller frees the local ref.
    fn jstring(self: *Self, cp: u21) ?jni.jobject {
        var buf: [8]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch return null;
        buf[n] = 0;
        return self.env.*.NewStringUTF(self.env, @ptrCast(&buf));
    }

    // getTextBounds(str) -> the glyph ink box {left, top (negative above baseline),
    // right, bottom} at the Paint's current text size.
    fn text_bounds(self: *Self, str: jni.jobject) [4]i32 {
        const e = self.env;
        const t = e.*;
        var args = [_]jni.jvalue{
            .{ .l = str },
            .{ .i = 0 },
            .{ .i = 1 },
            .{ .l = self.refs.rect },
        };
        t.CallVoidMethodA(e, self.refs.paint, self.refs.get_bounds, &args);
        return .{
            t.GetIntField(e, self.refs.rect, self.refs.r_left),
            t.GetIntField(e, self.refs.rect, self.refs.r_top),
            t.GetIntField(e, self.refs.rect, self.refs.r_right),
            t.GetIntField(e, self.refs.rect, self.refs.r_bottom),
        };
    }

    fn font_metrics_impl(ptr: *anyopaque, font_id: ts.FontId, font_size: f32) ts.FontMetrics {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = font_id;
        std.debug.assert(font_size > 0);
        if (!self.loaded) return std.mem.zeroes(ts.FontMetrics);
        const m = self.read_metrics(font_size);
        return .{
            .units_per_em = 1000, // metrics are already in points; not divided downstream
            .ascent = m.ascent,
            .descent = m.descent,
            .line_gap = m.line_gap,
            .cap_height = m.ascent * 0.7, // unused by the kit; a plausible stand-in
            .x_height = m.ascent * 0.5,
        };
    }

    const Metrics = struct { ascent: f32, descent: f32, line_gap: f32 };

    // Paint.FontMetrics.ascent is negative (above baseline); flip it to the
    // positive-up convention the kit expects.
    fn read_metrics(self: *Self, font_size: f32) Metrics {
        const e = self.env;
        const t = e.*;
        self.set_text_size(font_size);
        var a = [_]jni.jvalue{.{ .l = self.refs.fm }};
        _ = t.CallFloatMethodA(e, self.refs.paint, self.refs.get_fm, &a);
        return .{
            .ascent = -t.GetFloatField(e, self.refs.fm, self.refs.fm_ascent),
            .descent = t.GetFloatField(e, self.refs.fm, self.refs.fm_descent),
            .line_gap = t.GetFloatField(e, self.refs.fm, self.refs.fm_leading),
        };
    }

    fn layout_line_impl(
        ptr: *anyopaque,
        text: []const u8,
        font_size: f32,
        font_id: ts.FontId,
    ) ts.LineLayout {
        const self: *Self = @ptrCast(@alignCast(ptr));
        std.debug.assert(font_size > 0);
        if (!self.loaded) return empty_layout();
        const m = self.read_metrics(font_size); // also sets the text size for measure/bounds
        const e = self.env;
        const t = e.*;

        self.glyph_buffer.clearRetainingCapacity();
        self.run_buffer.clearRetainingCapacity();
        var pen: f32 = 0;
        var ink_top: f32 = 0; // points above baseline (positive)
        var ink_bottom: f32 = 0;
        var it = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
        while (it.nextCodepoint()) |cp| {
            if (self.glyph_buffer.items.len >= MAX_GLYPHS) break;
            const seq_len = std.unicode.utf8CodepointSequenceLength(cp) catch 1;
            const byte_index = it.i - seq_len; // it.i already moved past this codepoint
            const str = self.jstring(cp) orelse continue;
            defer t.DeleteLocalRef(e, str);
            var ma = [_]jni.jvalue{.{ .l = str }};
            const advance = t.CallFloatMethodA(e, self.refs.paint, self.refs.measure, &ma);
            const b = self.text_bounds(str);
            self.glyph_buffer.append(self.allocator, .{
                .id = cp,
                .position = .{ .x = pen, .y = 0 },
                .index = byte_index,
                .is_emoji = false,
            }) catch break;
            pen += advance;
            ink_top = @max(ink_top, @as(f32, @floatFromInt(-b[1])));
            ink_bottom = @max(ink_bottom, @as(f32, @floatFromInt(b[3])));
        }
        self.run_buffer.append(self.allocator, .{
            .font_id = font_id,
            .glyphs = self.glyph_buffer.items,
        }) catch {};

        // Cap height stands in when nothing inked (whitespace), so stacked rows
        // keep a real height instead of collapsing.
        const ink_ascent = if (ink_top > 0) ink_top else m.ascent * 0.7;
        std.debug.assert(ink_ascent >= 0);
        std.debug.assert(ink_bottom >= 0);
        return .{
            .width = pen,
            .ascent = m.ascent,
            .descent = m.descent,
            .ink_ascent = ink_ascent,
            .ink_descent = ink_bottom,
            .runs = self.run_buffer.items,
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

    fn rasterize_glyph_impl(ptr: *anyopaque, params: ts.RenderGlyphParams) ?ts.GlyphBitmap {
        const self: *Self = @ptrCast(@alignCast(ptr));
        if (!self.loaded) return null;
        std.debug.assert(params.font_size > 0);
        std.debug.assert(params.scale_factor > 0);
        const e = self.env;
        const t = e.*;
        const px = params.font_size * params.scale_factor;
        self.set_text_size(px);

        const str = self.jstring(@intCast(params.glyph_id)) orelse return null;
        defer t.DeleteLocalRef(e, str);
        const b = self.text_bounds(str);
        const w: u32 = @intCast(@max(0, b[2] - b[0]));
        const h: u32 = @intCast(@max(0, b[3] - b[1]));
        if (w == 0 or h == 0) return null; // whitespace has no ink
        std.debug.assert(@as(u64, w) * @as(u64, h) <= MAX_GLYPH_PIXELS);

        var cb = [_]jni.jvalue{
            .{ .i = b[2] - b[0] },
            .{ .i = b[3] - b[1] },
            .{ .l = self.refs.alpha8 },
        };
        const bmp = t.CallStaticObjectMethodA(
            e,
            self.refs.bitmap_cls,
            self.refs.create_bitmap,
            &cb,
        ) orelse return null;
        defer t.DeleteLocalRef(e, bmp);
        var cc = [_]jni.jvalue{.{ .l = bmp }};
        const canvas = t.NewObjectA(e, self.refs.canvas_cls, self.refs.canvas_ctor, &cc) orelse
            return null;
        defer t.DeleteLocalRef(e, canvas);
        // Shift the glyph's ink box to the bitmap origin (its left/top are the
        // bearings relative to the pen on the baseline).
        var dt = [_]jni.jvalue{
            .{ .l = str },
            .{ .f = @floatFromInt(-b[0]) },
            .{ .f = @floatFromInt(-b[1]) },
            .{ .l = self.refs.paint },
        };
        t.CallVoidMethodA(e, canvas, self.refs.draw_text, &dt);

        var info: jni.AndroidBitmapInfo = .{};
        if (jni.AndroidBitmap_getInfo(e, bmp, &info) != 0) return null;
        std.debug.assert(info.format == jni.ANDROID_BITMAP_FORMAT_A_8);
        var pixels: ?*anyopaque = null;
        if (jni.AndroidBitmap_lockPixels(e, bmp, &pixels) != 0) return null;
        const src: [*]const u8 = @ptrCast(pixels orelse {
            _ = jni.AndroidBitmap_unlockPixels(e, bmp);
            return null;
        });
        std.debug.assert(info.stride >= w); // the per-row copy reads `w` of `stride`
        self.bitmap_buffer.resize(self.allocator, w * h) catch {
            _ = jni.AndroidBitmap_unlockPixels(e, bmp);
            return null;
        };
        const dst = self.bitmap_buffer.items;
        var row: u32 = 0;
        while (row < h) : (row += 1) {
            @memcpy(dst[row * w ..][0..w], src[row * info.stride ..][0..w]);
        }
        _ = jni.AndroidBitmap_unlockPixels(e, bmp);
        return .{ .width = w, .height = h, .data = dst, .is_colored = false };
    }

    fn glyph_raster_bounds_impl(
        ptr: *anyopaque,
        params: ts.RenderGlyphParams,
    ) geometry.Bounds(i32) {
        const self: *Self = @ptrCast(@alignCast(ptr));
        if (!self.loaded) return geometry.Bounds(i32).init(0, 0, 0, 0);
        const px = params.font_size * params.scale_factor;
        self.set_text_size(px);
        const str = self.jstring(@intCast(params.glyph_id)) orelse
            return geometry.Bounds(i32).init(0, 0, 0, 0);
        defer self.env.*.DeleteLocalRef(self.env, str);
        const b = self.text_bounds(str);
        // top is already negative-above-baseline (the y-down sprite origin).
        return geometry.Bounds(i32).init(b[0], b[1], b[2] - b[0], b[3] - b[1]);
    }
};
