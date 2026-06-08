const zigui = @import("zigui");
const Node = zigui.Node;
const Frame = zigui.Frame;
const App = @import("../app.zig").App;
const page = @import("../scaffold/page.zig");

pub fn view(f: *Frame, app: *App) *Node {
    return page.page(&.{
        page.header("Tooltip", "A hint shown on hover."),
        page.section(f.theme, "Hover", &.{
            // No on_click: a hover-only target. rect_out anchors the hud bubble.
            zigui.button("Hover me", .{ .variant = .outline, .rect_out = &app.tip.rect }),
        }),
    });
}

// The hover hint, rendered in the non-modal hud region so the trigger stays
// hoverable. Self-gates: the node draws only while the trigger rect is hovered.
pub fn hud(f: *Frame, app: *App) ?*Node {
    _ = f;
    return zigui.tooltip_overlay(.{
        .text = "Add to library",
        .trigger = &app.tip.rect,
    });
}
