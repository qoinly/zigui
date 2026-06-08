const zigui = @import("zigui");
const Node = zigui.Node;
const Frame = zigui.Frame;
const Theme = zigui.Theme;
const App = @import("../app.zig").App;
const page = @import("../scaffold/page.zig");

const ICON_SYMS = [_]zigui.Icon{
    .close,
    .check,
    .plus,
    .chevron_down,
    .chevron_right,
    .arrow_right,
    .search,
    .gear,
    .bell,
    .info,
    .warning,
    .share,
    .copy,
    .grid,
    .eye,
    .calendar,
    .folder,
    .trash,
    .doc,
    .envelope,
    .message,
    .person,
    .heart,
    .chart_bar,
    .dollar_sign,
    .bolt,
    .moon,
    .sun,
    .pin,
    .save,
};

// A wider gap than page.section, matching the reference icon grid.
fn sym_grid(t: *const Theme, title: []const u8, source: zigui.IconSource) *Node {
    var kids: [ICON_SYMS.len]*Node = undefined;
    inline for (ICON_SYMS, 0..) |ic, i| {
        kids[i] = zigui.icon(ic, .{ .size = 22, .color = t.foreground, .source = source });
    }
    return zigui.col(.{ .gap = .sm }, &.{
        page.title_label(title),
        zigui.row(.{
            .gap = .lg,
            .cross = .center,
            .wrap = true,
            .pad = .lg,
            .bg = t.card,
            .border = t.border,
            .radius = t.radius,
        }, &kids),
    });
}

pub fn view(f: *Frame, app: *App) *Node {
    _ = app;
    const t = f.theme;
    return page.page(&.{
        page.header(
            "Icons",
            "One portable Icon enum, from the platform's own symbols or the bundled Lucide set.",
        ),
        sym_grid(t, "Native - the platform's own set (SF Symbols, Segoe, ...)", .native),
        sym_grid(t, "Bundled (Lucide) - the same glyph on every platform", .bundled),
    });
}
