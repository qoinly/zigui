const std = @import("std");
const zigui = @import("zigui");

// Shows the raw input-capture path: click Grab to enter relative capture, then the
// keyboard and mouse feed input_events() instead of the widgets. Escape releases.
// A real remote client would forward these events over the wire.
const App = struct {
    want_grab: bool = false,
    last_scancode: u16 = 0,
    last_down: bool = false,
    keys: u32 = 0,
    moves: u32 = 0,
    dx: f32 = 0,
    dy: f32 = 0,
    wheel: f32 = 0,
    btn_left: bool = false,
    btn_right: bool = false,
    btn_middle: bool = false,
    btn_events: u32 = 0,
    last_btn: []const u8 = "-",
    lines: [6][160]u8 = undefined,

    fn enter_grab(self: *App) void {
        self.want_grab = true;
    }
};

pub fn main() !void {
    var state: App = .{};
    var app = try zigui.App.init(.{ .title = "Input demo", .size = .{ 720, 520 } });
    defer app.deinit();
    try app.run(&state, .{ .body = render });
}

fn render(f: *zigui.Frame, app: *App) *zigui.Node {
    _ = f;
    for (zigui.input_events()) |ev| switch (ev) {
        .key => |k| {
            app.last_scancode = k.scancode;
            app.last_down = k.down;
            app.keys += 1;
        },
        .motion => |m| {
            app.dx += m.dx;
            app.dy += m.dy;
            app.moves += 1;
        },
        .button => |b| {
            app.btn_events += 1;
            app.last_btn = switch (b.button) {
                .left => "left",
                .right => "right",
                .middle => "middle",
                .other => "other",
            };
            switch (b.button) {
                .left => app.btn_left = b.down,
                .right => app.btn_right = b.down,
                .middle => app.btn_middle = b.down,
                .other => {},
            }
        },
        .wheel => |w| app.wheel += w.dy,
    };
    if (app.want_grab and !zigui.grabbed()) {
        zigui.grab(true);
        app.want_grab = false;
    }
    // While grabbed there may be no widget input to wake the loop, so keep ticking
    // (also lets release-on-blur poll).
    if (zigui.grabbed()) zigui.animate();

    const status = if (zigui.grabbed())
        "GRABBED - move / type / click; press Escape to release"
    else
        "not grabbed - click Grab, then move and type";
    const l0 = std.fmt.bufPrint(&app.lines[0], "status: {s}", .{status}) catch "";
    const l1 = std.fmt.bufPrint(&app.lines[1], "last key: scancode={d} down={}", .{
        app.last_scancode, app.last_down,
    }) catch "";
    const l2 = std.fmt.bufPrint(&app.lines[2], "keys={d}  moves={d}", .{
        app.keys, app.moves,
    }) catch "";
    const l3 = std.fmt.bufPrint(&app.lines[3], "mouse delta: x={d:.0} y={d:.0}", .{
        app.dx, app.dy,
    }) catch "";
    const l4 = std.fmt.bufPrint(&app.lines[4], "buttons L={} R={} M={} events={d} last={s}", .{
        app.btn_left,
        app.btn_right,
        app.btn_middle,
        app.btn_events,
        app.last_btn,
    }) catch "";
    const l5 = std.fmt.bufPrint(&app.lines[5], "wheel={d:.0}", .{app.wheel}) catch "";

    return zigui.col(.{ .pad = .lg, .gap = .sm, .grow = 1 }, &.{
        zigui.text(l0, .{ .size = 16 }),
        zigui.text(l1, .{ .size = 14 }),
        zigui.text(l2, .{ .size = 14 }),
        zigui.text(l3, .{ .size = 14 }),
        zigui.text(l4, .{ .size = 14 }),
        zigui.text(l5, .{ .size = 14 }),
        zigui.button("Grab", .{ .on_click = zigui.on(App, App.enter_grab) }),
    });
}
