const std = @import("std");
const builtin = @import("builtin");
const types = @import("../window/types.zig");
const builder = @import("../render/builder.zig");
const RenderError = builder.RenderError;
const label = @import("../render/label.zig");
const primitives = @import("../primitives.zig");

pub const RenderBuilder = builder.RenderBuilder;
pub const Theme = types.Theme;
pub const Quad = primitives.Quad;
pub const SizeF = @import("../geometry.zig").SizeF;
pub const SizeProposal = @import("../geometry.zig").SizeProposal;

// Modifier-key labels per platform: macOS spells them with its glyphs, every
// other OS writes the word. Use these instead of a hardcoded glyph so a combo
// reads right on each platform. The glyphs are the Command, Shift, and Option
// signs, escaped to keep the source ASCII.
const mac = builtin.os.tag == .macos;
pub const command = if (mac) "\u{2318}" else "Ctrl";
pub const shift = if (mac) "\u{21E7}" else "Shift";
pub const option = if (mac) "\u{2325}" else "Alt";

pub const KbdSize = enum { sm, default };

pub const KbdOptions = struct {
    theme: *const Theme,
    size: KbdSize = .default,
};

pub const MAX_KEYS = 8;
const KEY_PAD: f32 = 6;
const KEY_GAP: f32 = 4;
const KEY_RADIUS: f32 = 4;

fn metrics(size: KbdSize, theme: *const Theme) struct { h: f32, fs: f32 } {
    return switch (size) {
        .sm => .{ .h = 18, .fs = theme.font_size - 4 },
        .default => .{ .h = 20, .fs = theme.font_size - 3 },
    };
}

fn key_width(b: *RenderBuilder, text: []const u8, opts: KbdOptions) f32 {
    const m = metrics(opts.size, opts.theme);
    const sty = label.Style{
        .font_size = m.fs,
        .weight = .medium,
        .color = opts.theme.muted_foreground,
    };
    return @max(m.h, label.measure(b, text, sty).width + KEY_PAD * 2);
}

// So a caller can right-align the combo before render.
pub fn measure(
    b: *RenderBuilder,
    proposal: SizeProposal,
    keys: []const []const u8,
    opts: KbdOptions,
) SizeF {
    _ = proposal;
    std.debug.assert(keys.len <= MAX_KEYS);
    var total: f32 = 0;
    for (keys, 0..) |k, i| {
        if (i > 0) total += KEY_GAP;
        total += key_width(b, k, opts);
    }
    return SizeF.init(total, metrics(opts.size, opts.theme).h);
}

pub fn key(
    b: *RenderBuilder,
    x: f32,
    y: f32,
    text: []const u8,
    opts: KbdOptions,
) RenderError!SizeF {
    const theme = opts.theme;
    const m = metrics(opts.size, theme);
    const sty = label.Style{
        .font_size = m.fs,
        .weight = .medium,
        .color = theme.muted_foreground,
    };
    const tm = label.measure(b, text, sty);
    const w = @max(m.h, tm.width + KEY_PAD * 2);

    var chip = Quad.init(x, y, w, m.h);
    _ = chip.set_background(theme.muted)
        .set_corner_radius(KEY_RADIUS)
        .set_border_color(theme.border)
        .set_border_width(1);
    try b.append_quad(chip);
    _ = try label.render(b, x + (w - tm.width) / 2, label.centered_top(y, m.h, tm), text, sty);
    return SizeF.init(w, m.h);
}

// e.g. {"\u{2318}", "K"} for the Command-K combo.
pub fn render(
    b: *RenderBuilder,
    x: f32,
    y: f32,
    keys: []const []const u8,
    opts: KbdOptions,
) RenderError!SizeF {
    std.debug.assert(keys.len <= MAX_KEYS);
    var kx = x;
    for (keys, 0..) |k, i| {
        if (i > 0) kx += KEY_GAP;
        kx += (try key(b, kx, y, k, opts)).width;
    }
    return SizeF.init(kx - x, metrics(opts.size, opts.theme).h);
}

// So a caller can vertically centre a combo against adjacent text.
pub fn height(size: KbdSize, theme: *const Theme) f32 {
    return metrics(size, theme).h;
}
