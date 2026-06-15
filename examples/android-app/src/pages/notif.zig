const zigui = @import("zigui");
const Node = zigui.Node;
const Frame = zigui.Frame;
const App = @import("../app.zig").App;
const page = @import("../scaffold/page.zig");

pub fn open(app: *App) void {
    app.nav.push("notif", "Notif Listener");
}

fn do_enable(app: *App) void {
    _ = app;
    zigui.napi.notification_listener.request_enable();
}
// Post a notification so the enabled listener catches it (a self-contained loop).
fn do_post(app: *App) void {
    _ = app;
    zigui.napi.notifications.post("zigui", "hello from the listener demo");
}

// The notification-listener surface. Enable opens notification-access settings; once
// on, zigui's shipped listener forwards every posted notification to native, and
// "Post test notif" makes the app notify itself so the catch shows up in "Latest".
pub fn view(f: *Frame, app: *App) *Node {
    _ = f;
    const on = zigui.napi.notification_listener.enabled();
    const status = if (on) "Listener: enabled" else "Listener: disabled";
    const caught = app.notif[0..app.notif_len];
    const latest = if (app.notif_len > 0) caught else "(none caught yet)";
    return page.screen(&.{
        page.header("Notification listener."),
        page.status(status),
        zigui.button("Enable listener", .{ .on_click = zigui.on(App, do_enable) }),
        zigui.button("Post test notif", .{ .on_click = zigui.on(App, do_post) }),
        zigui.text("Latest:", .{ .size = 14 }),
        page.note(latest),
    });
}
