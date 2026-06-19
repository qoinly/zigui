const zigui = @import("zigui");
const Node = zigui.Node;
const Frame = zigui.Frame;
const App = @import("../app.zig").App;

// Four top-level destinations; a real app would swap the body per tab. Here the body
// just names the active one, so the highlight + the tap-to-switch are what show.
const items = [_]zigui.BottomBarItem{
    .{ .icon = .grid, .label = "Home" },
    .{ .icon = .search, .label = "Search" },
    .{ .icon = .bell, .label = "Alerts" },
    .{ .icon = .person, .label = "Profile" },
};

pub fn open(app: *App) void {
    app.nav.push("bottombar", "Bottom Bar");
}

fn select(app: *App, i: usize) void {
    app.tab = i;
}

fn toggle_style(app: *App) void {
    app.bb_style = if (app.bb_style == .floating) .standard else .floating;
}

pub fn view(f: *Frame, app: *App) *Node {
    const style_label = if (app.bb_style == .floating) "Style: floating" else "Style: standard";
    // The real system nav inset, from the safe-area body (device-specific, not a
    // guess). The standard bar's surface fills down into it to the screen edge; the
    // items stay above it. (A floating bar floats above the nav and ignores it.)
    const inset = f.size.height - (f.body.origin.y + f.body.size.height);
    return zigui.col(.{ .grow = 1 }, &.{
        zigui.col(.{ .grow = 1, .pad = .lg, .gap = .md }, &.{
            zigui.text("Bottom navigation.", .{ .size = 22 }),
            zigui.text(items[app.tab].label, .{ .size = 16, .muted = true }),
            zigui.button(style_label, .{ .on_click = zigui.on(App, toggle_style) }),
        }),
        zigui.bottom_bar(&items, &app.bottom_nav, .{
            .active = app.tab,
            .style = app.bb_style,
            .indicator = true,
            .safe_bottom = inset,
            .on_select = zigui.on_index(App, select),
        }),
    });
}
