const std = @import("std");
const zigui = @import("zigui");

// Two-window smoke test for the multi-window path: each window routes its own
// clicks and drives its own copy of the text field, and only the key window
// holds the shared native editor (gated on window_is_key), so typing in one
// window never leaks into the other. Window identity (title) lives on the
// window, not in this state, which carries only per-window data.
const Pane = struct {
    app: *zigui.App,
    field: zigui.TextField = .{},
    focused: bool = false,
    clicks: u32 = 0,
    line_buf: [32]u8 = undefined, // formatted text outlives render (laid out after)

    fn bump(self: *Pane) void {
        self.clicks += 1;
    }
    fn focus_field(self: *Pane) void {
        self.focused = true;
    }
    fn open_second(self: *Pane) void {
        if (g_second_open) return; // one window 2 is enough for the smoke test
        g_second_open = true;
        self.app.open_window(.{ .title = "Window 2" }, &g_second, .{ .body = render }) catch {};
    }
};

var g_second: Pane = undefined;
var g_second_open: bool = false;

// Let the second window be reopened (fresh) after it is closed.
fn on_window_closed(_: ?*anyopaque, id: u32) void {
    if (id != 2) return;
    g_second = .{ .app = g_second.app };
    g_second_open = false;
}

pub fn main() !void {
    var app = try zigui.App.init(.{ .title = "Window 1", .size = .{ 560, 420 } });
    defer app.deinit();
    app.on_window_closed(on_window_closed);
    var first: Pane = .{ .app = app };
    g_second = .{ .app = app };
    try app.run(&first, .{ .body = render });
}

fn render(f: *zigui.Frame, p: *Pane) *zigui.Node {
    _ = f;
    // Only the key window may hold the editor; drop focus on the others so the
    // shared native field stays put.
    if (!zigui.window_is_key()) p.focused = false;

    const line = std.fmt.bufPrint(&p.line_buf, "clicks: {d}", .{p.clicks}) catch "";
    const field = zigui.text_input(&p.field, .{
        .placeholder = "type here",
        .focused = p.focused,
        .on_focus = zigui.on(Pane, Pane.focus_field),
    });

    // The first window offers the button that spawns the second.
    if (zigui.window_id() == 1) {
        return zigui.col(.{ .pad = .lg, .gap = .md, .grow = 1 }, &.{
            zigui.text(zigui.window_title(), .{ .size = 24 }),
            zigui.text(line, .{ .size = 16 }),
            zigui.button("Click me", .{ .on_click = zigui.on(Pane, Pane.bump) }),
            field,
            zigui.button("Open second window", .{ .on_click = zigui.on(Pane, Pane.open_second) }),
        });
    }
    return zigui.col(.{ .pad = .lg, .gap = .md, .grow = 1 }, &.{
        zigui.text(zigui.window_title(), .{ .size = 24 }),
        zigui.text(line, .{ .size = 16 }),
        zigui.button("Click me", .{ .on_click = zigui.on(Pane, Pane.bump) }),
        field,
    });
}
