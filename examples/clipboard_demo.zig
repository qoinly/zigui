const std = @import("std");
const zigui = @import("zigui");

// Shows the clipboard change-notify path: copy something in another app and the
// external-change counter ticks and the text updates; clicking "Write own" sets the
// clipboard from here and does NOT count as an external change (no echo loop).
const App = struct {
    ext_changes: u32 = 0,
    text_len: usize = 0,
    text_buf: [256]u8 = undefined,
    want_write: bool = false,
    lines: [2][320]u8 = undefined,

    fn write_own(self: *App) void {
        self.want_write = true;
    }
};

pub fn main() !void {
    var state: App = .{};
    var app = try zigui.App.init(.{ .title = "Clipboard demo", .size = .{ 640, 360 } });
    defer app.deinit();
    try app.run(&state, .{ .body = render });
}

fn render(f: *zigui.Frame, app: *App) *zigui.Node {
    _ = f;
    if (zigui.clipboard_changed()) {
        app.ext_changes += 1;
        app.text_len = zigui.clipboard_text(&app.text_buf).len;
    }
    if (app.want_write) {
        zigui.set_clipboard_text("zigui wrote this");
        app.want_write = false;
    }
    zigui.animate(); // poll the clipboard every frame

    const l0 = std.fmt.bufPrint(&app.lines[0], "external changes: {d}", .{
        app.ext_changes,
    }) catch "";
    const l1 = std.fmt.bufPrint(&app.lines[1], "clipboard: {s}", .{
        app.text_buf[0..app.text_len],
    }) catch "";

    return zigui.col(.{ .pad = .lg, .gap = .md, .grow = 1 }, &.{
        zigui.text("copy text elsewhere, watch below; Write own must not count", .{ .size = 15 }),
        zigui.text(l0, .{ .size = 16 }),
        zigui.text(l1, .{ .size = 16 }),
        zigui.button("Write own", .{ .on_click = zigui.on(App, App.write_own) }),
    });
}
