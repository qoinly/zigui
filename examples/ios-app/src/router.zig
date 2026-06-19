const std = @import("std");
const zigui = @import("zigui");
const Node = zigui.Node;
const Frame = zigui.Frame;
const App = @import("app.zig").App;
const home = @import("pages/home.zig");
const controls = @import("pages/controls.zig");
const list = @import("pages/list.zig");
const detail = @import("pages/detail.zig");

// Dispatch by the nav stack's current route; nav_page calls this (twice during a
// slide, once otherwise). An unknown route falls through to the home root.
pub fn dispatch(f: *Frame, app: *App, route: []const u8) *Node {
    const eql = std.mem.eql;
    if (eql(u8, route, "controls")) return controls.view(f, app);
    if (eql(u8, route, "list")) return list.view(f, app);
    if (eql(u8, route, "detail")) return detail.view(f, app);
    return home.view(f, app);
}
