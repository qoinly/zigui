const std = @import("std");
const zigui = @import("zigui");
const Node = zigui.Node;
const Frame = zigui.Frame;
const App = @import("../app.zig").App;
const SelKind = App.SelKind;
const page = @import("../scaffold/page.zig");

const sel = zigui.kit.select;

const FRUITS = [_]sel.SelectItem{
    .{ .id = "apple", .label = "Apple" },
    .{ .id = "banana", .label = "Banana" },
    .{ .id = "blueberry", .label = "Blueberry" },
    .{ .id = "grapes", .label = "Grapes" },
    .{ .id = "pineapple", .label = "Pineapple" },
};
const VEGGIES = [_]sel.SelectItem{
    .{ .id = "carrot", .label = "Carrot" },
    .{ .id = "broccoli", .label = "Broccoli", .disabled = true },
    .{ .id = "spinach", .label = "Spinach" },
    .{ .id = "kale", .label = "Kale" },
    .{ .id = "peas", .label = "Peas" },
};
const SELECT_GROUPS = [_]sel.SelectGroup{
    .{ .label = "Fruits", .items = &FRUITS },
    .{ .label = "Vegetables", .items = &VEGGIES },
};
const FLAT_GROUPS = [_]sel.SelectGroup{.{ .items = &FRUITS }};
const TZ_ITEMS = [_]sel.SelectItem{
    .{ .id = "utc", .label = "UTC" },      .{ .id = "lon", .label = "London" },
    .{ .id = "par", .label = "Paris" },    .{ .id = "ber", .label = "Berlin" },
    .{ .id = "mos", .label = "Moscow" },   .{ .id = "dxb", .label = "Dubai" },
    .{ .id = "kar", .label = "Karachi" },  .{ .id = "dha", .label = "Dhaka" },
    .{ .id = "jkt", .label = "Jakarta" },  .{ .id = "sgp", .label = "Singapore" },
    .{ .id = "tyo", .label = "Tokyo" },    .{ .id = "syd", .label = "Sydney" },
    .{ .id = "akl", .label = "Auckland" },
};
const TZ_GROUPS = [_]sel.SelectGroup{.{ .items = &TZ_ITEMS }};

fn groups_for(kind: SelKind) []const sel.SelectGroup {
    return switch (kind) {
        .flat => &FLAT_GROUPS,
        .scroll => &TZ_GROUPS,
        .group, .search => &SELECT_GROUPS,
    };
}

fn sel_label(kind: SelKind, id: []const u8) []const u8 {
    for (groups_for(kind)) |g| {
        for (g.items) |it| {
            if (std.mem.eql(u8, it.id, id)) return it.label;
        }
    }
    return switch (kind) {
        .flat => "Select a fruit",
        .scroll => "Select a city",
        else => "Select an item",
    };
}

// Built into the app's scratch so the filtered slices outlive the per-frame node tree.
fn filtered_groups(app: *App) []const sel.SelectGroup {
    const s = &app.sel;
    const q = s.search.slice();
    if (q.len == 0) return &SELECT_GROUPS;
    var gi: usize = 0;
    var ii: usize = 0;
    for (SELECT_GROUPS) |grp| {
        const start = ii;
        for (grp.items) |it| {
            if (std.ascii.indexOfIgnoreCase(it.label, q) != null and ii < s.fg_items.len) {
                s.fg_items[ii] = it;
                ii += 1;
            }
        }
        if (ii > start and gi < s.fg.len) {
            s.fg[gi] = .{ .label = grp.label, .items = s.fg_items[start..ii] };
            gi += 1;
        }
    }
    return s.fg[0..gi];
}

fn open_sel(app: *App, kind: SelKind) void {
    app.sel.open = if (app.sel.open == kind) null else kind;
    app.sel.scroll = 0;
}
fn on_flat(app: *App) void {
    open_sel(app, .flat);
}
fn on_scroll(app: *App) void {
    open_sel(app, .scroll);
}
fn on_group(app: *App) void {
    open_sel(app, .group);
}
fn on_search(app: *App) void {
    open_sel(app, .search);
}
fn on_close(app: *App) void {
    app.sel.open = null;
}
fn on_pick(app: *App, id: []const u8) void {
    if (app.sel.open) |k| app.sel.vals[@intFromEnum(k)] = id; // id is a literal
    app.sel.open = null;
}
fn on_step(app: *App, delta: f32) void {
    app.sel.scroll += delta; // the panel re-clamps to its range each frame
}

fn trig(app: *App, kind: SelKind, on_click: zigui.ClickFn) *Node {
    const i = @intFromEnum(kind);
    return page.sized(240, zigui.select(sel_label(kind, app.sel.vals[i]), .{
        .open = app.sel.open == kind,
        .on_click = on_click,
        .rect_out = &app.sel.rects[i],
    }));
}

pub fn view(f: *Frame, app: *App) *Node {
    const t = f.theme;
    return page.page(&.{
        page.header("Select", "Pick one option from a dropdown."),
        page.section(t, "Default", &.{trig(app, .flat, zigui.on(App, on_flat))}),
        page.section(t, "Scrollable", &.{trig(app, .scroll, zigui.on(App, on_scroll))}),
        page.section(t, "Grouped", &.{trig(app, .group, zigui.on(App, on_group))}),
        page.section(t, "Searchable (combobox)", &.{trig(app, .search, zigui.on(App, on_search))}),
        page.section(t, "Disabled", &.{
            page.sized(240, zigui.select("Select an item", .{ .disabled = true })),
        }),
        page.section(t, "Invalid", &.{
            page.sized(240, zigui.select("Select an item", .{
                .invalid = true,
                .placeholder = true,
            })),
        }),
    });
}

// The dropdown panel, rendered in the overlay region while a trigger is open.
pub fn overlay(f: *Frame, app: *App) ?*Node {
    _ = f;
    const kind = app.sel.open orelse return null;
    const i = @intFromEnum(kind);
    const search = kind == .search;
    const groups = if (search) filtered_groups(app) else groups_for(kind);
    return zigui.select_overlay(.{
        .groups = groups,
        .selected_id = app.sel.vals[i],
        .state = &app.sel.state,
        .trigger = &app.sel.rects[i],
        // item-aligned keeps the chosen row over the trigger; the rest drop below.
        .position = if (kind == .flat) .item_aligned else .popper,
        .scroll = &app.sel.scroll,
        .search = search,
        .search_field = if (search) &app.sel.search else null,
        .on_select = zigui.on_id(App, on_pick),
        .on_scroll = zigui.on_delta(App, on_step),
        .on_dismiss = zigui.on(App, on_close),
    });
}
