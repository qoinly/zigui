const std = @import("std");
const zigui = @import("zigui");

// Shows the display + fullscreen mechanism: lists each monitor's frame and toggles
// the window in and out of native fullscreen.
const App = struct {
    want_toggle: bool = false,
    lines: [6][96]u8 = undefined,

    fn toggle(self: *App) void {
        self.want_toggle = true;
    }
};

pub fn main() !void {
    var state: App = .{};
    var app = try zigui.App.init(.{ .title = "Display demo", .size = .{ 640, 420 } });
    defer app.deinit();
    try app.run(&state, .{ .body = render });
}

fn render(f: *zigui.Frame, app: *App) *zigui.Node {
    _ = f;
    if (app.want_toggle) {
        zigui.set_fullscreen(!zigui.fullscreen());
        app.want_toggle = false;
    }
    zigui.animate(); // fullscreen transitions async; keep the labels current

    var kids: [7]*zigui.Node = undefined;
    var n: usize = 0;

    const l0 = std.fmt.bufPrint(&app.lines[0], "fullscreen: {}", .{zigui.fullscreen()}) catch "";
    const count = zigui.display_count();
    const l1 = std.fmt.bufPrint(&app.lines[1], "displays: {d}", .{count}) catch "";
    kids[n] = zigui.text(l0, .{ .size = 16 });
    n += 1;
    kids[n] = zigui.text(l1, .{ .size = 16 });
    n += 1;

    const shown = @min(count, 4);
    var i: u32 = 0;
    while (i < shown) : (i += 1) {
        const b = zigui.display_bounds(i);
        const line = std.fmt.bufPrint(&app.lines[2 + i], "  #{d}: {d:.0},{d:.0} {d:.0}x{d:.0}", .{
            i, b.origin.x, b.origin.y, b.size.width, b.size.height,
        }) catch "";
        kids[n] = zigui.text(line, .{ .size = 14 });
        n += 1;
    }
    kids[n] = zigui.button("Toggle fullscreen", .{ .on_click = zigui.on(App, App.toggle) });
    n += 1;

    return zigui.col(.{ .pad = .lg, .gap = .sm, .grow = 1 }, kids[0..n]);
}
