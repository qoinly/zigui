const std = @import("std");
const zigui = @import("zigui");
const Node = zigui.Node;
const Frame = zigui.Frame;
const App = @import("../app.zig").App;
const tooltip_page = @import("../pages/tooltip.zig");

// The non-modal top layer: floating toasts (fired from any page) + the tooltip
// page's hover hint. Never freezes the body. Toasts take the layer when any is
// live; the tooltip page has no toast trigger, so they never contend in practice.
pub fn view(f: *Frame, app: *App) ?*Node {
    for (app.toasts) |s| {
        if (s.active) return zigui.toasts(.{ .slots = &app.toasts });
    }
    if (std.mem.eql(u8, app.nav.selected_id, "tooltip")) return tooltip_page.hud(f, app);
    return null;
}
