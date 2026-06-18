const std = @import("std");
const zigui = @import("zigui");
const Node = zigui.Node;
const Frame = zigui.Frame;
const App = @import("app.zig").App;
const home = @import("pages/home.zig");
const detail = @import("pages/detail.zig");
const frame_page = @import("pages/frame.zig");
const native = @import("pages/native.zig");
const accessibility = @import("pages/accessibility.zig");
const notif = @import("pages/notif.zig");
const broadcasts = @import("pages/broadcasts.zig");
const kit = @import("pages/kit.zig");
const background = @import("pages/background.zig");
const headless = @import("pages/headless.zig");
const permissions = @import("pages/permissions.zig");

// Dispatch by the nav stack's current route; nav_page calls this (twice during a
// slide, once otherwise). An unknown route falls through to the home root.
pub fn dispatch(f: *Frame, app: *App, route: []const u8) *Node {
    const eql = std.mem.eql;
    if (eql(u8, route, "detail")) return detail.view(f, app);
    if (eql(u8, route, "frame")) return frame_page.view(f, app);
    if (eql(u8, route, "native")) return native.view(f, app);
    if (eql(u8, route, "a11y")) return accessibility.view(f, app);
    if (eql(u8, route, "notif")) return notif.view(f, app);
    if (eql(u8, route, "bc")) return broadcasts.view(f, app);
    if (eql(u8, route, "kit")) return kit.view(f, app);
    if (eql(u8, route, "work")) return background.view(f, app);
    if (eql(u8, route, "headless")) return headless.view(f, app);
    if (eql(u8, route, "perms")) return permissions.view(f, app);
    return home.view(f, app);
}
