// A real kit UI driven through the public App.init/run, the same API the desktop
// examples use. zigui's Android backend exports ANativeActivity_onCreate, which
// calls this main() (the @import("root").main bridge), then builds the surface
// and runs this render() through the real renderer + paint loop.
//
// One shape difference from desktop: App.run returns immediately on Android (the
// framework owns the loop), so the state must outlive main() - a container-scoped
// var, not a stack local. No defer app.deinit() for the same reason: the loop
// keeps running after main() returns.
const zigui = @import("zigui");

const Counter = struct {
    clicks: u32 = 0,
};

var state: Counter = .{};

pub fn main() !void {
    var app = try zigui.App.init(.{ .title = "zigui", .size = .{ 400, 800 } });
    try app.run(&state, .{ .body = render });
}

fn render(f: *zigui.Frame, counter: *Counter) *zigui.Node {
    _ = f;
    _ = counter;
    return zigui.col(.{ .pad = .lg, .gap = .md }, &.{
        zigui.text("Hello, Android.", .{ .size = 28 }),
        zigui.button("Tap me", .{ .on_click = zigui.on(Counter, on_click) }),
    });
}

fn on_click(counter: *Counter) void {
    counter.clicks += 1;
}

// The NativeActivity entry export emits only when the compilation root keeps it
// reachable; a comptime reference to zigui.App pulls the backend (and its
// exported ANativeActivity_onCreate) into the .so. A runtime use inside main()
// alone does not, so the framework would otherwise fail to find the entry symbol.
comptime {
    _ = zigui.App;
}
