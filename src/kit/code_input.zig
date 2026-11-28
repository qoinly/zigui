// A short code typed into a row of boxes, one character per box (a pairing code, a one-time
// code). The boxes are drawn here; typing comes from the key queue like the textarea's, so a
// hardware keyboard, the Android soft keyboard (delta mode) and Cmd/Ctrl+V all fill it the same.
// Characters go through `accept`, which may also rewrite them (case, look-alikes) or drop them,
// so a pasted "abc-123 " lands as "ABC123".
const std = @import("std");
const builtin = @import("builtin");
const types = @import("../window/types.zig");
const builder = @import("../render/builder.zig");
const RenderError = builder.RenderError;
const label = @import("../render/label.zig");
const primitives = @import("../primitives.zig");
const custom_paint = @import("../window/paint.zig");
const custom_shell = @import("../custom_shell.zig");
const callbacks = @import("../callbacks.zig");

pub const RenderBuilder = builder.RenderBuilder;
pub const Theme = types.Theme;
pub const Quad = primitives.Quad;
pub const SizeF = @import("../geometry.zig").SizeF;

const touch_input = builtin.abi.isAndroid();

pub const MAX_LEN = 16;

pub const CodeInputState = struct {
    buf: [MAX_LEN]u8 = undefined,
    len: usize = 0,
    focused: bool = false,
    // Stashed each frame for the click and blur thunks, which run between frames.
    on_focus: ?callbacks.FocusFn = null,
    focus_ctx: ?*anyopaque = null,

    pub fn slice(self: *const CodeInputState) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn clear(self: *CodeInputState) void {
        self.len = 0;
    }

    // Replace the contents with `text` read through `accept`, up to `length` characters.
    pub fn set(self: *CodeInputState, text: []const u8, length: usize, accept: AcceptFn) void {
        self.len = 0;
        self.append(text, length, accept);
    }

    fn append(self: *CodeInputState, text: []const u8, length: usize, accept: AcceptFn) void {
        const cap = @min(length, MAX_LEN);
        for (text) |ch| {
            if (self.len >= cap) break;
            if (accept(ch)) |c| {
                self.buf[self.len] = c;
                self.len += 1;
            }
        }
    }

    // Fill from the clipboard (a Paste button). Returns whether anything usable was there.
    pub fn paste(self: *CodeInputState, length: usize, accept: AcceptFn) bool {
        var scratch: [256]u8 = undefined;
        const raw = custom_shell.pasteboard_read_into(&scratch);
        var probe: CodeInputState = .{};
        probe.append(raw, length, accept);
        if (probe.len == 0) return false;
        self.buf = probe.buf;
        self.len = probe.len;
        return true;
    }
};

// Maps a typed byte to the byte stored, or null to drop it.
pub const AcceptFn = *const fn (u8) ?u8;

// Letters and digits, upper-cased.
pub fn alnum_upper(ch: u8) ?u8 {
    if (!std.ascii.isAlphanumeric(ch)) return null;
    return std.ascii.toUpper(ch);
}

pub const CodeSize = enum { default, lg };

pub const CodeInputOptions = struct {
    state: *CodeInputState,
    theme: *const Theme,
    paint: *custom_paint.PaintContext,
    length: usize = 6,
    // A dash between groups of this many boxes (0 = none): 3 reads ABC-123.
    group: usize = 3,
    accept: AcceptFn = alnum_upper,
    size: CodeSize = .default,
    center: bool = false,
    invalid: bool = false,
    font_family: ?[]const u8 = null,
    // Space under the boxes the soft keyboard should also leave visible (the button that sends it).
    reveal_below: f32 = 0,
    on_focus: ?callbacks.FocusFn = null,
    // Fires after a key changed the contents, and on Enter.
    on_change: ?callbacks.ClickFn = null,
    on_submit: ?callbacks.ClickFn = null,
    ctx: ?*anyopaque = null,
};

const Metrics = struct { w: f32, h: f32, gap: f32, dash: f32, font: f32 };

fn metrics(size: CodeSize) Metrics {
    return switch (size) {
        .default => .{ .w = 36, .h = 44, .gap = 6, .dash = 18, .font = 20 },
        .lg => .{ .w = 44, .h = 52, .gap = 8, .dash = 22, .font = 24 },
    };
}

pub fn height_for(size: CodeSize) f32 {
    return metrics(size).h;
}

// The row's natural width, so a caller can size or centre it.
pub fn width_for(size: CodeSize, length: usize, group: usize) f32 {
    const m = metrics(size);
    const n: f32 = @floatFromInt(length);
    const dashes: f32 = @floatFromInt(dash_count(length, group));
    return n * m.w + (n - 1 - dashes) * m.gap + dashes * m.dash;
}

fn dash_count(length: usize, group: usize) usize {
    if (group == 0 or length == 0) return 0;
    return (length - 1) / group;
}

fn focus_thunk(ctx: ?*anyopaque) void {
    const st: *CodeInputState = @ptrCast(@alignCast(ctx.?));
    st.focused = true;
    if (st.on_focus) |f| f(st.focus_ctx);
}

fn blur_thunk(ctx: *anyopaque) void {
    const st: *CodeInputState = @ptrCast(@alignCast(ctx));
    st.focused = false;
}

// Returns true when the contents changed.
fn drain_keys(o: CodeInputOptions) bool {
    const st = o.state;
    var changed = false;
    for (o.paint.keys()) |ev| switch (ev.code) {
        .char => {
            if (ev.mods.cmd and !ev.mods.ctrl and !ev.mods.alt and (ev.ch == 'v' or ev.ch == 'V')) {
                if (st.paste(o.length, o.accept)) changed = true;
                continue;
            }
            // The Android keyboard's Enter arrives as a typed newline.
            if (ev.ch == '\n' or ev.ch == '\r') {
                if (o.on_submit) |f| f(o.ctx);
                continue;
            }
            if (ev.mods.cmd or ev.mods.ctrl or ev.ch == 0 or ev.ch > 127) continue;
            const before = st.len;
            st.append(&.{@intCast(ev.ch)}, o.length, o.accept);
            if (st.len != before) changed = true;
        },
        .backspace => if (st.len > 0) {
            // Cmd/Ctrl+Backspace clears the whole code, as it would a word.
            st.len = if (ev.mods.cmd) 0 else st.len - 1;
            changed = true;
        },
        .enter => if (o.on_submit) |f| f(o.ctx),
        .escape => st.focused = false,
        else => {},
    };
    return changed;
}

pub fn render(b: *RenderBuilder, x: f32, y: f32, w: f32, o: CodeInputOptions) RenderError!SizeF {
    std.debug.assert(o.length > 0 and o.length <= MAX_LEN);
    const st = o.state;
    const theme = o.theme;
    const p = o.paint;
    var m = metrics(o.size);
    // Narrower than the row's natural width (a side pane on a fold): slim the boxes and the
    // space between them to fit, keeping their height and the text size.
    const natural = width_for(o.size, o.length, o.group);
    if (w > 0 and natural > w) {
        const k = w / natural;
        m.w *= k;
        m.gap *= k;
        m.dash *= k;
    }
    st.on_focus = o.on_focus;
    st.focus_ctx = o.ctx;
    if (st.len > o.length) st.len = o.length;

    if (st.focused) {
        p.text_focus_ctx = st;
        p.text_focus_blur = blur_thunk;
        if (!p.block_keys and drain_keys(o)) if (o.on_change) |f| f(o.ctx);
    }

    const total = @min(natural, if (w > 0) w else natural);
    const x0 = if (o.center) x + @max(0, (w - total) / 2) else x;
    try p.add_hitbox(.{ .x = x0, .y = y, .w = total, .h = m.h, .on_click = focus_thunk, .ctx = st });

    const font = o.font_family orelse theme.font_family;
    const sty = label.Style{ .font_size = m.font, .weight = .medium, .color = theme.foreground, .font_family = font };
    const active = if (st.len < o.length) st.len else o.length - 1;
    var cx = x0;
    for (0..o.length) |i| {
        if (i > 0 and o.group > 0 and i % o.group == 0) {
            var dash = Quad.init(cx + (m.dash - 8) / 2, y + m.h / 2 - 1, 8, 2);
            _ = dash.set_background(theme.muted_foreground).set_corner_radius(1);
            try b.append_quad(dash);
            cx += m.dash;
        } else if (i > 0) cx += m.gap;

        const lit = st.focused and i == active;
        const border = if (o.invalid) theme.destructive else if (lit) theme.ring else theme.border;
        var box = Quad.init(cx, y, m.w, m.h);
        _ = box.set_background(theme.background)
            .set_corner_radius(theme.radius - 2)
            .set_border_color(border)
            .set_border_width(if (lit) 2 else 1);
        try b.append_quad(box);

        if (i < st.len) {
            const ch = st.buf[i .. i + 1];
            const tm = label.measure(b, ch, sty);
            _ = try label.render(b, cx + (m.w - tm.width) / 2, label.centered_top(y, m.h, tm), ch, sty);
        } else if (lit) {
            var bar = Quad.init(cx + m.w / 2 - 1, y + (m.h - m.font) / 2, 2, m.font);
            _ = bar.set_background(theme.ring).set_corner_radius(1);
            try b.append_quad(bar);
        }
        cx += m.w;
    }

    if (touch_input and st.focused) {
        p.show_text_delta(x0, y, total, m.h + o.reveal_below);
    }
    return SizeF.init(w, m.h);
}
