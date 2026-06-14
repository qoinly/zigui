// The cross-platform navigator on the desktop: the same NavStack + app_bar the
// mobile shell uses, with Esc standing in for the Android Back button. The home
// page pushes a detail route WITH a payload (startActivity extras); the detail page
// reads it, and a "Save" button stages a result that pop hands back (setResult).
// The app-bar grows a back-chevron at depth > 1; Esc / the chevron pop it.
const std = @import("std");
const zigui = @import("zigui");

const App = struct {
    // The last result a detail page returned, copied out of the stack on the frame
    // the pop delivered it (take_result yields it once, the slice is borrowed).
    last_result: [64]u8 = undefined,
    last_result_len: usize = 0,
};

var nav: zigui.NavStack = .{};

pub fn main() !void {
    var state: App = .{};
    var app = try zigui.App.init(.{ .title = "Navigator", .size = .{ 480, 720 } });
    defer app.deinit();
    try app.run(&state, .{ .body = render });
}

fn render(f: *zigui.Frame, app: *App) *zigui.Node {
    if (nav.depth == 0) nav.go("home", "Home"); // seed the root once
    zigui.handle_back(&nav); // Esc / the chevron -> pop
    if (nav.take_result()) |r| { // a detail page returned a result: keep it
        const n = @min(r.len, app.last_result.len);
        @memcpy(app.last_result[0..n], r[0..n]);
        app.last_result_len = n;
    }

    const route = nav.current();
    const page = if (std.mem.eql(u8, route, "detail"))
        detail_page(f)
    else
        home_page(f, app);

    return zigui.col(.{}, &.{
        zigui.app_bar(nav.current_title(), .{ .show_back = nav.depth > 1 }),
        page,
    });
}

fn home_page(f: *zigui.Frame, app: *App) *zigui.Node {
    _ = f;
    const returned = app.last_result[0..app.last_result_len];
    const note = if (app.last_result_len > 0) returned else "(no result yet)";
    return zigui.col(.{ .pad = .lg, .gap = .md, .grow = 1 }, &.{
        zigui.text("Home page.", .{ .size = 28 }),
        zigui.button("Open details", .{ .on_click = zigui.on(App, open_detail) }),
        zigui.text("Returned from detail:", .{ .size = 14 }),
        zigui.text(note, .{ .size = 16 }),
    });
}

fn detail_page(f: *zigui.Frame) *zigui.Node {
    _ = f;
    return zigui.col(.{ .pad = .lg, .gap = .md, .grow = 1 }, &.{
        zigui.text("Detail page.", .{ .size = 28 }),
        zigui.text("Got args:", .{ .size = 14 }),
        zigui.text(nav.current_args(), .{ .size = 16 }),
        zigui.button("Save & back", .{ .on_click = zigui.on(App, save_and_back) }),
        zigui.text("(or Esc to return with no result)", .{ .size = 14 }),
    });
}

// startActivity with extras: hand the detail page a payload to read.
fn open_detail(app: *App) void {
    _ = app;
    nav.push_with("detail", "Details", "hello from home");
}

// setResult + finish: stage a result, then pop so it reaches the home page.
fn save_and_back(app: *App) void {
    _ = app;
    nav.set_result("saved at 42");
    nav.pop();
}
