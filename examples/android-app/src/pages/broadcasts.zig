const zigui = @import("zigui");
const Node = zigui.Node;
const Frame = zigui.Frame;
const App = @import("../app.zig").App;
const page = @import("../scaffold/page.zig");

const RECEIVE_SMS = "android.permission.RECEIVE_SMS";
const READ_SMS = "android.permission.READ_SMS";
const SEND_SMS = "android.permission.SEND_SMS";

pub fn open(app: *App) void {
    app.nav.push("bc", "Broadcasts");
}

// Subscribe to a system broadcast (screen on/off, no payload) and SMS (decoded
// payload, needs the runtime RECEIVE_SMS permission).
fn do_subscribe(app: *App) void {
    _ = app;
    if (!zigui.napi.permissions.granted(RECEIVE_SMS)) zigui.napi.permissions.request(RECEIVE_SMS);
    zigui.napi.broadcast.subscribe("android.intent.action.SCREEN_ON");
    zigui.napi.broadcast.subscribe("android.intent.action.SCREEN_OFF");
    zigui.napi.broadcast.subscribe("android.provider.Telephony.SMS_RECEIVED");
}
// Read the SMS inbox into the page buffer (READ_SMS, distinct from RECEIVE_SMS).
fn do_sms_read(app: *App) void {
    if (!zigui.napi.permissions.granted(READ_SMS)) {
        zigui.napi.permissions.request(READ_SMS);
        return;
    }
    if (zigui.napi.sms.read(&app.sms)) |inbox| app.sms_len = inbox.len;
}
// Send an SMS to the emulator's own number so it loops back to the inbox (SEND_SMS).
fn do_sms_send(app: *App) void {
    _ = app;
    if (!zigui.napi.permissions.granted(SEND_SMS)) {
        zigui.napi.permissions.request(SEND_SMS);
        return;
    }
    zigui.napi.sms.send("5555215554", "hello from zigui sms send");
}

// The broadcast-subscription surface. "Subscribe" registers screen on/off (no
// payload) + SMS (decoded "sender\tbody"); the last received broadcast shows as
// "action\tpayload". Trigger screen events with adb keyevent, SMS with emu sms send.
pub fn view(f: *Frame, app: *App) *Node {
    _ = f;
    const got = app.bc[0..app.bc_len];
    const last = if (app.bc_len > 0) got else "(none received yet)";
    const inbox = app.sms[0..app.sms_len];
    const inbox_note = if (app.sms_len > 0) inbox else "(inbox not read yet)";
    return page.screen(&.{
        page.header("Broadcasts."),
        zigui.button("Subscribe screen + SMS", .{ .on_click = zigui.on(App, do_subscribe) }),
        zigui.text("Last:", .{ .size = 14 }),
        page.note(last),
        zigui.button("Read SMS inbox", .{ .on_click = zigui.on(App, do_sms_read) }),
        page.note(inbox_note),
        zigui.button("Send SMS to self", .{ .on_click = zigui.on(App, do_sms_send) }),
    });
}
