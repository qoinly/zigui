// A real kit UI driven through the public App.init/run, the same API the desktop
// examples use. zigui's Android backend exports ANativeActivity_onCreate, which
// calls this main() (the @import("root").main bridge), then builds the surface and
// runs the App.render / overlay / hud views through the real renderer + paint loop.
//
// One shape difference from desktop: App.run returns immediately on Android (the
// framework owns the loop), so the state must outlive main() - a container-scoped
// var, not a stack local. No defer app.deinit() for the same reason: the loop keeps
// running after main() returns.
const zigui = @import("zigui");
const app = @import("app.zig");
const App = app.App;

var state: App = .{};

pub fn main() !void {
    var window = try zigui.App.init(.{ .title = "zigui", .size = .{ 400, 800 } });
    try window.run(&state, .{
        .body = App.render,
        .overlay = app.overlay_view,
        .hud = app.hud_view,
    });
}

// The NativeActivity entry export emits only when the compilation root keeps it
// reachable; a comptime reference to zigui.App pulls the backend (and its exported
// ANativeActivity_onCreate, plus the JNI bridge symbols the shipped
// io.qoinly.zigui.ZiguiActivity resolves against) into the .so. A runtime use inside
// main() alone does not, so the framework would otherwise miss the entry.
comptime {
    _ = zigui.App;
}
