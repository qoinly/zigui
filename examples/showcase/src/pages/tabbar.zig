const std = @import("std");
const zigui = @import("zigui");
const Node = zigui.Node;
const Frame = zigui.Frame;
const App = @import("../app.zig").App;
const page = @import("../scaffold/page.zig");
const tb = zigui.kit.tabbar;

const TAB_SEED = [_]App.TabRec{
    .{
        .id = "t_health",
        .title = "Health Check",
        .prefix = "GET",
        .pcolor = 0x22C55E,
        .pinned = true,
    },
    .{ .id = "t_users", .title = "Get Users", .prefix = "GET", .pcolor = 0x22C55E, .pinned = true },
    .{
        .id = "t_create",
        .title = "Create User",
        .prefix = "POST",
        .pcolor = 0xF59E0B,
        .dirty = true,
    },
    .{ .id = "t_del", .title = "Delete Session", .prefix = "DEL", .pcolor = 0xEF4444 },
    .{
        .id = "t_refresh",
        .title = "Refresh Token",
        .prefix = "POST",
        .pcolor = 0xF59E0B,
        .dirty = true,
    },
    .{ .id = "t_orders", .title = "List Orders", .prefix = "GET", .pcolor = 0x22C55E },
    .{ .id = "t_webhook", .title = "Webhook Config", .prefix = "PUT", .pcolor = 0x3B82F6 },
};

fn seed(app: *App) void {
    const tt = &app.tabbar;
    if (tt.seeded) return;
    for (TAB_SEED, 0..) |r, i| tt.recs[i] = r;
    tt.recs_len = TAB_SEED.len;
    tt.seeded = true;
}

fn build_items(app: *App) []const tb.TabItem {
    const tt = &app.tabbar;
    var i: usize = 0;
    while (i < tt.recs_len) : (i += 1) {
        const r = tt.recs[i];
        tt.items[i] = .{
            .id = r.id,
            .title = r.title,
            .prefix = r.prefix,
            .prefix_color = if (r.pcolor != 0) zigui.Rgba.from_hex(r.pcolor) else null,
            .dirty = r.dirty,
            .pinned = r.pinned,
        };
    }
    return tt.items[0..tt.recs_len];
}

fn pinned_count(tt: *App.Tabbar) usize {
    var c: usize = 0;
    for (tt.recs[0..tt.recs_len]) |r| {
        if (r.pinned) c += 1;
    }
    return c;
}

fn move(tt: *App.Tabbar, from: usize, to: usize) void {
    if (from == to) return;
    const moved = tt.recs[from];
    if (from < to) {
        var k = from;
        while (k < to) : (k += 1) tt.recs[k] = tt.recs[k + 1];
    } else {
        var k = from;
        while (k > to) : (k -= 1) tt.recs[k] = tt.recs[k - 1];
    }
    tt.recs[to] = moved;
    if (tt.active == from) {
        tt.active = to;
    } else if (from < to and tt.active > from and tt.active <= to) {
        tt.active -= 1;
    } else if (to < from and tt.active >= to and tt.active < from) {
        tt.active += 1;
    }
}

fn on_select(app: *App, i: usize) void {
    const tt = &app.tabbar;
    if (i < tt.recs_len) tt.active = i;
}

fn on_close(app: *App, i: usize) void {
    const tt = &app.tabbar;
    if (i >= tt.recs_len) return;
    var k = i;
    while (k + 1 < tt.recs_len) : (k += 1) tt.recs[k] = tt.recs[k + 1];
    tt.recs_len -= 1;
    if (tt.active > i) tt.active -= 1;
    if (tt.recs_len > 0 and tt.active >= tt.recs_len) tt.active = tt.recs_len - 1;
}

fn on_new(app: *App) void {
    const tt = &app.tabbar;
    if (tt.recs_len >= tb.MAX_TABS) return;
    const slot = tt.new_n % tt.new_bufs.len;
    const id = std.fmt.bufPrint(&tt.new_bufs[slot], "new{d}", .{tt.new_n}) catch "new";
    tt.new_n += 1;
    tt.recs[tt.recs_len] = .{ .id = id, .title = "Untitled", .dirty = true };
    tt.active = tt.recs_len;
    tt.recs_len += 1;
    tt.scroll = 1e9; // scroll-to-end request; clamped next frame
}

fn on_move(app: *App, from: usize, to: usize) void {
    const tt = &app.tabbar;
    if (from >= tt.recs_len or to >= tt.recs_len) return;
    // Keep pinned tabs grouped at the front: clamp a move into its own region.
    const pc = pinned_count(tt);
    const clamped = if (from < pc) @min(to, pc - 1) else @max(to, pc);
    move(tt, from, clamped);
}

fn on_pin(app: *App, i: usize) void {
    const tt = &app.tabbar;
    if (i >= tt.recs_len or !tt.recs[i].pinned) return;
    tt.recs[i].pinned = false; // clicking a pinned tab's glyph unpins it
    move(tt, i, pinned_count(tt));
}

pub fn view(f: *Frame, app: *App) *Node {
    const t = f.theme;
    seed(app);
    const tt = &app.tabbar;
    const card: *Node = if (tt.recs_len == 0)
        zigui.text("No open tabs. Click + to open one.", .{ .size = 13, .muted = true })
    else card: {
        const active = tt.recs[@min(tt.active, tt.recs_len - 1)];
        break :card zigui.col(.{
            .pad = .lg,
            .gap = .sm,
            .bg = t.card,
            .border = t.border,
            .radius = t.radius,
        }, &.{
            zigui.text(active.title, .{ .size = 15, .weight = .semi_bold }),
            zigui.text("The request editor for this tab would render here.", .{
                .size = 13,
                .muted = true,
            }),
        });
    };
    return page.page(&.{
        page.header(
            "Tab Bar",
            "Closeable, reorderable tabs for open pages (Postman / Insomnia style).",
        ),
        zigui.tabbar(.{
            .tabs = build_items(app),
            .active = tt.active,
            .state = &tt.state,
            .scroll_x = &tt.scroll,
            .on_select = zigui.on_index(App, on_select),
            .on_close = zigui.on_index(App, on_close),
            .on_new = zigui.on(App, on_new),
            .on_move = zigui.on_move2(App, on_move),
            .on_pin = zigui.on_index(App, on_pin),
        }),
        card,
    });
}
