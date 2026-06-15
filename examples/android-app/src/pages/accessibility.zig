const zigui = @import("zigui");
const Node = zigui.Node;
const Frame = zigui.Frame;
const App = @import("../app.zig").App;
const page = @import("../scaffold/page.zig");

pub fn open(app: *App) void {
    app.nav.push("a11y", "Accessibility");
}

fn do_enable(app: *App) void {
    _ = app;
    zigui.napi.accessibility.request_enable();
}
fn do_home(app: *App) void {
    _ = app;
    zigui.napi.accessibility.global_action(.home);
}
// Inject a swipe-up into the foreground (here, the app's own scroll list).
fn do_swipe(app: *App) void {
    _ = app;
    zigui.napi.accessibility.swipe(160, 470, 160, 180, 250);
}
// Read the foreground node tree into the page's buffer.
fn do_read(app: *App) void {
    if (zigui.napi.accessibility.read(&app.a11y_read)) |tree| {
        app.a11y_read_len = tree.len;
    }
}
// Subscribe to window-change + notification events; the service then forwards them.
fn do_events(app: *App) void {
    _ = app;
    zigui.napi.accessibility.subscribe_event(.window_state_changed);
    zigui.napi.accessibility.subscribe_event(.notification_state_changed);
}

// The accessibility-service control surface. Enable opens system settings (a service
// is user-enabled, never programmatic); once on, the global actions + the injected
// swipe + the screen-read all run through zigui's shipped bound service. The inject
// hits whatever is foreground - here, the app's own scroll list.
pub fn view(f: *Frame, app: *App) *Node {
    _ = f;
    const on = zigui.napi.accessibility.enabled();
    const status = if (on) "Service: enabled" else "Service: disabled";
    const tree = app.a11y_read[0..app.a11y_read_len];
    const read_note = if (app.a11y_read_len > 0) tree else "(no read yet)";
    const ev = app.a11y_event[0..app.a11y_event_len];
    const ev_note = if (app.a11y_event_len > 0) ev else "(no event yet)";
    return page.screen(&.{
        page.header("Accessibility."),
        page.status(status),
        zigui.button("Enable service", .{ .on_click = zigui.on(App, do_enable) }),
        zigui.button("Home action", .{ .on_click = zigui.on(App, do_home) }),
        zigui.button("Inject swipe", .{ .on_click = zigui.on(App, do_swipe) }),
        zigui.button("Read screen", .{ .on_click = zigui.on(App, do_read) }),
        page.note(read_note),
        zigui.button("Subscribe events", .{ .on_click = zigui.on(App, do_events) }),
        page.note(ev_note),
    });
}
