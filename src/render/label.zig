const std = @import("std");
const color = @import("../color.zig");
const text_system = @import("../text_system.zig");
const builder = @import("builder.zig");

const RenderBuilder = builder.RenderBuilder;
const RenderError = builder.RenderError;
const FontWeight = text_system.FontWeight;

pub const Style = struct {
    font_size: f32 = 14,
    weight: FontWeight = .normal,
    color: color.Rgba = .{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 },
    font_family: []const u8 = ".AppleSystemUIFont",
};

pub fn render(
    b: *RenderBuilder,
    x: f32,
    y: f32,
    text: []const u8,
    style: Style,
) RenderError!f32 {
    if (text.len == 0) return 0;
    const fid = b.text_system.get_font_id(style.font_family, style.weight);
    const line = b.text_system.shape_text(text, style.font_size, fid);
    try b.text_system.sprites_for_line(
        line,
        x,
        y + line.ascent,
        style.color,
        b.scale_factor,
        b.sprites,
        b.allocator,
    );
    return line.width;
}

fn is_cont(byte: u8) bool {
    return (byte & 0xC0) == 0x80;
}

// For single-line cells that must not bleed past their column width.
pub fn render_clamped(
    b: *RenderBuilder,
    x: f32,
    y: f32,
    text: []const u8,
    max_w: f32,
    style: Style,
) RenderError!f32 {
    std.debug.assert(style.font_size > 0);
    if (text.len == 0 or max_w <= 0) return 0;
    if (measure(b, text, style).width <= max_w) return render(b, x, y, text, style);
    const ell = "\u{2026}";
    const ew = measure(b, ell, style).width;
    std.debug.assert(ew >= 0);
    if (max_w <= ew) return render(b, x, y, ell, style);
    const budget = max_w - ew;
    var lo: usize = 0;
    var hi: usize = text.len;
    var iters: u32 = 0;
    while (lo < hi) {
        std.debug.assert(iters < 64); // binary search over byte length: ~log2(len)
        iters += 1;
        var mid = lo + (hi - lo + 1) / 2;
        while (mid > lo and mid < text.len and is_cont(text[mid])) mid -= 1;
        if (mid == lo) break;
        if (measure(b, text[0..mid], style).width <= budget) lo = mid else hi = mid - 1;
    }
    const pw = try render(b, x, y, text[0..lo], style);
    _ = try render(b, x + pw, y, ell, style);
    return pw + ew;
}

// ink_ascent / ink_descent: tight glyph-ink extent above / below the baseline
// for THIS exact string. Center on these, not the font line box, whose empty
// descent/leading pushes short text off-center.
pub const Size = struct {
    width: f32,
    ascent: f32,
    descent: f32,
    ink_ascent: f32 = 0,
    ink_descent: f32 = 0,
};

// Render-y centering text in [region_y, region_y + region_h]. Centers the cap
// box, not the full ink box: descenders (p/g/y) don't shift it, so sibling
// labels in a row share a baseline regardless of which has descenders.
pub fn centered_top(region_y: f32, region_h: f32, m: Size) f32 {
    return region_y + region_h / 2 - m.ascent + m.ink_ascent / 2;
}

pub fn measure(b: *RenderBuilder, text: []const u8, style: Style) Size {
    if (text.len == 0) return .{ .width = 0, .ascent = 0, .descent = 0 };
    const fid = b.text_system.get_font_id(style.font_family, style.weight);
    const line = b.text_system.shape_text(text, style.font_size, fid);
    return .{
        .width = line.width,
        .ascent = line.ascent,
        .descent = line.descent,
        .ink_ascent = line.ink_ascent,
        .ink_descent = line.ink_descent,
    };
}

// A wrap producing more lines than this is a bug, not a layout - assert it.
pub const MAX_WRAP_LINES: u32 = 4096;

pub const Wrapped = struct {
    width: f32,
    height: f32,
    lines: u32,
};

// Min-content width: the widest single space-split word, i.e. the narrowest
// column the text can wrap into without breaking a word. measure_wrapped can't
// report this (it clamps to max_w), so the flex auto-min floor queries it here.
pub fn min_content_width(b: *RenderBuilder, text: []const u8, style: Style) f32 {
    std.debug.assert(style.font_size > 0);
    var widest: f32 = 0;
    var words: u32 = 0;
    var it = std.mem.tokenizeScalar(u8, text, ' ');
    while (it.next()) |word| {
        std.debug.assert(words < MAX_WRAP_LINES);
        words += 1;
        widest = @max(widest, measure(b, word, style).width);
    }
    return widest;
}

// Greedy word-wrap height-for-width, split on ASCII space. A single word wider
// than max_w spills its line (no character breaking).
pub fn measure_wrapped(b: *RenderBuilder, text: []const u8, style: Style, max_w: f32) Wrapped {
    if (text.len == 0) return .{ .width = 0, .height = 0, .lines = 0 };
    std.debug.assert(style.font_size > 0);
    const base = measure(b, text, style);
    const lh = base.ascent + base.descent;
    if (max_w <= 0) return .{ .width = base.width, .height = lh, .lines = 1 };
    const space_w = measure(b, " ", style).width;
    var widest: f32 = 0;
    var line_w: f32 = 0;
    var lines: u32 = 1;
    var first = true;
    var it = std.mem.tokenizeScalar(u8, text, ' ');
    while (it.next()) |word| {
        std.debug.assert(lines < MAX_WRAP_LINES);
        const ww = measure(b, word, style).width;
        if (first) {
            line_w = ww;
            first = false;
        } else if (line_w + space_w + ww > max_w) {
            widest = @max(widest, line_w);
            lines += 1;
            line_w = ww;
        } else {
            line_w += space_w + ww;
        }
    }
    widest = @max(widest, line_w);
    return .{
        .width = @min(widest, max_w),
        .height = lh * @as(f32, @floatFromInt(lines)),
        .lines = lines,
    };
}

pub fn render_wrapped(
    b: *RenderBuilder,
    x: f32,
    y: f32,
    text: []const u8,
    style: Style,
    max_w: f32,
) RenderError!f32 {
    if (text.len == 0) return 0;
    std.debug.assert(style.font_size > 0);
    const base = measure(b, text, style);
    const lh = base.ascent + base.descent;
    if (max_w <= 0) {
        _ = try render(b, x, y, text, style);
        return lh;
    }
    const space_w = measure(b, " ", style).width;
    var line_x: f32 = 0;
    var line_y: f32 = 0;
    var lines: u32 = 1;
    var first = true;
    var it = std.mem.tokenizeScalar(u8, text, ' ');
    while (it.next()) |word| {
        std.debug.assert(lines < MAX_WRAP_LINES);
        const ww = measure(b, word, style).width;
        if (first) {
            _ = try render(b, x, y, word, style);
            line_x = ww;
            first = false;
        } else if (line_x + space_w + ww > max_w) {
            line_y += lh;
            lines += 1;
            _ = try render(b, x, y + line_y, word, style);
            line_x = ww;
        } else {
            _ = try render(b, x + line_x + space_w, y + line_y, word, style);
            line_x += space_w + ww;
        }
    }
    return line_y + lh;
}
