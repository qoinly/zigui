const std = @import("std");
const zigui = @import("zigui");
const Node = zigui.Node;
const Frame = zigui.Frame;
const App = @import("../app.zig").App;
const page = @import("../scaffold/page.zig");

// A manifest declares few runtime permissions; cap the list and its name backing.
const MAX_PERMS = 32;
const NAME_BYTES = 1024;

pub fn open(app: *App) void {
    app.nav.push("perms", "Permissions");
}

// Request the first permission that a request would still move (never-asked or
// askable-denied), one system dialog per tap. Granted and permanently-denied ones
// are skipped - the latter only Settings can grant.
fn do_request_next(app: *App) void {
    _ = app;
    var names: [MAX_PERMS][]const u8 = undefined;
    var scratch: [NAME_BYTES]u8 = undefined;
    for (zigui.napi.permissions.declared(&names, &scratch)) |p| {
        switch (zigui.napi.permissions.status(p)) {
            .not_requested, .declined => {
                zigui.napi.permissions.request(p);
                return;
            },
            else => {},
        }
    }
}

// The manifest's permissions, read at runtime, each with its live four-state. Proves
// the screen drives off the manifest: no permission string is hardcoded here.
pub fn view(f: *Frame, app: *App) *Node {
    _ = app;
    const names = f.arena.alloc([]const u8, MAX_PERMS) catch return empty();
    const scratch = f.arena.alloc(u8, NAME_BYTES) catch return empty();
    const perms = zigui.napi.permissions.declared(names, scratch);

    var rows: []const *Node = &.{};
    if (f.arena.alloc(*Node, perms.len)) |slice| {
        for (slice, perms) |*r, p| r.* = perm_row(f, p);
        rows = slice;
    } else |_| {}

    return page.screen(&.{
        page.header("Permissions."),
        page.note("Declared in the manifest, read at runtime - no hardcoded names."),
        zigui.col(.{ .gap = .sm }, rows),
        zigui.button("Request next pending", .{ .on_click = zigui.on(App, do_request_next) }),
    });
}

fn empty() *Node {
    return page.screen(&.{page.header("Permissions.")});
}

// "android.permission.CAMERA  -  not requested". The name and state borrow the frame
// arena, valid for this frame only.
fn perm_row(f: *Frame, name: []const u8) *Node {
    const short = short_name(name);
    const state = switch (zigui.napi.permissions.status(name)) {
        .granted => "granted",
        .not_requested => "not requested",
        .declined => "declined",
        .declined_permanent => "declined (don't ask again)",
    };
    const buf = f.arena.alloc(u8, 96) catch return zigui.text(short, .{ .size = 14 });
    const line = std.fmt.bufPrint(buf, "{s}  -  {s}", .{ short, state }) catch short;
    return zigui.text(line, .{ .size = 14 });
}

// Drops the "android.permission." prefix for a compact row.
fn short_name(name: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| return name[dot + 1 ..];
    return name;
}
