const zigui = @import("zigui");
const Node = zigui.Node;
const Frame = zigui.Frame;
const App = @import("../app.zig").App;
const detail = @import("detail.zig");
const frame_page = @import("frame.zig");
const native = @import("native.zig");
const accessibility = @import("accessibility.zig");
const notif = @import("notif.zig");
const broadcasts = @import("broadcasts.zig");
const kit = @import("kit.zig");
const background = @import("background.zig");
const headless = @import("headless.zig");
const onboarding = @import("onboarding.zig");
const permissions = @import("permissions.zig");
const bottombar = @import("bottombar.zig");

// A tap adds a dot, capped so the row never overflows the surface. With no font the
// label does not render, so the dot row is the visible proof a touch reached the kit.
const MAX_DOTS = 8;
// Enough rows to overflow the viewport so the list is scrollable by drag.
const LIST_ROWS = 16;

fn tap(app: *App) void {
    app.clicks += 1;
}
fn focus_field(app: *App) void {
    app.focus = 1;
}
fn blur_fields(app: *App) void {
    app.focus = 0;
}
fn toggle_awake(app: *App) void {
    app.awake = !app.awake;
}
fn toggle_immersive(app: *App) void {
    app.immersive = !app.immersive;
}

pub fn view(f: *Frame, app: *App) *Node {
    const n = @min(app.clicks, MAX_DOTS);
    var dots: []const *Node = &.{};
    if (f.arena.alloc(*Node, n)) |slice| {
        const box = zigui.Config{ .width = 28, .height = 28, .radius = 8, .bg = f.theme.primary };
        for (slice) |*dot| dot.* = zigui.col(box, &.{});
        dots = slice;
    } else |_| {}

    // A tall list of alternating bars; dragging inside it scrolls (the bars shift).
    var rows: []const *Node = &.{};
    if (f.arena.alloc(*Node, LIST_ROWS)) |slice| {
        for (slice, 0..) |*r, i| {
            const c = if (i % 2 == 0) f.theme.primary else f.theme.border;
            r.* = zigui.col(.{ .height = 44, .radius = 8, .bg = c }, &.{});
        }
        rows = slice;
    } else |_| {}

    // A click that misses the field blurs the shared editor (hides the keyboard).
    const shell = zigui.Config{
        .pad = .lg,
        .gap = .md,
        .grow = 1,
        .on_click = zigui.on(App, blur_fields),
    };
    const returned = app.last_result[0..app.last_result_len];
    const note = if (app.last_result_len > 0) returned else "(no result yet)";
    const awake_label = if (app.awake) "Keep awake: ON" else "Keep awake: off";
    const imm_label = if (app.immersive) "Immersive: ON" else "Immersive: off";
    return zigui.col(shell, &.{
        zigui.text("Hello, Android.", .{ .size = 28 }),
        zigui.button("Tap me", .{ .on_click = zigui.on(App, tap) }),
        zigui.button("Open details", .{ .on_click = zigui.on(App, detail.open) }),
        zigui.button("Show AHB frame", .{ .on_click = zigui.on(App, frame_page.open) }),
        zigui.button("Native APIs", .{ .on_click = zigui.on(App, native.open) }),
        zigui.button("Permissions", .{ .on_click = zigui.on(App, permissions.open) }),
        zigui.button("Accessibility", .{ .on_click = zigui.on(App, accessibility.open) }),
        zigui.button("Notif listener", .{ .on_click = zigui.on(App, notif.open) }),
        zigui.button("Broadcasts", .{ .on_click = zigui.on(App, broadcasts.open) }),
        zigui.button("Kit UI", .{ .on_click = zigui.on(App, kit.open) }),
        zigui.button("Bottom bar", .{ .on_click = zigui.on(App, bottombar.open) }),
        zigui.button("Background", .{ .on_click = zigui.on(App, background.open) }),
        zigui.button("Headless", .{ .on_click = zigui.on(App, headless.open) }),
        zigui.button("Onboarding", .{ .on_click = zigui.on(App, onboarding.open) }),
        zigui.button(awake_label, .{ .on_click = zigui.on(App, toggle_awake) }),
        zigui.button(imm_label, .{ .on_click = zigui.on(App, toggle_immersive) }),
        zigui.text(note, .{ .size = 16 }),
        zigui.text_input(&app.field, .{
            .placeholder = "Tap to type",
            .focused = app.focus == 1,
            .id = 1,
            .on_focus = zigui.on(App, focus_field),
        }),
        zigui.row(.{ .gap = .sm }, dots),
        zigui.scroll(&app.list_scroll, .{ .grow = 1 }, zigui.col(.{ .gap = .sm }, rows)),
    });
}
