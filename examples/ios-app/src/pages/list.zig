const std = @import("std");
const zigui = @import("zigui");
const Node = zigui.Node;
const Frame = zigui.Frame;
const App = @import("../app.zig").App;
const page = @import("../scaffold/page.zig");

// Enough rows to overflow the screen so the list drag-scrolls (with iOS momentum
// and a rubber-band edge).
const LIST_ROWS = 40;

pub fn open(app: *App) void {
    app.nav.push("list", "Scrolling list");
}

pub fn view(f: *Frame, app: *App) *Node {
    const rows = f.arena.alloc(*Node, LIST_ROWS) catch return page.header("out of memory");
    for (rows, 0..) |*r, i| {
        const label = std.fmt.allocPrint(f.arena, "row {d}", .{i}) catch "row";
        r.* = zigui.text(label, .{ .size = 20 });
    }
    // The engine resolves a scroll's basis from its content, so a grow scroll in a
    // column inflates past the viewport and never clips. Pin the viewport to the body
    // below the app bar instead, so it clips and drag-scrolls.
    const h = @max(0, f.body.size.height - zigui.app_bar_height);
    return zigui.scroll(&app.list, .{ .height = h }, zigui.col(.{ .pad = .lg, .gap = .md }, rows));
}
