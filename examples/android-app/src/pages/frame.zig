const zigui = @import("zigui");
const Node = zigui.Node;
const Frame = zigui.Frame;
const App = @import("../app.zig").App;
const page = @import("../scaffold/page.zig");
const ahb = @import("../ahb.zig");

// Push the zero-copy frame page (an AHardwareBuffer imported with no copy).
pub fn open(app: *App) void {
    app.nav.push("frame", "Frame");
}

// A synthesized YUV AHardwareBuffer imported with no copy and sampled through the
// renderer's ycbcr pipeline.
pub fn view(f: *Frame, app: *App) *Node {
    _ = f;
    _ = app;
    return page.screen(&.{
        page.header("AHardwareBuffer (zero-copy NV12)."),
        ahb.frame_node(),
    });
}
