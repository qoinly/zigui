const zigui = @import("zigui");
const Node = zigui.Node;
const Frame = zigui.Frame;

// Bottom-bar navigation, edge-to-edge per Apple's HIG: content scrolls under the top
// nav bar and the floating tab bar. Each tab demos a large-title style (collapse to a
// small title, stay while a frost ramps in, or hide on scroll). A button pushes a
// detail page (sliding in from the right) with a circle glass back button. Icons are
// builtin Lucide.
const tabs = [_]zigui.BottomBarItem{
    .{ .icon = .doc, .label = "Today" },
    .{ .icon = .bolt, .label = "Games" },
    .{ .icon = .layout_grid, .label = "Apps" },
    .{ .icon = .heart, .label = "Arcade" },
    .{ .icon = .search, .label = "Search" },
};

const palette = [_]zigui.Rgba{
    .{ .r = 0.92, .g = 0.26, .b = 0.30, .a = 1 },
    .{ .r = 0.20, .g = 0.52, .b = 0.96, .a = 1 },
    .{ .r = 0.22, .g = 0.80, .b = 0.44, .a = 1 },
    .{ .r = 0.96, .g = 0.72, .b = 0.12, .a = 1 },
};

pub const App = struct {
    tab: usize = 0,
    detail: bool = false,
    push: zigui.PushState = .{},
    bottom_nav: zigui.BottomBarState = .{},
    list: zigui.ScrollState = .{},
    detail_list: zigui.ScrollState = .{},

    pub fn render(f: *Frame, app: *App) *Node {
        const safe_top = f.body.origin.y;
        // The tab page and the pushed detail page slide past each other; the tab bar
        // stays fixed above the slide.
        const base = tab_body(f, app, safe_top);
        const pushed = detail_body(f, app, safe_top);
        return zigui.col(.{}, &.{
            zigui.push_slide(f, &app.push, &app.detail, base, pushed),
            zigui.bottom_bar(&tabs, &app.bottom_nav, .{
                .active = app.tab,
                .style = .floating,
                .on_select = zigui.on_index(App, select_tab),
            }),
        });
    }
};

// The active tab's page body (scroll + the floating top bar). Item 0 is a button that
// pushes the detail page; the rest are plain rows, so a tab scrolls cleanly (only a real
// navigation shows a back button).
fn tab_body(f: *Frame, app: *App, safe_top: f32) *Node {
    const items = f.arena.alloc(*Node, 41) catch return zigui.text("oom", .{});
    items[0] = zigui.button("Open a detail page", .{ .on_click = zigui.on(App, open_detail) });
    for (items[1..], 0..) |*r, i| {
        const bg = palette[(i + app.tab) % palette.len];
        r.* = zigui.col(.{ .height = 48, .radius = 12, .bg = bg }, &.{});
    }
    const content = zigui.col(.{}, &.{
        // clears the status bar, the large title, and the search row
        zigui.col(.{ .height = safe_top + 96 }, &.{}),
        zigui.col(.{ .pad = .lg, .gap = .md }, items),
        zigui.col(.{ .height = 86 }, &.{}), // clears the floating tab bar at the end
    });
    // Each tab demos a large-title style: collapse-to-small, sticky (frost ramps in on
    // scroll), then hide (the whole bar fades away as you scroll down).
    const styles = [_]zigui.TopBarStyle{
        .large, // Today
        .large_sticky, // Games
        .large_hide, // Apps
        .large, // Arcade
        .large_sticky, // Search
    };
    const style = styles[app.tab];
    return zigui.col(.{}, &.{
        zigui.scroll(&app.list, .{ .height = f.size.height }, content),
        zigui.top_bar(tabs[app.tab].label, .{
            .style = style,
            .scroll = &app.list,
            .search = "Search",
            .frost = style != .large_hide,
        }),
    });
}

// The pushed page body: no full-width nav frost, just circle glass back + action buttons
// over the content; the page's own title scrolls in the body.
fn detail_body(f: *Frame, app: *App, safe_top: f32) *Node {
    const items = f.arena.alloc(*Node, 13) catch return zigui.text("oom", .{});
    items[0] = zigui.text("Detail", .{ .size = 32 });
    for (items[1..], 0..) |*r, i| {
        r.* = zigui.col(.{ .height = 48, .radius = 12, .bg = palette[i % palette.len] }, &.{});
    }
    const content = zigui.col(.{}, &.{
        zigui.col(.{ .height = safe_top + 58 }, &.{}), // under the circle buttons
        zigui.col(.{ .pad = .lg, .gap = .md }, items),
        zigui.col(.{ .height = 86 }, &.{}),
    });
    return zigui.col(.{}, &.{
        zigui.scroll(&app.detail_list, .{ .height = f.size.height }, content),
        zigui.top_bar("Detail", .{
            .style = .none,
            .frost = false,
            .on_back = zigui.on(App, go_back),
            .on_action = zigui.on(App, share),
            .action_icon = .share,
        }),
    });
}

fn select_tab(app: *App, i: usize) void {
    app.tab = i;
}
fn open_detail(app: *App) void {
    app.detail = true;
}
fn go_back(app: *App) void {
    app.detail = false;
}
fn share(app: *App) void {
    _ = app; // a placeholder action; the demo just shows the right-hand glass button
}
