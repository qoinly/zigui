// A real kit UI driven through the public App.init/run, the same API the desktop
// examples use. zigui's Android backend exports ANativeActivity_onCreate, which
// calls this main() (the @import("root").main bridge), then builds the surface
// and runs this render() through the real renderer + paint loop.
//
// One shape difference from desktop: App.run returns immediately on Android (the
// framework owns the loop), so the state must outlive main() - a container-scoped
// var, not a stack local. No defer app.deinit() for the same reason: the loop
// keeps running after main() returns.
const std = @import("std");
const zigui = @import("zigui");
const ahb = @import("ahb.zig");

const Counter = struct {
    clicks: u32 = 0,
    focus: u32 = 0, // id of the focused text field, 0 = none
    awake: bool = false, // FLAG_KEEP_SCREEN_ON while true
    immersive: bool = false, // system bars hidden while true
    bright: bool = false, // screen forced to full brightness while true
    orient: zigui.napi.display.Orientation = .auto, // current orientation lock
    auth_done: ?bool = null, // last biometric outcome: null none, true ok, false failed
    // The last result a detail page returned, copied out of the stack on the frame
    // the pop delivered it (take_result yields it once, the slice is borrowed).
    last_result: [64]u8 = undefined,
    last_result_len: usize = 0,
    // A preview of the picked document's text, kept across frames (take_picked_file
    // yields it once, like the route result).
    file_preview: [256]u8 = undefined,
    file_preview_len: usize = 0,
    // The last accessibility screen-read, kept across frames (read() borrows the buffer
    // it fills, so copy it out for the page to show).
    a11y_read: [256]u8 = undefined,
    a11y_read_len: usize = 0,
    // The last subscribed accessibility event, "type\tpackage\ttext", kept across frames.
    a11y_event: [256]u8 = undefined,
    a11y_event_len: usize = 0,
    // The last notification the listener caught, kept across frames (take() borrows
    // the buffer it fills).
    notif: [256]u8 = undefined,
    notif_len: usize = 0,
    // The last broadcast received, "action\tpayload", kept across frames.
    bc: [256]u8 = undefined,
    bc_len: usize = 0,
    // The inbox read-out, "address\tbody\n...", kept across frames (read() borrows
    // the buffer it fills).
    sms: [256]u8 = undefined,
    sms_len: usize = 0,
    // Kit overlay widgets (rendered by the kit, not native): a modal dialog, an eased
    // edge sheet, and an in-app toast stack.
    dialog_open: bool = false,
    sheet_open: bool = false,
    sheet_t: f32 = 0, // caller-eased sheet slide progress 0..1
    toasts: [3]zigui.ToastSlot = .{ .{}, .{}, .{} },
};

const CAMERA = "android.permission.CAMERA";
const RECEIVE_SMS = "android.permission.RECEIVE_SMS";
const READ_SMS = "android.permission.READ_SMS";
const SEND_SMS = "android.permission.SEND_SMS";

fn do_pick_file(c: *Counter) void {
    _ = c;
    zigui.napi.picker.open_file();
}
fn do_request_camera(c: *Counter) void {
    _ = c;
    if (!zigui.napi.permissions.granted(CAMERA)) zigui.napi.permissions.request(CAMERA);
}

fn toggle_awake(c: *Counter) void {
    c.awake = !c.awake;
}
fn toggle_immersive(c: *Counter) void {
    c.immersive = !c.immersive;
}

var state: Counter = .{};
var nav: zigui.NavStack = .{};
var list_scroll: zigui.ScrollState = .{};
var field: zigui.TextField = .{};

fn focus_field(c: *Counter) void {
    c.focus = 1;
}
fn blur_fields(c: *Counter) void {
    c.focus = 0;
}

// startActivity with extras: push the detail page carrying a payload it reads back.
fn open_detail(c: *Counter) void {
    _ = c;
    nav.push_with("detail", "Details", "hello from home");
}

// setResult + finish: stage a result, then pop so the home page receives it.
fn save_and_back(c: *Counter) void {
    _ = c;
    nav.set_result("saved at 42");
    nav.pop();
}

// Push the zero-copy frame page (an AHardwareBuffer imported with no copy).
fn open_frame(c: *Counter) void {
    _ = c;
    nav.push("frame", "Frame");
}

// Push the native-API page.
fn open_native(c: *Counter) void {
    _ = c;
    nav.push("native", "Native APIs");
}

fn do_vibrate(c: *Counter) void {
    _ = c;
    zigui.napi.haptics.vibrate(40);
}
fn do_open_url(c: *Counter) void {
    _ = c;
    zigui.napi.links.open_url("https://ziglang.org");
}
fn do_share(c: *Counter) void {
    _ = c;
    zigui.napi.links.share_text("shared from zigui");
}
fn do_notify(c: *Counter) void {
    _ = c;
    zigui.napi.notifications.post("zigui", "hello from the native api demo");
}
// Round-trips the clipboard: write, then read it back into the result buffer.
fn do_clipboard(c: *Counter) void {
    zigui.napi.clipboard.write("copied by zigui");
    const got = zigui.napi.clipboard.read(&c.last_result);
    c.last_result_len = got.len;
}
fn do_toast(c: *Counter) void {
    _ = c;
    zigui.napi.notifications.toast("toast from zigui");
}
// Cycle auto -> portrait -> landscape -> auto, applied next frame.
fn cycle_orientation(c: *Counter) void {
    c.orient = switch (c.orient) {
        .auto => .portrait,
        .portrait => .landscape,
        else => .auto,
    };
    zigui.napi.display.orientation(c.orient);
}
fn toggle_brightness(c: *Counter) void {
    c.bright = !c.bright;
    zigui.napi.display.brightness(if (c.bright) 1.0 else -1.0); // -1 = system default
}
fn do_biometric(c: *Counter) void {
    _ = c;
    zigui.napi.biometric.authenticate("Sign in", "Confirm it's you");
}

fn open_a11y(c: *Counter) void {
    _ = c;
    nav.push("a11y", "Accessibility");
}
fn do_a11y_enable(c: *Counter) void {
    _ = c;
    zigui.napi.accessibility.request_enable();
}
fn do_a11y_home(c: *Counter) void {
    _ = c;
    zigui.napi.accessibility.global_action(.home);
}
// Inject a swipe-up into the foreground (here, the app's own scroll list).
fn do_a11y_swipe(c: *Counter) void {
    _ = c;
    zigui.napi.accessibility.swipe(160, 470, 160, 180, 250);
}
// Read the foreground node tree into the page's buffer.
fn do_a11y_read(c: *Counter) void {
    if (zigui.napi.accessibility.read(&c.a11y_read)) |tree| {
        c.a11y_read_len = tree.len;
    }
}
// Subscribe to window-change + notification events; the service then forwards them.
fn do_a11y_events(c: *Counter) void {
    _ = c;
    zigui.napi.accessibility.subscribe_event(.window_state_changed);
    zigui.napi.accessibility.subscribe_event(.notification_state_changed);
}

fn open_notif(c: *Counter) void {
    _ = c;
    nav.push("notif", "Notif Listener");
}
fn do_notif_enable(c: *Counter) void {
    _ = c;
    zigui.napi.notification_listener.request_enable();
}
// Post a notification so the enabled listener catches it (a self-contained loop).
fn do_notif_post(c: *Counter) void {
    _ = c;
    zigui.napi.notifications.post("zigui", "hello from the listener demo");
}

fn open_bc(c: *Counter) void {
    _ = c;
    nav.push("bc", "Broadcasts");
}
// Subscribe to a system broadcast (screen on/off, no payload) and SMS (decoded
// payload, needs the runtime RECEIVE_SMS permission).
fn do_bc_subscribe(c: *Counter) void {
    _ = c;
    if (!zigui.napi.permissions.granted(RECEIVE_SMS)) zigui.napi.permissions.request(RECEIVE_SMS);
    zigui.napi.broadcast.subscribe("android.intent.action.SCREEN_ON");
    zigui.napi.broadcast.subscribe("android.intent.action.SCREEN_OFF");
    zigui.napi.broadcast.subscribe("android.provider.Telephony.SMS_RECEIVED");
}
// Read the SMS inbox into the page buffer (READ_SMS, distinct from RECEIVE_SMS).
fn do_sms_read(c: *Counter) void {
    if (!zigui.napi.permissions.granted(READ_SMS)) {
        zigui.napi.permissions.request(READ_SMS);
        return;
    }
    if (zigui.napi.sms.read(&c.sms)) |inbox| c.sms_len = inbox.len;
}
// Send an SMS to the emulator's own number so it loops back to the inbox (SEND_SMS).
fn do_sms_send(c: *Counter) void {
    _ = c;
    if (!zigui.napi.permissions.granted(SEND_SMS)) {
        zigui.napi.permissions.request(SEND_SMS);
        return;
    }
    zigui.napi.sms.send("5555215554", "hello from zigui sms send");
}

fn open_kit(c: *Counter) void {
    _ = c;
    nav.push("kit", "Kit UI");
}
fn open_dialog(c: *Counter) void {
    c.dialog_open = true;
}
fn dialog_close(c: *Counter) void {
    c.dialog_open = false;
}
fn dialog_confirm(c: *Counter) void {
    c.dialog_open = false;
    push_toast(c, "Confirmed", .success);
}
fn open_sheet(c: *Counter) void {
    c.sheet_open = true;
}
fn sheet_close(c: *Counter) void {
    c.sheet_open = false; // sheet_t eases to 0 over the next frames, sliding it out
}
fn show_toast(c: *Counter) void {
    push_toast(c, "Saved (kit toast, not native)", .default);
}

// Push a toast into the first free slot; if all are full, overwrite slot 0.
fn push_toast(c: *Counter, msg: []const u8, variant: zigui.ToastVariant) void {
    for (&c.toasts) |*s| {
        if (!s.active) {
            s.* = .{ .active = true, .text = msg, .variant = variant };
            return;
        }
    }
    c.toasts[0] = .{ .active = true, .text = msg, .variant = variant };
}

pub fn main() !void {
    var app = try zigui.App.init(.{ .title = "zigui", .size = .{ 400, 800 } });
    try app.run(&state, .{ .body = render, .overlay = overlay_view, .hud = hud_view });
}

// The modal layer: the eased edge sheet owns it while sliding, else the dialog frosts
// the backdrop and blocks the body. Both are kit-rendered (GPU), not native Android.
fn overlay_view(f: *zigui.Frame, counter: *Counter) ?*zigui.Node {
    const target: f32 = if (counter.sheet_open) 1 else 0;
    counter.sheet_t += (target - counter.sheet_t) * 0.25;
    if (@abs(target - counter.sheet_t) < 0.005) counter.sheet_t = target;
    if (counter.sheet_t != target) zigui.animate(); // keep ticking while it slides
    if (counter.sheet_t > 0.001) {
        return zigui.sheet(.{
            .side = .bottom,
            .open_t = counter.sheet_t,
            .top_inset = f.body.origin.y,
            .title = "Edit profile",
            .description = "A kit sheet sliding from the bottom edge.",
            .dismiss = counter.sheet_open,
            .on_close = zigui.on(Counter, sheet_close),
        });
    }
    counter.sheet_open = false; // fully closed
    if (!counter.dialog_open) return null;
    return zigui.dialog(.{
        .width = 288, // fit a phone screen (the 420 default overflows)
        .title = "Delete this?",
        .description = "This kit dialog interrupts for a decision.",
        .actions = &.{
            .{
                .label = "Cancel",
                .variant = .outline,
                .on_click = zigui.on(Counter, dialog_close),
            },
            .{
                .label = "Delete",
                .variant = .destructive,
                .on_click = zigui.on(Counter, dialog_confirm),
            },
        },
        .on_dismiss = zigui.on(Counter, dialog_close),
    });
}

// The non-modal top layer: the in-app toast stack, fired from the Kit UI page.
fn hud_view(f: *zigui.Frame, counter: *Counter) ?*zigui.Node {
    _ = f;
    for (counter.toasts) |s| {
        if (s.active) return zigui.toasts(.{ .slots = &counter.toasts });
    }
    return null;
}

// A tap adds a dot, capped so the row never overflows the surface. With no font
// the label does not render, so the dot row is the visible proof a touch reached
// the kit.
const MAX_DOTS = 8;
// Enough rows to overflow the viewport so the list is scrollable by drag.
const LIST_ROWS = 16;

fn render(f: *zigui.Frame, counter: *Counter) *zigui.Node {
    if (nav.depth == 0) nav.go("home", "Home"); // seed the root once
    zigui.handle_back(&nav); // Esc / Android Back / chevron -> pop
    if (nav.take_result()) |r| { // a detail page returned a result: keep it
        const k = @min(r.len, counter.last_result.len);
        @memcpy(counter.last_result[0..k], r[0..k]);
        counter.last_result_len = k;
    }
    if (zigui.napi.picker.take_file(&counter.file_preview)) |picked| { // a pick came back: keep it
        counter.file_preview_len = picked.len;
    }
    if (zigui.napi.biometric.result()) |outcome| { // the prompt finished: keep its verdict
        counter.auth_done = outcome == .success;
    }
    if (zigui.napi.notification_listener.take(&counter.notif)) |n| { // a notification arrived
        counter.notif_len = n.len;
    }
    if (zigui.napi.broadcast.take(&counter.bc)) |b| { // a subscribed broadcast arrived
        counter.bc_len = b.len;
    }
    if (zigui.napi.accessibility.take_event(&counter.a11y_event)) |e| { // an a11y event arrived
        counter.a11y_event_len = e.len;
    }
    // Window properties, re-asserted every frame (the backend hops into the OS
    // only on a change): light status-bar icons over this dark theme, plus the
    // two live toggles below.
    zigui.napi.display.status_bar_icons(.light);
    zigui.napi.display.keep_awake(counter.awake);
    zigui.napi.display.immersive(counter.immersive);

    // nav_page renders the current page, or slides the two pages during a push/pop.
    const page = zigui.nav_page(f, Counter, &nav, counter, dispatch);
    return zigui.col(.{}, &.{
        zigui.app_bar(nav.current_title(), .{ .show_back = nav.depth > 1 }),
        page,
    });
}

// The route -> page dispatch; nav_page calls it (twice during a slide, once otherwise).
fn dispatch(f: *zigui.Frame, counter: *Counter, route: []const u8) *zigui.Node {
    if (std.mem.eql(u8, route, "detail")) return detail_page(f);
    if (std.mem.eql(u8, route, "frame")) return frame_page(f);
    if (std.mem.eql(u8, route, "native")) return native_page(f, counter);
    if (std.mem.eql(u8, route, "a11y")) return a11y_page(f, counter);
    if (std.mem.eql(u8, route, "notif")) return notif_page(f, counter);
    if (std.mem.eql(u8, route, "bc")) return bc_page(f, counter);
    if (std.mem.eql(u8, route, "kit")) return kit_page(f, counter);
    return home_page(f, counter);
}

fn home_page(f: *zigui.Frame, counter: *Counter) *zigui.Node {
    const n = @min(counter.clicks, MAX_DOTS);
    var dots: []const *zigui.Node = &.{};
    if (f.arena.alloc(*zigui.Node, n)) |slice| {
        const box = zigui.Config{ .width = 28, .height = 28, .radius = 8, .bg = f.theme.primary };
        for (slice) |*dot| dot.* = zigui.col(box, &.{});
        dots = slice;
    } else |_| {}

    // A tall list of alternating bars; dragging inside it scrolls (the bars shift).
    var rows: []const *zigui.Node = &.{};
    if (f.arena.alloc(*zigui.Node, LIST_ROWS)) |slice| {
        for (slice, 0..) |*r, i| {
            const c = if (i % 2 == 0) f.theme.primary else f.theme.border;
            r.* = zigui.col(.{ .height = 44, .radius = 8, .bg = c }, &.{});
        }
        rows = slice;
    } else |_| {}

    // A click that misses the field blurs the shared editor (hides the keyboard).
    const page = zigui.Config{
        .pad = .lg,
        .gap = .md,
        .grow = 1,
        .on_click = zigui.on(Counter, blur_fields),
    };
    const returned = counter.last_result[0..counter.last_result_len];
    const note = if (counter.last_result_len > 0) returned else "(no result yet)";
    const awake_label = if (counter.awake) "Keep awake: ON" else "Keep awake: off";
    const imm_label = if (counter.immersive) "Immersive: ON" else "Immersive: off";
    return zigui.col(page, &.{
        zigui.text("Hello, Android.", .{ .size = 28 }),
        zigui.button("Tap me", .{ .on_click = zigui.on(Counter, on_click) }),
        zigui.button("Open details", .{ .on_click = zigui.on(Counter, open_detail) }),
        zigui.button("Show AHB frame", .{ .on_click = zigui.on(Counter, open_frame) }),
        zigui.button("Native APIs", .{ .on_click = zigui.on(Counter, open_native) }),
        zigui.button("Accessibility", .{ .on_click = zigui.on(Counter, open_a11y) }),
        zigui.button("Notif listener", .{ .on_click = zigui.on(Counter, open_notif) }),
        zigui.button("Broadcasts", .{ .on_click = zigui.on(Counter, open_bc) }),
        zigui.button("Kit UI", .{ .on_click = zigui.on(Counter, open_kit) }),
        zigui.button(awake_label, .{ .on_click = zigui.on(Counter, toggle_awake) }),
        zigui.button(imm_label, .{ .on_click = zigui.on(Counter, toggle_immersive) }),
        zigui.text(note, .{ .size = 16 }),
        zigui.text_input(&field, .{
            .placeholder = "Tap to type",
            .focused = counter.focus == 1,
            .id = 1,
            .on_focus = zigui.on(Counter, focus_field),
        }),
        zigui.row(.{ .gap = .sm }, dots),
        zigui.scroll(&list_scroll, .{ .grow = 1 }, zigui.col(.{ .gap = .sm }, rows)),
    });
}

// The native services, each one tap. Clipboard round-trips into the note; the
// picked file's text and the camera-permission state show their result inline.
fn native_page(f: *zigui.Frame, counter: *Counter) *zigui.Node {
    const clip = counter.last_result[0..counter.last_result_len];
    const note = if (counter.last_result_len > 0) clip else "(clipboard empty)";
    const file = counter.file_preview[0..counter.file_preview_len];
    const file_note = if (counter.file_preview_len > 0) file else "(no file picked)";
    const has_cam = zigui.napi.permissions.granted(CAMERA);
    const cam = if (has_cam) "Camera: granted" else "Camera: not granted";
    const auth = if (counter.auth_done) |ok|
        (if (ok) "Auth: success" else "Auth: failed")
    else
        "Auth: (none)";
    return zigui.col(.{ .pad = .lg, .gap = .md, .grow = 1 }, &.{
        zigui.text("Native APIs.", .{ .size = 20 }),
        zigui.button("Vibrate", .{ .on_click = zigui.on(Counter, do_vibrate) }),
        zigui.button("Open URL", .{ .on_click = zigui.on(Counter, do_open_url) }),
        zigui.button("Share text", .{ .on_click = zigui.on(Counter, do_share) }),
        zigui.button("Notify", .{ .on_click = zigui.on(Counter, do_notify) }),
        zigui.button("Toast", .{ .on_click = zigui.on(Counter, do_toast) }),
        zigui.button("Copy + paste", .{ .on_click = zigui.on(Counter, do_clipboard) }),
        zigui.text(note, .{ .size = 16 }),
        zigui.button("Rotate", .{ .on_click = zigui.on(Counter, cycle_orientation) }),
        zigui.button("Brightness", .{ .on_click = zigui.on(Counter, toggle_brightness) }),
        zigui.text(device_status(f), .{ .size = 16 }),
        zigui.button("Authenticate", .{ .on_click = zigui.on(Counter, do_biometric) }),
        zigui.text(auth, .{ .size = 16 }),
        zigui.button("Request camera", .{ .on_click = zigui.on(Counter, do_request_camera) }),
        zigui.text(cam, .{ .size = 16 }),
        zigui.button("Pick file", .{ .on_click = zigui.on(Counter, do_pick_file) }),
        zigui.text(file_note, .{ .size = 14 }),
    });
}

// Battery + connectivity, polled each frame and formatted into the arena (which the
// node borrows for the frame). A format failure falls back to a static label.
fn device_status(f: *zigui.Frame) []const u8 {
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

// The accessibility-service control surface. Enable opens system settings (a service
// is user-enabled, never programmatic); once on, the global actions + the injected
// swipe + the screen-read all run through zigui's shipped bound service. The inject
// hits whatever is foreground - here, the app's own scroll list.
fn a11y_page(f: *zigui.Frame, counter: *Counter) *zigui.Node {
    _ = f;
    const on = zigui.napi.accessibility.enabled();
    const status = if (on) "Service: enabled" else "Service: disabled";
    const tree = counter.a11y_read[0..counter.a11y_read_len];
    const read_note = if (counter.a11y_read_len > 0) tree else "(no read yet)";
    const ev = counter.a11y_event[0..counter.a11y_event_len];
    const ev_note = if (counter.a11y_event_len > 0) ev else "(no event yet)";
    return zigui.col(.{ .pad = .lg, .gap = .md, .grow = 1 }, &.{
        zigui.text("Accessibility.", .{ .size = 20 }),
        zigui.text(status, .{ .size = 16 }),
        zigui.button("Enable service", .{ .on_click = zigui.on(Counter, do_a11y_enable) }),
        zigui.button("Home action", .{ .on_click = zigui.on(Counter, do_a11y_home) }),
        zigui.button("Inject swipe", .{ .on_click = zigui.on(Counter, do_a11y_swipe) }),
        zigui.button("Read screen", .{ .on_click = zigui.on(Counter, do_a11y_read) }),
        zigui.text(read_note, .{ .size = 12 }),
        zigui.button("Subscribe events", .{ .on_click = zigui.on(Counter, do_a11y_events) }),
        zigui.text(ev_note, .{ .size = 12 }),
    });
}

// The notification-listener surface. Enable opens notification-access settings; once
// on, zigui's shipped listener forwards every posted notification to native, and
// "Post test notif" makes the app notify itself so the catch shows up in "Latest".
fn notif_page(f: *zigui.Frame, counter: *Counter) *zigui.Node {
    _ = f;
    const on = zigui.napi.notification_listener.enabled();
    const status = if (on) "Listener: enabled" else "Listener: disabled";
    const caught = counter.notif[0..counter.notif_len];
    const latest = if (counter.notif_len > 0) caught else "(none caught yet)";
    return zigui.col(.{ .pad = .lg, .gap = .md, .grow = 1 }, &.{
        zigui.text("Notification listener.", .{ .size = 20 }),
        zigui.text(status, .{ .size = 16 }),
        zigui.button("Enable listener", .{ .on_click = zigui.on(Counter, do_notif_enable) }),
        zigui.button("Post test notif", .{ .on_click = zigui.on(Counter, do_notif_post) }),
        zigui.text("Latest:", .{ .size = 14 }),
        zigui.text(latest, .{ .size = 12 }),
    });
}

// The broadcast-subscription surface. "Subscribe" registers screen on/off (no
// payload) + SMS (decoded "sender\tbody"); the last received broadcast shows as
// "action\tpayload". Trigger screen events with adb keyevent, SMS with emu sms send.
fn bc_page(f: *zigui.Frame, counter: *Counter) *zigui.Node {
    _ = f;
    const got = counter.bc[0..counter.bc_len];
    const last = if (counter.bc_len > 0) got else "(none received yet)";
    const inbox = counter.sms[0..counter.sms_len];
    const inbox_note = if (counter.sms_len > 0) inbox else "(inbox not read yet)";
    return zigui.col(.{ .pad = .lg, .gap = .md, .grow = 1 }, &.{
        zigui.text("Broadcasts.", .{ .size = 20 }),
        zigui.button("Subscribe screen + SMS", .{
            .on_click = zigui.on(Counter, do_bc_subscribe),
        }),
        zigui.text("Last:", .{ .size = 14 }),
        zigui.text(last, .{ .size = 12 }),
        zigui.button("Read SMS inbox", .{ .on_click = zigui.on(Counter, do_sms_read) }),
        zigui.text(inbox_note, .{ .size = 12 }),
        zigui.button("Send SMS to self", .{ .on_click = zigui.on(Counter, do_sms_send) }),
    });
}

// The kit-widget surface: a card (a styled surface), and triggers for the modal
// dialog + edge sheet (overlay region) and the in-app toast stack (hud region) - all
// kit-rendered through the same GPU renderer as desktop, not native Android views.
fn kit_page(f: *zigui.Frame, counter: *Counter) *zigui.Node {
    _ = counter;
    const t = f.theme;
    return zigui.col(.{ .pad = .lg, .gap = .md, .grow = 1 }, &.{
        zigui.text("Kit widgets.", .{ .size = 20 }),
        zigui.col(.{
            .gap = .sm,
            .pad = .lg,
            .bg = t.card,
            .border = t.border,
            .radius = t.radius,
        }, &.{
            zigui.text("Card", .{ .size = 16, .weight = .semi_bold }),
            zigui.text("A surface grouping content.", .{ .size = 13, .muted = true }),
            zigui.separator(.horizontal),
            zigui.text("Same renderer as desktop.", .{ .size = 13 }),
        }),
        zigui.button("Open dialog", .{ .on_click = zigui.on(Counter, open_dialog) }),
        zigui.button("Open sheet", .{ .on_click = zigui.on(Counter, open_sheet) }),
        zigui.button("Show toast", .{ .on_click = zigui.on(Counter, show_toast) }),
    });
}

// The zero-copy frame page: a synthesized YUV AHardwareBuffer imported with no
// copy and sampled through the renderer's ycbcr pipeline.
fn frame_page(f: *zigui.Frame) *zigui.Node {
    _ = f;
    return zigui.col(.{ .pad = .lg, .gap = .md, .grow = 1 }, &.{
        zigui.text("AHardwareBuffer (zero-copy NV12).", .{ .size = 20 }),
        ahb.frame_node(),
    });
}

// The pushed page reads the payload it was opened with (current_args) and can stage
// a result for home; the chevron / Back / Esc pop back (Save returns the result).
fn detail_page(f: *zigui.Frame) *zigui.Node {
    _ = f;
    return zigui.col(.{ .pad = .lg, .gap = .md, .grow = 1 }, &.{
        zigui.text("Detail page.", .{ .size = 28 }),
        zigui.text("Got args:", .{ .size = 14 }),
        zigui.text(nav.current_args(), .{ .size = 16 }),
        zigui.button("Save & back", .{ .on_click = zigui.on(Counter, save_and_back) }),
        zigui.text("(or Back to return with no result)", .{ .size = 14 }),
    });
}

fn on_click(counter: *Counter) void {
    counter.clicks += 1;
}

// The NativeActivity entry export emits only when the compilation root keeps it
// reachable; a comptime reference to zigui.App pulls the backend (and its
// exported ANativeActivity_onCreate, plus the JNI bridge symbols the shipped
// io.qoinly.zigui.ZiguiActivity resolves against) into the .so. A runtime use
// inside main() alone does not, so the framework would otherwise miss the entry.
comptime {
    _ = zigui.App;
}
