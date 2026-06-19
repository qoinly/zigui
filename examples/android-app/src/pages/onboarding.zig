const zigui = @import("zigui");
const Node = zigui.Node;
const Frame = zigui.Frame;
const App = @import("../app.zig").App;

pub fn open(app: *App) void {
    app.onboarding.index = 0;
    app.nav.push("splash", "Onboarding");
}
fn leave(app: *App) void {
    app.nav.go("home", "Home"); // skip / finish: reset to the home root
}

// The full-screen onboarding carousel (no app-bar): swipe or Next across the slides,
// Skip / Finish leave it. app.render routes the "splash" route here.
pub fn view(f: *Frame, app: *App) *Node {
    return zigui.carousel(f, App, &app.onboarding, app, .{
        .count = 3,
        .on_skip = zigui.on(App, leave),
        .on_finish = zigui.on(App, leave),
    }, slide);
}

// One slide; the carousel calls this for each i in 0..count.
fn slide(f: *Frame, app: *App, i: usize) *Node {
    _ = f;
    _ = app;
    const titles = [_][]const u8{ "Welcome to zigui", "GPU-rendered", "One kit, every platform" };
    const bodies = [_][]const u8{
        "A Zig immediate-mode GUI toolkit.",
        "Vulkan / Metal / D3D11 - blazing fast.",
        "Desktop and Android from the same code.",
    };
    return zigui.col(.{
        .pad = .lg,
        .gap = .md,
        .grow = 1,
        .justify = .center,
        .cross = .center,
    }, &.{
        zigui.text(titles[i], .{ .size = 26, .weight = .semi_bold }),
        zigui.text(bodies[i], .{ .size = 15, .muted = true }),
    });
}
