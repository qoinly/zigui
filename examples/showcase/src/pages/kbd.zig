const zigui = @import("zigui");
const Node = zigui.Node;
const Frame = zigui.Frame;
const App = @import("../app.zig").App;
const page = @import("../scaffold/page.zig");

pub fn view(f: *Frame, app: *App) *Node {
    _ = app;
    const t = f.theme;
    return page.page(&.{
        page.header("Kbd", "Keyboard keys and shortcuts."),
        page.section(t, "Keys", &.{
            zigui.kbd(&.{zigui.key_command}),
            zigui.kbd(&.{zigui.key_shift}),
            zigui.kbd(&.{zigui.key_option}),
            zigui.kbd(&.{"Esc"}),
        }),
        page.section(t, "Shortcuts", &.{
            zigui.kbd(&.{ zigui.key_command, "K" }),
            zigui.kbd(&.{ zigui.key_command, zigui.key_shift, "P" }),
            zigui.kbd(&.{ zigui.key_command, "S" }),
        }),
    });
}
