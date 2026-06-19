const std = @import("std");
const zigui = @import("zigui");
const Node = zigui.Node;
const Frame = zigui.Frame;
const App = @import("../app.zig").App;
const page = @import("../scaffold/page.zig");

const CAMERA = "android.permission.CAMERA";

// Push the native-API page.
pub fn open(app: *App) void {
    app.nav.push("native", "Native APIs");
}

fn do_vibrate(app: *App) void {
    _ = app;
    zigui.napi.haptics.vibrate(40);
}
fn do_open_url(app: *App) void {
    _ = app;
    zigui.napi.links.open_url("https://ziglang.org");
}
fn do_share(app: *App) void {
    _ = app;
    zigui.napi.links.share_text("shared from zigui");
}
fn do_notify(app: *App) void {
    _ = app;
    zigui.napi.notifications.post("zigui", "hello from the native api demo");
}
fn do_toast(app: *App) void {
    _ = app;
    zigui.napi.notifications.toast("toast from zigui");
}
// Round-trips the clipboard: write, then read it back into the result buffer.
fn do_clipboard(app: *App) void {
    zigui.napi.clipboard.write("copied by zigui");
    const got = zigui.napi.clipboard.read(&app.last_result);
    app.last_result_len = got.len;
}
// Cycle auto -> portrait -> landscape -> auto, applied next frame.
fn cycle_orientation(app: *App) void {
    app.orient = switch (app.orient) {
        .auto => .portrait,
        .portrait => .landscape,
        else => .auto,
    };
    zigui.napi.display.orientation(app.orient);
}
fn toggle_brightness(app: *App) void {
    app.bright = !app.bright;
    zigui.napi.display.brightness(if (app.bright) 1.0 else -1.0); // -1 = system default
}
fn do_biometric(app: *App) void {
    _ = app;
    zigui.napi.biometric.authenticate("Sign in", "Confirm it's you");
}
fn do_request_camera(app: *App) void {
    _ = app;
    if (!zigui.napi.permissions.granted(CAMERA)) zigui.napi.permissions.request(CAMERA);
}
fn do_pick_file(app: *App) void {
    _ = app;
    zigui.napi.picker.open_file();
}

// The native services, each one tap. Clipboard round-trips into the note; the picked
// file's text and the camera-permission state show their result inline.
pub fn view(f: *Frame, app: *App) *Node {
    const clip = app.last_result[0..app.last_result_len];
    const note = if (app.last_result_len > 0) clip else "(clipboard empty)";
    const file = app.file_preview[0..app.file_preview_len];
    const file_note = if (app.file_preview_len > 0) file else "(no file picked)";
    const cam = switch (zigui.napi.permissions.status(CAMERA)) {
        .granted => "Camera: granted",
        .not_requested => "Camera: not requested",
        .declined => "Camera: declined",
        .declined_permanent => "Camera: declined (enable in Settings)",
    };
    const auth = if (app.auth_done) |ok|
        (if (ok) "Auth: success" else "Auth: failed")
    else
        "Auth: (none)";
    return page.screen(&.{
        page.header("Native APIs."),
        zigui.button("Vibrate", .{ .on_click = zigui.on(App, do_vibrate) }),
        zigui.button("Open URL", .{ .on_click = zigui.on(App, do_open_url) }),
        zigui.button("Share text", .{ .on_click = zigui.on(App, do_share) }),
        zigui.button("Notify", .{ .on_click = zigui.on(App, do_notify) }),
        zigui.button("Toast", .{ .on_click = zigui.on(App, do_toast) }),
        zigui.button("Copy + paste", .{ .on_click = zigui.on(App, do_clipboard) }),
        page.status(note),
        zigui.button("Rotate", .{ .on_click = zigui.on(App, cycle_orientation) }),
        zigui.button("Brightness", .{ .on_click = zigui.on(App, toggle_brightness) }),
        page.status(device_status(f)),
        zigui.button("Authenticate", .{ .on_click = zigui.on(App, do_biometric) }),
        page.status(auth),
        zigui.button("Request camera", .{ .on_click = zigui.on(App, do_request_camera) }),
        page.status(cam),
        zigui.button("Pick file", .{ .on_click = zigui.on(App, do_pick_file) }),
        zigui.text(file_note, .{ .size = 14 }),
    });
}

// Battery + connectivity, polled each frame and formatted into the arena (which the
// node borrows for the frame). A format failure falls back to a static label.
fn device_status(f: *Frame) []const u8 {
    const buf = f.arena.alloc(u8, 64) catch return "Battery/Net: n/a";
    const level = zigui.napi.device.battery_level();
    const charge = if (zigui.napi.device.charging()) "+" else "";
    const net = switch (zigui.napi.device.network()) {
        .none => "offline",
        .wifi => "wifi",
        .cellular => "cellular",
        .other => "other",
    };
    const out = std.fmt.bufPrint(buf, "Battery: {d}%{s}  Net: {s}", .{ level, charge, net });
    return out catch "Battery/Net: n/a";
}
