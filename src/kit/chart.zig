const std = @import("std");
const types = @import("../window/types.zig");
const color = @import("../color.zig");
const builder = @import("../render/builder.zig");
const RenderError = builder.RenderError;
const label = @import("../render/label.zig");
const primitives = @import("../primitives.zig");
const custom_paint = @import("../window/paint.zig");
const tr = @import("theme_resolve.zig");

pub const RenderBuilder = builder.RenderBuilder;
pub const Theme = types.Theme;
pub const Rgba = color.Rgba;
pub const Quad = primitives.Quad;
pub const RingChart = primitives.RingChart;
pub const Polyline = primitives.Polyline;
pub const LineSegment = primitives.LineSegment;

const RingStyle = struct {
    fill: Rgba,
    track: Rgba,
    inner_ratio: f32 = 0.78, // visually thin ring rim
    start_angle_deg: f32 = -90.0, // 12 o'clock
};

// (x, y) = top-left of the bounding square; size = outer diameter. The
// fragment shader does the arc work via SDF; no CPU tessellation.
fn ring_chart(
    b: *RenderBuilder,
    x: f32,
    y: f32,
    size: f32,
    progress: f32,
    style: RingStyle,
) !void {
    std.debug.assert(size > 0);
    std.debug.assert(style.inner_ratio >= 0);
    std.debug.assert(style.inner_ratio <= 1);
    var ring = RingChart.init(
        x,
        y,
        size,
        std.math.clamp(progress, 0.0, 1.0),
        style.inner_ratio,
        style.fill,
        style.track,
    );
    ring.start_angle_deg = style.start_angle_deg;
    try b.append_ring(ring);
}

pub const MAX_POINTS = 64;

const PAD_L: f32 = 36; // left gutter for y value labels
const PAD_B: f32 = 22; // bottom strip for x category labels
const Y_DIVS: usize = 4;
const DOT_R: f32 = 3;
const LINE_TH: f32 = 2;
const BAR_RATIO: f32 = 0.6; // bar width as a fraction of its category slot
const BAR_RADIUS: f32 = 3;
const AXIS_FONT_DELTA: f32 = 4;

fn data_max(values: []const f32) f32 {
    std.debug.assert(values.len <= MAX_POINTS);
    var m: f32 = 0;
    for (values) |v| m = @max(m, v);
    return m;
}

// Round up to the next 1/2/5 x 10^k so the axis labels read cleanly.
fn nice_max(raw: f32) f32 {
    if (!std.math.isFinite(raw) or raw <= 0) return 1; // can't drive an axis

    const mag = std.math.pow(f32, 10, @floor(std.math.log10(raw)));
    const norm = raw / mag;
    const nice: f32 = if (norm <= 1) 1 else if (norm <= 2) 2 else if (norm <= 5) 5 else 10;
    return nice * mag;
}

const Plot = struct { x: f32, y: f32, w: f32, h: f32, minv: f32, maxv: f32, n: usize };

fn val_to_y(p: Plot, v: f32) f32 {
    const span = p.maxv - p.minv;
    const t = if (span > 0) std.math.clamp((v - p.minv) / span, 0, 1) else 0;
    return p.y + p.h * (1 - t);
}

// n = category count (drives the x-axis slots); labels may be shorter.
const PlotCfg = struct {
    theme: *const Theme,
    maxv: f32,
    minv: f32 = 0, // non-zero only when the data dips below zero (negative bars)
    n: usize,
    labels: []const []const u8 = &.{},
    grid: bool = true,
};

fn begin_plot_cfg(b: *RenderBuilder, x: f32, y: f32, w: f32, h: f32, cfg: PlotCfg) !Plot {
    std.debug.assert(w > 0);
    std.debug.assert(h > 0);
    std.debug.assert(cfg.n <= MAX_POINTS);
    std.debug.assert(cfg.labels.len <= MAX_POINTS);
    const has_axis = cfg.labels.len > 0;
    const px = x + PAD_L;
    const pw = w - PAD_L;
    const ph = h - (if (has_axis) PAD_B else 0);
    const plot = Plot{
        .x = px,
        .y = y,
        .w = pw,
        .h = ph,
        .minv = cfg.minv,
        .maxv = cfg.maxv,
        .n = cfg.n,
    };

    if (cfg.grid) {
        const theme = cfg.theme;
        const gsty = label.Style{
            .font_size = theme.font_size - AXIS_FONT_DELTA,
            .weight = .normal,
            .color = theme.muted_foreground,
        };
        var i: usize = 0;
        while (i <= Y_DIVS) : (i += 1) {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(Y_DIVS));
            const gy = y + ph * (1 - t);
            try b.append_line(LineSegment.init(px, gy, px + pw, gy, 1, theme.border));
            // Format the float directly; a float->int cast would trap on a huge
            // or non-finite caller-supplied max.
            var buf: [24]u8 = undefined;
            const gval = cfg.minv + (cfg.maxv - cfg.minv) * t;
            const txt = std.fmt.bufPrint(&buf, "{d:.0}", .{gval}) catch "";
            const m = label.measure(b, txt, gsty);
            _ = try label.render(b, px - 8 - m.width, gy - (m.ascent + m.descent) / 2, txt, gsty);
        }
    }

    if (has_axis) try draw_x_labels(b, plot, cfg.theme, cfg.labels);
    return plot;
}

fn draw_x_labels(
    b: *RenderBuilder,
    p: Plot,
    theme: *const Theme,
    labels: []const []const u8,
) !void {
    const sty = label.Style{
        .font_size = theme.font_size - AXIS_FONT_DELTA,
        .weight = .normal,
        .color = theme.muted_foreground,
    };
    if (p.n == 0) return;
    const slot = p.w / @as(f32, @floatFromInt(p.n));
    // Thin the ticks when cells are too narrow for the widest label: render
    // every stride-th one so they never collide.
    const stride = label_stride(b, p, labels, sty, slot);
    var i: usize = 0;
    while (i < p.n and i < labels.len) : (i += stride) {
        const cx = p.x + slot * (@as(f32, @floatFromInt(i)) + 0.5);
        const m = label.measure(b, labels[i], sty);
        _ = try label.render(b, cx - m.width / 2, p.y + p.h + 6, labels[i], sty);
    }
}

fn label_stride(
    b: *RenderBuilder,
    p: Plot,
    labels: []const []const u8,
    sty: label.Style,
    slot: f32,
) usize {
    if (slot <= 0) return 1;
    const gap: f32 = 8;
    var widest: f32 = 0;
    var k: usize = 0;
    while (k < p.n and k < labels.len) : (k += 1) {
        const w = label.measure(b, labels[k], sty).width;
        if (w > widest) widest = w;
    }
    const need = @min((widest + gap) / slot, @as(f32, @floatFromInt(p.n)));
    return @max(1, @as(usize, @intFromFloat(@ceil(need))));
}

// ---- Line / area (multi-series) ----

pub const MAX_SERIES = 8;

pub const Series = struct {
    name: []const u8 = "",
    color: Rgba,
    values: []const f32,
    point_colors: []const Rgba = &.{}, // optional per-point dot colours
};

pub const Curve = enum { linear, step };

pub const LineChartOptions = struct {
    theme: *const Theme,
    series: []const Series,
    labels: []const []const u8 = &.{},
    curve: Curve = .linear,
    fill: bool = false, // area fill under each series
    gradient: bool = false, // fade the fill toward the baseline (implies fill)
    axes: bool = false, // draw solid left + bottom axis lines
    stacked: bool = false, // stack the series' areas (implies fill)
    expand: bool = false, // normalise each stack to 100% (implies stacked)
    dots: bool = false,
    dot_radius: f32 = 0, // 0 = default; larger = custom dots
    dot_hollow: bool = false, // ring (card-filled centre) instead of solid
    point_labels: bool = false,
    label_color: ?Rgba = null, // override the point-label colour
    max: f32 = 0,
    grid: bool = true,
    paint: ?*custom_paint.PaintContext = null,
};

fn series_max(series: []const Series) f32 {
    std.debug.assert(series.len <= MAX_SERIES);
    var m: f32 = 0;
    for (series) |s| m = @max(m, data_max(s.values));
    return m;
}

fn point_count(series: []const Series) usize {
    std.debug.assert(series.len <= MAX_SERIES);
    var n: usize = 0;
    for (series) |s| n = @max(n, s.values.len);
    return n;
}

pub fn line_chart(
    b: *RenderBuilder,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    opts: LineChartOptions,
) RenderError!void {
    std.debug.assert(opts.series.len <= MAX_SERIES);
    const n = point_count(opts.series);
    if (n == 0) return;
    if (opts.stacked or opts.expand) return line_stacked(b, x, y, w, h, opts, n);
    const maxv = if (opts.max > 0) opts.max else nice_max(series_max(opts.series));
    const p = try begin_plot_cfg(b, x, y, w, h, .{
        .theme = opts.theme,
        .maxv = maxv,
        .n = n,
        .labels = opts.labels,
        .grid = opts.grid,
    });
    if (opts.axes) {
        const ac = opts.theme.muted_foreground;
        try b.append_line(LineSegment.init(p.x, p.y, p.x, p.y + p.h, 1, ac));
        try b.append_line(LineSegment.init(p.x, p.y + p.h, p.x + p.w, p.y + p.h, 1, ac));
    }
    for (opts.series) |s| try draw_series(b, p, opts, s);
    if (opts.paint) |pp| {
        if (hover_idx(p, pp)) |idx| try line_tip(b, p, opts, pp, idx, x, w);
    }
}

// Sum of series 0..=k at category i (the stacked upper edge of band k).
fn cum_at(series: []const Series, k: usize, i: usize) f32 {
    var sum: f32 = 0;
    var j: usize = 0;
    while (j <= k) : (j += 1) {
        if (i < series[j].values.len) sum += series[j].values[i];
    }
    return sum;
}

// Stacked areas can't share a sloped baseline, so paint back-to-front: each
// series fills its cumulative line to the bottom in an opaque colour, and the
// next (lower) series draws on top, leaving only its own band visible. expand
// normalises every category to a full-height 100% stack.
fn line_stacked(
    b: *RenderBuilder,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    opts: LineChartOptions,
    n: usize,
) !void {
    const series = opts.series;
    const sc = series.len;
    if (sc == 0) return;
    const top = sc - 1;
    var peak: f32 = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) peak = @max(peak, cum_at(series, top, i));
    const maxv = if (opts.expand) 100 else if (opts.max > 0) opts.max else nice_max(peak);
    const p = try begin_plot_cfg(b, x, y, w, h, .{
        .theme = opts.theme,
        .maxv = maxv,
        .n = n,
        .labels = opts.labels,
        .grid = opts.grid,
    });
    const base = p.y + p.h;
    const slot = p.w / @as(f32, @floatFromInt(n));

    var k: usize = sc;
    while (k > 0) {
        k -= 1;
        var seg: usize = 0;
        while (seg + 1 < n) : (seg += 1) {
            const ax = p.x + slot * (@as(f32, @floatFromInt(seg)) + 0.5);
            const bx = p.x + slot * (@as(f32, @floatFromInt(seg + 1)) + 0.5);
            const ay = val_to_y(p, stacked_val(series, k, seg, opts.expand, maxv));
            const by = val_to_y(p, stacked_val(series, k, seg + 1, opts.expand, maxv));
            try b.append_polyline(Polyline.init(ax, ay, bx, by, base, series[k].color));
            try b.append_line(LineSegment.init(ax, ay, bx, by, LINE_TH, series[k].color));
        }
    }
    if (opts.paint) |pp| {
        if (hover_idx(p, pp)) |idx| try stacked_tip(b, p, opts, pp, idx, x, w);
    }
}

// Cumulative value at (k, i) mapped into the plot domain; expand turns it into
// a percent of that category's total.
fn stacked_val(series: []const Series, k: usize, i: usize, expand: bool, maxv: f32) f32 {
    const cum = cum_at(series, k, i);
    if (!expand) return cum;
    const total = cum_at(series, series.len - 1, i);
    return if (total > 0) cum / total * maxv else 0;
}

fn stacked_tip(
    b: *RenderBuilder,
    p: Plot,
    opts: LineChartOptions,
    pp: *custom_paint.PaintContext,
    idx: usize,
    bx: f32,
    bw: f32,
) !void {
    const slot = p.w / @as(f32, @floatFromInt(p.n));
    const gx = p.x + slot * (@as(f32, @floatFromInt(idx)) + 0.5);
    var gc = opts.theme.muted_foreground;
    gc.a *= 0.4;
    try b.append_line(LineSegment.init(gx, p.y, gx, p.y + p.h, 1, gc));
    var rows_buf: [MAX_SERIES]TipRow = undefined;
    var vbufs: [MAX_SERIES][24]u8 = undefined;
    var rn: usize = 0;
    for (opts.series) |s| {
        if (idx >= s.values.len) continue;
        rows_buf[rn] = .{
            .color = s.color,
            .name = s.name,
            .value = std.fmt.bufPrint(&vbufs[rn], "{d:.0}", .{s.values[idx]}) catch "",
        };
        rn += 1;
    }
    const header = if (idx < opts.labels.len) opts.labels[idx] else "";
    try draw_tip(b, opts.theme, pp.mouse_x, pp.mouse_y, header, rows_buf[0..rn], bx, bw);
}

fn point_at(p: Plot, values: []const f32, idx: usize) [2]f32 {
    std.debug.assert(p.n > 0); // slot divides by p.n
    std.debug.assert(idx < values.len);
    const slot = p.w / @as(f32, @floatFromInt(p.n));
    const cx = p.x + slot * (@as(f32, @floatFromInt(idx)) + 0.5);
    return .{ cx, val_to_y(p, values[idx]) };
}

fn draw_series(b: *RenderBuilder, p: Plot, opts: LineChartOptions, s: Series) !void {
    const n = s.values.len;
    if (n == 0) return;
    const base = p.y + p.h;
    var i: usize = 0;
    while (i + 1 < n) : (i += 1) {
        const a = point_at(p, s.values, i);
        const c = point_at(p, s.values, i + 1);
        var fc = s.color;
        fc.a *= if (opts.gradient) 0.4 else 0.18;
        const g: f32 = if (opts.gradient) 1 else 0;
        switch (opts.curve) {
            .linear => {
                if (opts.fill) {
                    var pl = Polyline.init(a[0], a[1], c[0], c[1], base, fc);
                    try b.append_polyline(pl.set_gradient(g).*);
                }
                try b.append_line(LineSegment.init(a[0], a[1], c[0], c[1], LINE_TH, s.color));
            },
            .step => {
                if (opts.fill) {
                    var pl = Polyline.init(a[0], a[1], c[0], a[1], base, fc);
                    try b.append_polyline(pl.set_gradient(g).*);
                }
                try b.append_line(LineSegment.init(a[0], a[1], c[0], a[1], LINE_TH, s.color));
                try b.append_line(LineSegment.init(c[0], a[1], c[0], c[1], LINE_TH, s.color));
            },
        }
    }
    if (opts.dots) {
        const r = if (opts.dot_radius > 0) opts.dot_radius else DOT_R;
        var j: usize = 0;
        while (j < n) : (j += 1) {
            const pt = point_at(p, s.values, j);
            const dc = if (j < s.point_colors.len) s.point_colors[j] else s.color;
            try draw_dot(b, pt[0], pt[1], r, dc, opts.dot_hollow, opts.theme);
        }
    }
    if (opts.point_labels) {
        const lc = opts.label_color orelse opts.theme.muted_foreground;
        const lsty = label.Style{
            .font_size = opts.theme.font_size - 3,
            .weight = .semi_bold,
            .color = lc,
        };
        var j: usize = 0;
        while (j < n) : (j += 1) {
            const pt = point_at(p, s.values, j);
            var vb: [16]u8 = undefined;
            const txt = std.fmt.bufPrint(&vb, "{d:.0}", .{s.values[j]}) catch "";
            const m = label.measure(b, txt, lsty);
            _ = try label.render(b, pt[0] - m.width / 2, pt[1] - m.ascent - 6, txt, lsty);
        }
    }
}

fn draw_dot(
    b: *RenderBuilder,
    cx: f32,
    cy: f32,
    r: f32,
    c: Rgba,
    hollow: bool,
    theme: *const Theme,
) !void {
    var o = Quad.init(cx - r, cy - r, r * 2, r * 2);
    _ = o.set_background(c).set_corner_radius(r);
    try b.append_quad(o);
    if (hollow and r > 2) {
        const ir = r - 2;
        var inner = Quad.init(cx - ir, cy - ir, ir * 2, ir * 2);
        _ = inner.set_background(theme.card).set_corner_radius(ir);
        try b.append_quad(inner);
    }
}

// A lighter ring + solid centre marking a hovered point.
fn draw_halo(b: *RenderBuilder, cx: f32, cy: f32, c: Rgba) !void {
    var halo = c;
    halo.a *= 0.3;
    var ho = Quad.init(cx - (DOT_R + 4), cy - (DOT_R + 4), (DOT_R + 4) * 2, (DOT_R + 4) * 2);
    _ = ho.set_background(halo).set_corner_radius(DOT_R + 4);
    try b.append_quad(ho);
    var so = Quad.init(cx - (DOT_R + 1), cy - (DOT_R + 1), (DOT_R + 1) * 2, (DOT_R + 1) * 2);
    _ = so.set_background(c).set_corner_radius(DOT_R + 1);
    try b.append_quad(so);
}

fn line_tip(
    b: *RenderBuilder,
    p: Plot,
    opts: LineChartOptions,
    pp: *custom_paint.PaintContext,
    idx: usize,
    bx: f32,
    bw: f32,
) !void {
    // Area marks the point with lighter dots only; a plain line adds a faint guide.
    if (!opts.fill) {
        const slot = p.w / @as(f32, @floatFromInt(p.n));
        const gx = p.x + slot * (@as(f32, @floatFromInt(idx)) + 0.5);
        var gc = opts.theme.muted_foreground;
        gc.a *= 0.4;
        try b.append_line(LineSegment.init(gx, p.y, gx, p.y + p.h, 1, gc));
    }
    for (opts.series) |s| {
        if (idx >= s.values.len) continue;
        const pt = point_at(p, s.values, idx);
        try draw_halo(b, pt[0], pt[1], s.color);
    }
    var rows_buf: [MAX_SERIES]TipRow = undefined;
    var vbufs: [MAX_SERIES][24]u8 = undefined;
    var rn: usize = 0;
    for (opts.series) |s| {
        if (idx >= s.values.len) continue;
        rows_buf[rn] = .{
            .color = s.color,
            .name = s.name,
            .value = std.fmt.bufPrint(&vbufs[rn], "{d:.0}", .{s.values[idx]}) catch "",
        };
        rn += 1;
    }
    const header = if (idx < opts.labels.len) opts.labels[idx] else "";
    try draw_tip(b, opts.theme, pp.mouse_x, pp.mouse_y, header, rows_buf[0..rn], bx, bw);
}

fn hover_idx(p: Plot, pp: *custom_paint.PaintContext) ?usize {
    if (p.n == 0 or !pp.is_hovered(p.x, p.y, p.w, p.h)) return null;
    const slot = p.w / @as(f32, @floatFromInt(p.n));
    var fi = (pp.mouse_x - p.x) / slot;
    if (fi < 0) fi = 0;
    var idx: usize = @intFromFloat(fi);
    if (idx >= p.n) idx = p.n - 1;
    return idx;
}

const TIP_PAD: f32 = 10;
const TIP_DOT: f32 = 9;
const TIP_HEAD: f32 = 22; // header band height
const TIP_ROW: f32 = 19; // per-series row height

pub const TipRow = struct { color: Rgba, name: []const u8, value: []const u8 };

// All quads flush before all glyphs, so the box alone can't hide what's
// behind it; mask those glyphs first. bx..bx+bw bounds the tooltip
// horizontally so it can't spill into a neighbouring card (whose glyphs
// draw later and would paint over the box). bw <= 0 disables the clamp.
fn draw_tip(
    b: *RenderBuilder,
    theme: *const Theme,
    mx: f32,
    my: f32,
    header: []const u8,
    rows: []const TipRow,
    bx: f32,
    bw: f32,
) !void {
    std.debug.assert(rows.len <= MAX_SERIES);
    const hs = label.Style{
        .font_size = theme.font_size - 1,
        .weight = .semi_bold,
        .color = theme.foreground,
    };
    const ns = label.Style{
        .font_size = theme.font_size - 2,
        .weight = .normal,
        .color = theme.muted_foreground,
    };
    const vs = label.Style{
        .font_size = theme.font_size - 2,
        .weight = .semi_bold,
        .color = theme.foreground,
    };
    const hm = label.measure(b, header, hs);
    var roww: f32 = 0;
    for (rows) |r| {
        const nm = label.measure(b, r.name, ns);
        const vm = label.measure(b, r.value, vs);
        const rw = TIP_DOT + 8 + (if (r.name.len > 0) nm.width + 24 else 0) + vm.width;
        roww = @max(roww, rw);
    }
    const tw = @max(hm.width, roww) + TIP_PAD * 2;
    const th = TIP_HEAD + @as(f32, @floatFromInt(rows.len)) * TIP_ROW + 8;
    var tx = mx + 14;
    if (bw > 0 and tx + tw > bx + bw) tx = mx - 14 - tw; // flip left of the cursor
    if (bw > 0 and tx < bx) tx = bx;
    const ty = if (my - th - 6 < 0) my + 14 else my - th - 6;

    for (b.sprites.items) |*s| {
        const sx = s.position[0];
        const sy = s.position[1];
        if (sx + s.size[0] > tx and sx < tx + tw and sy + s.size[1] > ty and sy < ty + th) {
            s.clip_bounds = .{ 0, 0, 0, 0 };
        }
    }

    var bg = Quad.init(tx, ty, tw, th);
    _ = bg.set_background(theme.popover)
        .set_corner_radius(theme.radius - 2)
        .set_border_color(theme.border)
        .set_border_width(1);
    try b.append_quad(bg);
    _ = try label.render(b, tx + TIP_PAD, ty + 8, header, hs);
    var ry = ty + TIP_HEAD + 5;
    for (rows) |r| {
        var d = Quad.init(tx + TIP_PAD, ry + 3, TIP_DOT, TIP_DOT);
        _ = d.set_background(r.color).set_corner_radius(2);
        try b.append_quad(d);
        if (r.name.len > 0) _ = try label.render(b, tx + TIP_PAD + TIP_DOT + 8, ry, r.name, ns);
        const vm = label.measure(b, r.value, vs);
        _ = try label.render(b, tx + tw - TIP_PAD - vm.width, ry, r.value, vs);
        ry += TIP_ROW;
    }
}

// ---- Bar (multi-series) ----

pub const BarDir = enum { vertical, horizontal };

pub const BarChartOptions = struct {
    theme: *const Theme,
    series: []const Series,
    labels: []const []const u8 = &.{},
    dir: BarDir = .vertical,
    stacked: bool = false, // grouped side-by-side when false
    bar_labels: bool = false,
    label_color: ?Rgba = null, // override the bar-label colour
    neg_color: ?Rgba = null, // colour for below-zero bars (else the series colour)
    max: f32 = 0,
    grid: bool = true,
    paint: ?*custom_paint.PaintContext = null,
};

// Stacked needs the tallest per-category sum; grouped needs the tallest bar.
fn bar_max(opts: BarChartOptions, n: usize) f32 {
    if (opts.max > 0) return opts.max;
    if (!opts.stacked) return nice_max(series_max(opts.series));
    var m: f32 = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        var sum: f32 = 0;
        for (opts.series) |s| {
            if (i < s.values.len) sum += s.values[i];
        }
        m = @max(m, sum);
    }
    return nice_max(m);
}

// Grouped vertical bars: nice-rounded [min, max], min < 0 only when data dips
// below zero. Stacked stays 0-based (negative stacks aren't modelled).
fn bar_domain(opts: BarChartOptions, n: usize) [2]f32 {
    std.debug.assert(opts.series.len <= MAX_SERIES);
    if (opts.stacked) return .{ 0, bar_max(opts, n) };
    var hi: f32 = 0;
    var lo: f32 = 0;
    for (opts.series) |s| {
        std.debug.assert(s.values.len <= MAX_POINTS);
        for (s.values) |v| {
            hi = @max(hi, v);
            lo = @min(lo, v);
        }
    }
    const maxv = if (opts.max > 0) opts.max else nice_max(hi);
    const minv = if (lo < 0) -nice_max(-lo) else 0;
    return .{ minv, maxv };
}

// Mixed bars carry a per-category palette; otherwise the series colour.
fn bar_color(s: Series, i: usize) Rgba {
    return if (i < s.point_colors.len) s.point_colors[i] else s.color;
}

fn cat_band(b: *RenderBuilder, bx: f32, by: f32, bw: f32, bh: f32, theme: *const Theme) !void {
    var band = Quad.init(bx, by, bw, bh);
    _ = band.set_background(tr.elevate(theme, 0.07));
    try b.append_quad(band);
}

fn bar_tip(b: *RenderBuilder, opts: BarChartOptions, idx: usize, bx: f32, bw: f32) !void {
    const pp = opts.paint orelse return;
    const header = if (idx < opts.labels.len) opts.labels[idx] else "";
    var rows_buf: [MAX_SERIES]TipRow = undefined;
    var vbufs: [MAX_SERIES][24]u8 = undefined;
    var rn: usize = 0;
    for (opts.series) |s| {
        if (idx >= s.values.len) continue;
        rows_buf[rn] = .{
            .color = bar_color(s, idx),
            .name = s.name,
            .value = std.fmt.bufPrint(&vbufs[rn], "{d:.0}", .{s.values[idx]}) catch "",
        };
        rn += 1;
    }
    try draw_tip(b, opts.theme, pp.mouse_x, pp.mouse_y, header, rows_buf[0..rn], bx, bw);
}

pub fn bar_chart(
    b: *RenderBuilder,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    opts: BarChartOptions,
) RenderError!void {
    std.debug.assert(opts.series.len <= MAX_SERIES);
    std.debug.assert(opts.labels.len <= MAX_POINTS);
    const n = point_count(opts.series);
    if (n == 0) return;
    std.debug.assert(n <= MAX_POINTS); // bar_h draws its own axes and skips begin_plot_cfg's cap
    if (opts.dir == .horizontal) return bar_h(b, x, y, w, h, opts, n, bar_max(opts, n));
    return bar_v(b, x, y, w, h, opts, n);
}

fn bar_v(b: *RenderBuilder, x: f32, y: f32, w: f32, h: f32, opts: BarChartOptions, n: usize) !void {
    const dom = bar_domain(opts, n);
    const p = try begin_plot_cfg(b, x, y, w, h, .{
        .theme = opts.theme,
        .minv = dom[0],
        .maxv = dom[1],
        .n = n,
        .labels = opts.labels,
        .grid = opts.grid,
    });
    const slot = p.w / @as(f32, @floatFromInt(n));
    const zero_y = val_to_y(p, 0);
    const sc: f32 = @floatFromInt(opts.series.len);
    const group_w = slot * BAR_RATIO;
    const hi = if (opts.paint) |pp| hover_idx(p, pp) else null;
    if (hi) |idx| {
        const band_x = p.x + slot * @as(f32, @floatFromInt(idx));
        try cat_band(b, band_x, p.y, slot, p.h, opts.theme);
    }

    var i: usize = 0;
    while (i < n) : (i += 1) {
        const cat_x = p.x + slot * @as(f32, @floatFromInt(i)) + (slot - group_w) / 2;
        if (opts.stacked) {
            const base = p.y + p.h;
            var acc: f32 = 0;
            for (opts.series) |s| {
                if (i >= s.values.len) continue;
                const top = base - p.h * std.math.clamp((acc + s.values[i]) / p.maxv, 0, 1);
                const bot = base - p.h * std.math.clamp(acc / p.maxv, 0, 1);
                var q = Quad.init(cat_x, top, group_w, bot - top);
                _ = q.set_background(s.color);
                try b.append_quad(q);
                acc += s.values[i];
            }
        } else {
            const bw = group_w / sc;
            for (opts.series, 0..) |s, si| {
                if (i >= s.values.len) continue;
                const v = s.values[i];
                const vy = val_to_y(p, v);
                const top = @min(vy, zero_y);
                const bh = @abs(vy - zero_y);
                const bx = cat_x + bw * @as(f32, @floatFromInt(si));
                const col = if (v < 0) (opts.neg_color orelse bar_color(s, i)) else bar_color(s, i);
                var q = Quad.init(bx, top, @max(1, bw - 2), @max(1, bh));
                _ = q.set_background(col).set_corner_radius(BAR_RADIUS);
                try b.append_quad(q);
                if (opts.bar_labels) {
                    const ly = if (v < 0) top + bh + 4 else top - 16;
                    try bar_label_c(b, opts, bx + (bw - 2) / 2, ly, v);
                }
            }
        }
    }
    if (hi) |idx| try bar_tip(b, opts, idx, x, w);
}

fn bar_label_c(b: *RenderBuilder, opts: BarChartOptions, cx: f32, ty: f32, v: f32) !void {
    const lc = opts.label_color orelse opts.theme.muted_foreground;
    const sty = label.Style{
        .font_size = opts.theme.font_size - 3,
        .weight = .semi_bold,
        .color = lc,
    };
    var vb: [16]u8 = undefined;
    const txt = std.fmt.bufPrint(&vb, "{d:.0}", .{v}) catch "";
    const m = label.measure(b, txt, sty);
    _ = try label.render(b, cx - m.width / 2, ty, txt, sty);
}

fn hover_idx_h(
    py: f32,
    ph: f32,
    n: usize,
    pp: *custom_paint.PaintContext,
    px: f32,
    pw: f32,
) ?usize {
    if (n == 0 or !pp.is_hovered(px, py, pw, ph)) return null;
    const slot = ph / @as(f32, @floatFromInt(n));
    var fi = (pp.mouse_y - py) / slot;
    if (fi < 0) fi = 0;
    var idx: usize = @intFromFloat(fi);
    if (idx >= n) idx = n - 1;
    return idx;
}

fn bar_h(
    b: *RenderBuilder,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    opts: BarChartOptions,
    n: usize,
    maxv: f32,
) !void {
    const theme = opts.theme;
    const pad_b: f32 = if (opts.grid) PAD_B else 0;
    const px = x + PAD_L;
    const pw = w - PAD_L;
    const ph = h - pad_b;
    const gsty = label.Style{
        .font_size = theme.font_size - AXIS_FONT_DELTA,
        .weight = .normal,
        .color = theme.muted_foreground,
    };

    if (opts.grid) {
        var k: usize = 0;
        while (k <= Y_DIVS) : (k += 1) {
            const t = @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(Y_DIVS));
            const gx = px + pw * t;
            try b.append_line(LineSegment.init(gx, y, gx, y + ph, 1, theme.border));
            var buf: [24]u8 = undefined;
            const txt = std.fmt.bufPrint(&buf, "{d:.0}", .{maxv * t}) catch "";
            const m = label.measure(b, txt, gsty);
            _ = try label.render(b, gx - m.width / 2, y + ph + 6, txt, gsty);
        }
    }

    const slot = ph / @as(f32, @floatFromInt(n));
    const sc: f32 = @floatFromInt(opts.series.len);
    const group_h = slot * BAR_RATIO;
    var li: usize = 0;
    while (li < n and li < opts.labels.len) : (li += 1) {
        const cy = y + slot * (@as(f32, @floatFromInt(li)) + 0.5);
        const m = label.measure(b, opts.labels[li], gsty);
        const ly = cy - (m.ascent + m.descent) / 2;
        _ = try label.render(b, px - 8 - m.width, ly, opts.labels[li], gsty);
    }

    const hi = if (opts.paint) |pp| hover_idx_h(y, ph, n, pp, px, pw) else null;
    if (hi) |idx| try cat_band(b, px, y + slot * @as(f32, @floatFromInt(idx)), pw, slot, theme);

    var i: usize = 0;
    while (i < n) : (i += 1) {
        const row_y = y + slot * @as(f32, @floatFromInt(i)) + (slot - group_h) / 2;
        if (opts.stacked) {
            var acc: f32 = 0;
            for (opts.series) |s| {
                if (i >= s.values.len) continue;
                const x0 = px + pw * std.math.clamp(acc / maxv, 0, 1);
                const x1 = px + pw * std.math.clamp((acc + s.values[i]) / maxv, 0, 1);
                var q = Quad.init(x0, row_y, x1 - x0, group_h);
                _ = q.set_background(s.color);
                try b.append_quad(q);
                acc += s.values[i];
            }
        } else {
            const bh = group_h / sc;
            for (opts.series, 0..) |s, si| {
                if (i >= s.values.len) continue;
                const bl = pw * std.math.clamp(s.values[i] / maxv, 0, 1);
                const ry = row_y + bh * @as(f32, @floatFromInt(si));
                var q = Quad.init(px, ry, @max(1, bl), @max(1, bh - 2));
                _ = q.set_background(bar_color(s, i)).set_corner_radius(BAR_RADIUS);
                try b.append_quad(q);
                if (opts.bar_labels) {
                    const lc = opts.label_color orelse theme.muted_foreground;
                    const lsty = label.Style{
                        .font_size = theme.font_size - 3,
                        .weight = .semi_bold,
                        .color = lc,
                    };
                    var vb: [16]u8 = undefined;
                    const txt = std.fmt.bufPrint(&vb, "{d:.0}", .{s.values[i]}) catch "";
                    const lm = label.measure(b, txt, lsty);
                    const ly = ry + (bh - 2) / 2 - (lm.ascent + lm.descent) / 2;
                    _ = try label.render(b, px + bl + 6, ly, txt, lsty);
                }
            }
        }
    }
    if (hi) |idx| try bar_tip(b, opts, idx, x, w);
}

// ---- Donut / pie ----

pub const MAX_SLICES = 16;

pub const Slice = struct {
    label: []const u8 = "",
    value: f32,
    color: Rgba,
};

pub const SliceLabel = enum { none, name, value, percent };
pub const LabelPos = enum { inside, outside };

pub const DonutChartOptions = struct {
    theme: *const Theme,
    slices: []const Slice,
    inner_ratio: f32 = 0.62, // 0 = full pie
    center_top: []const u8 = "", // big number in the hole
    center_bottom: []const u8 = "", // caption under it
    slice_labels: SliceLabel = .none,
    label_pos: LabelPos = .inside, // on the slice, or out past the rim
    label_lines: bool = false, // leader line from rim to an outside label
    active: ?usize = null, // a popped-out, emphasised slice
    paint: ?*custom_paint.PaintContext = null, // set to draw a hover tooltip
};

const SLICE_POP: f32 = 8;

// Pure, so a caller can drive an interactive pie by feeding the result back
// as `.active`.
pub fn donut_hit_test(
    cx: f32,
    cy: f32,
    size: f32,
    inner_ratio: f32,
    slices: []const Slice,
    mx: f32,
    my: f32,
) ?usize {
    std.debug.assert(slices.len <= MAX_SLICES);
    var total: f32 = 0;
    for (slices) |s| total += s.value;
    if (total <= 0) return null;
    const dx = mx - cx;
    const dy = my - cy;
    const dist = @sqrt(dx * dx + dy * dy);
    const outer = size / 2;
    if (dist < outer * inner_ratio or dist > outer) return null;
    var theta = std.math.atan2(dy, dx) * 180.0 / std.math.pi + 90; // 0 = 12 o'clock, clockwise
    if (theta < 0) theta += 360;
    var cum: f32 = 0;
    for (slices, 0..) |s, i| {
        const frac = s.value / total;
        if (theta >= cum * 360 and theta < (cum + frac) * 360) return i;
        cum += frac;
    }
    return null;
}

// (cx, cy) = centre; slices fill clockwise from 12 o'clock.
pub fn donut(
    b: *RenderBuilder,
    cx: f32,
    cy: f32,
    size: f32,
    opts: DonutChartOptions,
) RenderError!void {
    std.debug.assert(size > 0);
    std.debug.assert(opts.slices.len <= MAX_SLICES);
    std.debug.assert(opts.inner_ratio >= 0);
    std.debug.assert(opts.inner_ratio <= 1);
    const theme = opts.theme;
    var total: f32 = 0;
    for (opts.slices) |s| total += s.value;
    if (total <= 0) return;

    var cum: f32 = 0;
    for (opts.slices, 0..) |s, i| {
        const frac = s.value / total;
        // The active slice grows outward; shrink its inner_ratio in proportion
        // to the larger diameter so the hole edge stays put.
        const sz = if (opts.active == i) size + SLICE_POP else size;
        try ring_chart(b, cx - sz / 2, cy - sz / 2, sz, frac, .{
            .fill = s.color,
            .track = tr.transparent(), // only this slice's arc draws
            .inner_ratio = opts.inner_ratio * size / sz,
            .start_angle_deg = -90 + cum * 360,
        });
        cum += frac;
    }

    if (opts.slice_labels != .none) try draw_slice_labels(b, cx, cy, size, total, opts);

    if (opts.center_top.len > 0) {
        const sty = label.Style{
            .font_size = theme.font_size + 6,
            .weight = .semi_bold,
            .color = theme.foreground,
        };
        const m = label.measure(b, opts.center_top, sty);
        _ = try label.render(b, cx - m.width / 2, cy - m.ascent, opts.center_top, sty);
    }
    if (opts.center_bottom.len > 0) {
        const sty = label.Style{
            .font_size = theme.font_size - 3,
            .weight = .normal,
            .color = theme.muted_foreground,
        };
        const m = label.measure(b, opts.center_bottom, sty);
        _ = try label.render(b, cx - m.width / 2, cy + 4, opts.center_bottom, sty);
    }

    if (opts.paint) |pp| {
        if (!pp.mouse_inside) return;
        const hit = donut_hit_test(
            cx,
            cy,
            size,
            opts.inner_ratio,
            opts.slices,
            pp.mouse_x,
            pp.mouse_y,
        );
        if (hit) |idx| {
            const s = opts.slices[idx];
            var vb: [32]u8 = undefined;
            const pct = s.value / total * 100;
            const vstr = std.fmt.bufPrint(&vb, "{d:.0} ({d:.0}%)", .{ s.value, pct }) catch "";
            const rows = [_]TipRow{.{ .color = s.color, .name = "", .value = vstr }};
            try draw_tip(b, theme, pp.mouse_x, pp.mouse_y, s.label, &rows, 0, 0);
        }
    }
}

// Inside labels sit at the slice's mid-radius; outside labels sit just past
// the rim with an optional leader line back to it.
fn draw_slice_labels(
    b: *RenderBuilder,
    cx: f32,
    cy: f32,
    size: f32,
    total: f32,
    opts: DonutChartOptions,
) !void {
    const outer = size / 2;
    const r_mid = outer * (opts.inner_ratio + 1) / 2;
    const inside = opts.label_pos == .inside;
    // Slice fills are saturated, so on-slice text reads best as the dark canvas
    // colour; outside labels sit on the background and use the normal foreground.
    const col = if (inside) opts.theme.background else opts.theme.foreground;
    const sty = label.Style{
        .font_size = opts.theme.font_size - 3,
        .weight = .semi_bold,
        .color = col,
    };
    var cum: f32 = 0;
    for (opts.slices) |s| {
        const frac = s.value / total;
        const phi = (cum + frac / 2) * 360 * std.math.pi / 180.0; // clockwise from 12 o'clock
        const sn = @sin(phi);
        const cs = @cos(phi);
        var vb: [24]u8 = undefined;
        const txt = switch (opts.slice_labels) {
            .none => "",
            .name => s.label,
            .value => std.fmt.bufPrint(&vb, "{d:.0}", .{s.value}) catch "",
            .percent => std.fmt.bufPrint(&vb, "{d:.0}%", .{frac * 100}) catch "",
        };
        const m = label.measure(b, txt, sty);
        if (inside) {
            const lx = cx + r_mid * sn - m.width / 2;
            const ly = cy - r_mid * cs - (m.ascent + m.descent) / 2;
            _ = try label.render(b, lx, ly, txt, sty);
        } else {
            const lr = outer + 14;
            const px = cx + lr * sn;
            const py = cy - lr * cs;
            if (opts.label_lines) {
                const rx = cx + outer * sn;
                const ry = cy - outer * cs;
                const lead = LineSegment.init(rx, ry, px, py, 1, opts.theme.muted_foreground);
                try b.append_line(lead);
            }
            const tx = if (sn >= 0) px + 4 else px - 4 - m.width;
            _ = try label.render(b, tx, py - (m.ascent + m.descent) / 2, txt, sty);
        }
        cum += frac;
    }
}

// Concentric rings, one Slice set per ring (outermost first). Each ring is an
// independent 100% donut band separated by a gap.
pub const PieStackedOptions = struct {
    rings: []const []const Slice,
};

pub fn pie_stacked(
    b: *RenderBuilder,
    cx: f32,
    cy: f32,
    size: f32,
    opts: PieStackedOptions,
) RenderError!void {
    std.debug.assert(size > 0);
    const rings = opts.rings;
    std.debug.assert(rings.len <= MAX_SLICES);
    const r_count = rings.len;
    if (r_count == 0) return;
    const outer = size / 2;
    const band = outer / @as(f32, @floatFromInt(r_count));
    for (rings, 0..) |slices, k| {
        std.debug.assert(slices.len <= MAX_SLICES);
        var total: f32 = 0;
        for (slices) |s| total += s.value;
        if (total <= 0) continue;
        const r_out = outer - band * @as(f32, @floatFromInt(k));
        const r_in = r_out - band * 0.82; // gap between rings
        std.debug.assert(r_in >= 0);
        std.debug.assert(r_in <= r_out);
        const sz = r_out * 2;
        var cum: f32 = 0;
        for (slices) |s| {
            const frac = s.value / total;
            try ring_chart(b, cx - sz / 2, cy - sz / 2, sz, frac, .{
                .fill = s.color,
                .track = tr.transparent(),
                .inner_ratio = r_in / r_out,
                .start_angle_deg = -90 + cum * 360,
            });
            cum += frac;
        }
    }
}
