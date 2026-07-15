const std = @import("std");
const types = @import("../window/types.zig");
const builder = @import("../render/builder.zig");
const callbacks = @import("../callbacks.zig");
const RenderError = builder.RenderError;
const label = @import("../render/label.zig");
const icon = @import("../render/icon.zig");
const primitives = @import("../primitives.zig");
const custom_paint = @import("../window/paint.zig");
const tr = @import("theme_resolve.zig");

pub const RenderBuilder = builder.RenderBuilder;
pub const Theme = types.Theme;
pub const Quad = primitives.Quad;
pub const SizeF = @import("../geometry.zig").SizeF;

pub const Size = types.Size;
pub const InputKind = enum { text, number, password };

// Visual shell only: live text editing needs a native NSTextField. The kit
// draws the box and reports gestures; the caller owns the value + reveal state.
pub const InputOptions = struct {
    value: []const u8 = "",
    placeholder: []const u8 = "",
    size: Size = .default, // .sm fits a titlebar/toolbar band; .default is the form field
    kind: InputKind = .text,
    focused: bool = false,
    disabled: bool = false,
    invalid: bool = false,
    reveal: bool = false,
    theme: *const Theme,
    paint: ?*custom_paint.PaintContext = null,
    on_focus: ?callbacks.FocusFn = null,
    on_reveal_toggle: ?callbacks.ToggleFn = null,
    on_increment: ?callbacks.ClickFn = null,
    on_decrement: ?callbacks.ClickFn = null,
    ctx: ?*anyopaque = null,
};

pub fn height_for(size: Size) f32 {
    return switch (size) {
        .sm => 32,
        .lg => 40,
        .default, .icon, .icon_sm => 36,
    };
}
pub const PAD: f32 = 12; // text left inset; the native editor overlay tracks this
const EYE_SLOT: f32 = 30;
const STEP_SLOT: f32 = 20;
const GLYPH_PT: f32 = 15;
const MAX_MASK = 64; // passwords rarely run longer; keeps the stack mask buf small

// Buf is stack-owned so two inputs never share it. U+2022 is 3 bytes, hence
// the * 3 sizing.
fn mask_of(value: []const u8, buf: *[MAX_MASK * 3]u8) []const u8 {
    const dot = "\u{2022}";
    var n = std.unicode.utf8CountCodepoints(value) catch value.len;
    if (n > MAX_MASK) n = MAX_MASK;
    std.debug.assert(n <= MAX_MASK);
    var i: usize = 0;
    while (i < n) : (i += 1) @memcpy(buf[i * 3 .. i * 3 + 3], dot);
    return buf[0 .. n * 3];
}

pub fn render(b: *RenderBuilder, x: f32, y: f32, w: f32, opts: InputOptions) RenderError!SizeF {
    std.debug.assert(w > 0);
    const theme = opts.theme;
    const h = height_for(opts.size);

    const has_eye = opts.kind == .password and opts.on_reveal_toggle != null;
    const has_step = opts.kind == .number and
        (opts.on_increment != null or opts.on_decrement != null);
    const right_slot: f32 = if (has_eye) EYE_SLOT else if (has_step) STEP_SLOT else 0;

    // Box hitbox first; sub-buttons added after so they win in their own
    // sub-rect (hit-test walks newest-first).
    if (opts.paint != null and !opts.disabled) {
        try opts.paint.?.add_hitbox(.{
            .x = x,
            .y = y,
            .w = w,
            .h = h,
            .on_click = opts.on_focus,
            .ctx = opts.ctx,
        });
    }

    var box = Quad.init(x, y, w, h);
    const border = if (opts.invalid)
        theme.destructive
    else if (opts.focused)
        theme.ring
    else
        theme.border;
    const bg = if (opts.disabled) theme.muted else theme.background;
    _ = box.set_background(bg)
        .set_corner_radius(theme.radius - 2)
        .set_border_color(border)
        .set_border_width(if (opts.focused or opts.invalid) 2 else 1);
    try b.append_quad(box);

    const has_val = opts.value.len > 0;
    const fg = if (opts.disabled)
        theme.muted_foreground
    else if (has_val)
        theme.foreground
    else
        theme.muted_foreground;
    // When focused the native editor draws the text; drawing it here too would
    // show the value through the editor.
    if (!opts.focused and (has_val or opts.placeholder.len > 0)) {
        var mask_buf: [MAX_MASK * 3]u8 = undefined;
        const shown = if (!has_val)
            opts.placeholder
        else if (opts.kind == .password and !opts.reveal)
            mask_of(opts.value, &mask_buf)
        else
            opts.value;
        const sty = label.Style{ .font_size = theme.font_size, .weight = .normal, .color = fg };
        const m = label.measure(b, shown, sty);
        const t0 = b.sprites.items.len;
        _ = try label.render(b, x + PAD, label.centered_top(y, h, m), shown, sty);
        // Clip the value so a long one is cut at the field edge instead of bleeding
        // into the next column. A freshly rendered glyph carries the {0,0,0,0}
        // "no-clip" sentinel; intersecting that would collapse to zero (it reads as a
        // real empty rect), so set tclip directly there and intersect only a real one.
        const tclip: [4]f32 = .{ x, y, w - PAD - right_slot, h };
        for (b.sprites.items[t0..]) |*sp| {
            sp.clip_bounds = if (sp.clip_bounds[2] <= 0 or sp.clip_bounds[3] <= 0)
                tclip
            else
                tr.clip_intersect(sp.clip_bounds, tclip);
        }
    }

    if (has_eye) try render_eye(b, &opts, x + w - EYE_SLOT, y, h);
    if (has_step) try render_steppers(b, &opts, x + w - STEP_SLOT, y, h);
    return SizeF.init(w, h);
}

fn render_eye(b: *RenderBuilder, opts: *const InputOptions, sx: f32, y: f32, h: f32) !void {
    const ic: icon.Icon = if (opts.reveal) .eye_slash else .eye;
    const c = opts.theme.muted_foreground;
    _ = try icon.render_icon_centered_xy(b, sx, y, EYE_SLOT, h, ic, .{
        .point_size = GLYPH_PT,
        .color = c,
    });
    if (opts.paint) |p| {
        if (!opts.disabled) try p.add_hitbox(.{
            .x = sx,
            .y = y,
            .w = EYE_SLOT,
            .h = h,
            .on_click = opts.on_reveal_toggle,
            .ctx = opts.ctx,
        });
    }
}

fn render_steppers(b: *RenderBuilder, opts: *const InputOptions, sx: f32, y: f32, h: f32) !void {
    const c = opts.theme.muted_foreground;
    _ = try icon.render_icon_centered_xy(b, sx, y + 4, STEP_SLOT, h / 2 - 4, .chevron_up, .{
        .point_size = GLYPH_PT - 4,
        .color = c,
    });
    _ = try icon.render_icon_centered_xy(b, sx, y + h / 2, STEP_SLOT, h / 2 - 4, .chevron_down, .{
        .point_size = GLYPH_PT - 4,
        .color = c,
    });
    if (opts.paint) |p| {
        if (!opts.disabled) {
            try p.add_hitbox(.{
                .x = sx,
                .y = y,
                .w = STEP_SLOT,
                .h = h / 2,
                .on_click = opts.on_increment,
                .ctx = opts.ctx,
            });
            try p.add_hitbox(.{
                .x = sx,
                .y = y + h / 2,
                .w = STEP_SLOT,
                .h = h / 2,
                .on_click = opts.on_decrement,
                .ctx = opts.ctx,
            });
        }
    }
}
