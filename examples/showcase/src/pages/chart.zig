const zigui = @import("zigui");
const Node = zigui.Node;
const Frame = zigui.Frame;
const Theme = zigui.Theme;
const App = @import("../app.zig").App;
const page = @import("../scaffold/page.zig");

const ch = zigui.kit.chart;
const Rgba = zigui.Rgba;

const CHART_H: f32 = 168;
const DONUT_H: f32 = 200;

const C_BLUE = Rgba.from_hex(0x3B82F6);
const C_GREEN = Rgba.from_hex(0x22C55E);
const CHART_LABELS = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun" };
const CHART_VALUES = [_]f32{ 186, 305, 237, 273, 209, 314 };
const LINE_B = [_]f32{ 120, 190, 130, 240, 180, 290 };
const NEG_VALUES = [_]f32{ 186, -90, 237, -150, 120, 290 };
const DOT_PALETTE = [_]Rgba{
    Rgba.from_hex(0x3B82F6),
    Rgba.from_hex(0x22C55E),
    Rgba.from_hex(0xF59E0B),
    Rgba.from_hex(0xEF4444),
    Rgba.from_hex(0xA855F7),
    Rgba.from_hex(0x06B6D4),
};
const ONE_SERIES = [_]ch.Series{.{ .name = "Desktop", .color = C_BLUE, .values = &CHART_VALUES }};
const MULTI_SERIES = [_]ch.Series{
    .{ .name = "Desktop", .color = C_BLUE, .values = &CHART_VALUES },
    .{ .name = "Mobile", .color = C_GREEN, .values = &LINE_B },
};
const COLORED_SERIES = [_]ch.Series{
    .{ .name = "Visitors", .color = C_BLUE, .values = &CHART_VALUES, .point_colors = &DOT_PALETTE },
};
const NEG_SERIES = [_]ch.Series{.{ .name = "Net", .color = C_BLUE, .values = &NEG_VALUES }};
const DONUT_SLICES = [_]ch.Slice{
    .{ .label = "Chrome", .value = 275, .color = Rgba.from_hex(0x3B82F6) },
    .{ .label = "Safari", .value = 200, .color = Rgba.from_hex(0x22C55E) },
    .{ .label = "Firefox", .value = 187, .color = Rgba.from_hex(0xF59E0B) },
    .{ .label = "Edge", .value = 173, .color = Rgba.from_hex(0xEF4444) },
    .{ .label = "Other", .value = 90, .color = Rgba.from_hex(0xA1A1AA) },
};

fn card(t: *const Theme, title: []const u8, body: *Node) *Node {
    return zigui.col(.{
        .gap = .sm,
        .pad = .lg,
        .grow = 1,
        .min_width = 230,
        .max_width = 540,
        .bg = t.card,
        .border = t.border,
        .radius = t.radius,
    }, &.{
        zigui.text(title, .{ .size = 13, .weight = .semi_bold }),
        body,
    });
}

const LineMods = struct {
    curve: ch.Curve = .linear,
    fill: bool = false,
    gradient: bool = false,
    axes: bool = false,
    stacked: bool = false,
    expand: bool = false,
    dots: bool = false,
    dot_radius: f32 = 0,
    point_labels: bool = false,
};
fn lc(t: *const Theme, series: []const ch.Series, m: LineMods) *Node {
    return zigui.line_chart(.{
        .theme = t,
        .series = series,
        .labels = &CHART_LABELS,
        .curve = m.curve,
        .fill = m.fill,
        .gradient = m.gradient,
        .axes = m.axes,
        .stacked = m.stacked,
        .expand = m.expand,
        .dots = m.dots,
        .dot_radius = m.dot_radius,
        .point_labels = m.point_labels,
    }, CHART_H);
}

const BarMods = struct {
    dir: ch.BarDir = .vertical,
    stacked: bool = false,
    bar_labels: bool = false,
    neg_color: ?Rgba = null,
};
fn bc(t: *const Theme, series: []const ch.Series, m: BarMods) *Node {
    return zigui.bar_chart(.{
        .theme = t,
        .series = series,
        .labels = &CHART_LABELS,
        .dir = m.dir,
        .stacked = m.stacked,
        .bar_labels = m.bar_labels,
        .neg_color = m.neg_color,
    }, CHART_H);
}

const DonutMods = struct {
    inner: f32 = 0.62,
    labels: ch.SliceLabel = .none,
    pos: ch.LabelPos = .inside,
    lines: bool = false,
    top: []const u8 = "",
    bottom: []const u8 = "",
};
fn dn(t: *const Theme, m: DonutMods) *Node {
    return zigui.donut(.{
        .theme = t,
        .slices = &DONUT_SLICES,
        .inner_ratio = m.inner,
        .slice_labels = m.labels,
        .label_pos = m.pos,
        .label_lines = m.lines,
        .center_top = m.top,
        .center_bottom = m.bottom,
    }, DONUT_H);
}

pub fn line(f: *Frame, app: *App) *Node {
    _ = app;
    const t = f.theme;
    return page.page(&.{
        page.header("Line Chart", "Plot one or more series over a domain."),
        zigui.grid(.{ .gap = .md }, &.{
            card(t, "Linear", lc(t, &ONE_SERIES, .{})),
            card(t, "Step", lc(t, &ONE_SERIES, .{ .curve = .step })),
            card(t, "Multiple", lc(t, &MULTI_SERIES, .{})),
            card(t, "Dots", lc(t, &ONE_SERIES, .{ .dots = true })),
            card(t, "Point labels", lc(t, &ONE_SERIES, .{ .point_labels = true })),
            card(t, "Colored dots", lc(t, &COLORED_SERIES, .{ .dots = true, .dot_radius = 4 })),
        }),
    });
}

pub fn bar(f: *Frame, app: *App) *Node {
    _ = app;
    const t = f.theme;
    return page.page(&.{
        page.header("Bar Chart", "Compare values across categories."),
        zigui.grid(.{ .gap = .md }, &.{
            card(t, "Vertical", bc(t, &ONE_SERIES, .{})),
            card(t, "Horizontal", bc(t, &ONE_SERIES, .{ .dir = .horizontal })),
            card(t, "Grouped", bc(t, &MULTI_SERIES, .{})),
            card(t, "Stacked", bc(t, &MULTI_SERIES, .{ .stacked = true })),
            card(t, "Labels", bc(t, &ONE_SERIES, .{ .bar_labels = true })),
            card(t, "Negative", bc(t, &NEG_SERIES, .{ .neg_color = Rgba.from_hex(0xEF4444) })),
        }),
    });
}

pub fn area(f: *Frame, app: *App) *Node {
    _ = app;
    const t = f.theme;
    return page.page(&.{
        page.header("Area Chart", "A line chart with the area under it filled."),
        zigui.grid(.{ .gap = .md }, &.{
            card(t, "Linear", lc(t, &ONE_SERIES, .{ .fill = true })),
            card(t, "Step", lc(t, &ONE_SERIES, .{ .fill = true, .curve = .step })),
            card(t, "Gradient", lc(t, &ONE_SERIES, .{ .fill = true, .gradient = true })),
            card(t, "Axes", lc(t, &ONE_SERIES, .{ .fill = true, .axes = true })),
            card(t, "Stacked", lc(t, &MULTI_SERIES, .{ .stacked = true })),
            card(t, "Expanded", lc(t, &MULTI_SERIES, .{ .expand = true })),
        }),
    });
}

pub fn pie(f: *Frame, app: *App) *Node {
    _ = app;
    const t = f.theme;
    return page.page(&.{
        page.header("Pie Chart", "Show parts of a whole."),
        zigui.grid(.{ .gap = .md }, &.{
            card(t, "Pie", dn(t, .{ .inner = 0 })),
            card(t, "Donut", dn(t, .{ .top = "925", .bottom = "Visitors" })),
            card(t, "Labeled", dn(t, .{
                .inner = 0,
                .labels = .value,
                .pos = .outside,
                .lines = true,
            })),
            card(t, "Percent", dn(t, .{ .labels = .percent })),
        }),
    });
}
