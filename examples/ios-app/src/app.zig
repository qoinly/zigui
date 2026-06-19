const zigui = @import("zigui");
const Node = zigui.Node;
const Frame = zigui.Frame;
const router = @import("router.zig");

// The whole app state; the view is a pure function of it, handlers mutate it. The
// nav stack + the per-page widget state (scroll list, shared text editor) keep a
// stable address because App lives container-scoped, so pages back-point into them.
pub const App = struct {
    nav: zigui.NavStack = .{},
    list: zigui.ScrollState = .{},
    field: zigui.TextField = .{},
    focus: u32 = 0, // id of the focused text field, 0 = none
    clicks: u32 = 0,

    pub fn render(f: *Frame, app: *App) *Node {
        if (app.nav.depth == 0) app.nav.go("home", "zigui on iOS"); // seed the root once
        zigui.handle_back(&app.nav); // the app-bar chevron / Esc pops
        // nav_page renders the current route (sliding the two during a push/pop).
        const page = zigui.nav_page(f, App, &app.nav, app, router.dispatch);
        return zigui.col(.{}, &.{
            zigui.app_bar(app.nav.current_title(), .{ .show_back = app.nav.depth > 1 }),
            page,
        });
    }
};
