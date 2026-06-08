const std = @import("std");
const types = @import("../window/types.zig");
const builder = @import("../render/builder.zig");
const RenderError = builder.RenderError;
const label = @import("../render/label.zig");
const primitives = @import("../primitives.zig");
const custom_paint = @import("../window/paint.zig");
const callbacks = @import("../callbacks.zig");

pub const RenderBuilder = builder.RenderBuilder;
pub const Theme = types.Theme;
pub const Quad = primitives.Quad;
pub const SizeF = @import("../geometry.zig").SizeF;

pub const MAX_TABS = 16;

// A hitbox's ctx is read on a later input event, so each payload must outlive
// the render call. The caller owns this slab so two tab strips never clobber
// each other and rendering stays reentrant. Bounded by MAX_TABS (asserted).
const Shim = struct { on_select: ?callbacks.SelectFn, ctx: ?*anyopaque, index: usize };

pub const TabsState = struct {
    shims: [MAX_TABS]Shim = undefined,
    shim_len: usize = 0,
};

pub const TabsOptions = struct {
    tabs: []const []const u8,
    selected: usize = 0,
    height: f32 = 36,
    theme: *const Theme,
    paint: ?*custom_paint.PaintContext = null,
    on_select: ?callbacks.SelectFn = null,
    ctx: ?*anyopaque = null,
};

fn shim_click(ctx: ?*anyopaque) void {
    const s: *const Shim = @ptrCast(@alignCast(ctx orelse return));
    if (s.on_select) |cb| cb(s.ctx, s.index);
}

pub fn render(
    b: *RenderBuilder,
    x: f32,
    y: f32,
    w: f32,
    state: *TabsState,
    opts: TabsOptions,
) RenderError!SizeF {
    const theme = opts.theme;
    const h = opts.height;
    std.debug.assert(w > 0);
    std.debug.assert(opts.tabs.len > 0);
    std.debug.assert(opts.tabs.len <= MAX_TABS);

    var track = Quad.init(x, y, w, h);
    _ = track.set_background(theme.muted).set_corner_radius(theme.radius);
    try b.append_quad(track);

    state.shim_len = 0;
    const n: f32 = @floatFromInt(opts.tabs.len);
    const pad: f32 = 4;
    const seg = (w - pad * 2) / n;
    for (opts.tabs, 0..) |tab, i| {
        const tx = x + pad + @as(f32, @floatFromInt(i)) * seg;
        const active = i == opts.selected;
        if (opts.paint) |p| {
            std.debug.assert(state.shim_len < state.shims.len);
            state.shims[state.shim_len] = .{
                .on_select = opts.on_select,
                .ctx = opts.ctx,
                .index = i,
            };
            try p.add_hitbox(.{
                .x = tx,
                .y = y,
                .w = seg,
                .h = h,
                .on_click = shim_click,
                .ctx = @ptrCast(&state.shims[state.shim_len]),
            });
            state.shim_len += 1;
        }
        if (active) {
            var pill = Quad.init(tx, y + pad, seg, h - pad * 2);
            _ = pill.set_background(theme.background).set_corner_radius(theme.radius - 2);
            try b.append_quad(pill);
        }
        const sty = label.Style{
            .font_size = theme.font_size,
            .weight = if (active) .semi_bold else .medium,
            .color = if (active) theme.foreground else theme.muted_foreground,
        };
        const m = label.measure(b, tab, sty);
        _ = try label.render(b, tx + (seg - m.width) / 2, label.centered_top(y, h, m), tab, sty);
    }
    return SizeF.init(w, h);
}
