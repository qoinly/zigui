// Desktop idle-sleep inhibitor through the org.freedesktop.ScreenSaver dbus
// service - the interface every desktop environment implements, so it covers both
// X11 and Wayland without a per-windowing-system path. libdbus-1 is dlopen'd like
// the other linux bindings (xcb-xinput, xkbcommon); an absent bus, library, or
// service degrades to a no-op. Inhibit returns a cookie, UnInhibit(cookie) frees it.

const std = @import("std");

extern "c" fn dlopen(file: [*:0]const u8, mode: c_int) ?*anyopaque;
extern "c" fn dlsym(handle: ?*anyopaque, name: [*:0]const u8) ?*anyopaque;
const RTLD_NOW: c_int = 2;

const DBUS_BUS_SESSION: c_int = 0;
const DBUS_TYPE_STRING: c_int = 's';
const DBUS_TYPE_UINT32: c_int = 'u';
const SS_NAME = "org.freedesktop.ScreenSaver";
const SS_PATH = "/org/freedesktop/ScreenSaver";

const Connection = anyopaque;
const Message = anyopaque;
const Str = [*:0]const u8;

// DBusError: { const char *name; const char *message; unsigned bits; void *pad }.
const Error = extern struct {
    name: ?[*:0]const u8 = null,
    message: ?[*:0]const u8 = null,
    bits: c_uint = 0,
    padding1: ?*anyopaque = null,
};

// DBusMessageIter is a fixed-size caller-allocated blob with opaque contents (the
// real struct is ~72 bytes); 128 aligned bytes covers it with margin.
const Iter = extern struct { blob: [128]u8 align(@alignOf(usize)) = undefined };

const Fns = struct {
    bus_get: *const fn (c_int, *Error) callconv(.c) ?*Connection,
    new_call: *const fn (Str, Str, Str, Str) callconv(.c) ?*Message,
    iter_append_start: *const fn (*Message, *Iter) callconv(.c) void,
    iter_append: *const fn (*Iter, c_int, *const anyopaque) callconv(.c) u32,
    send_block: *const fn (*Connection, *Message, c_int, *Error) callconv(.c) ?*Message,
    iter_read_start: *const fn (*Message, *Iter) callconv(.c) u32,
    iter_read: *const fn (*Iter, *anyopaque) callconv(.c) void,
    unref: *const fn (*Message) callconv(.c) void,
    error_free: *const fn (*Error) callconv(.c) void,
};

var g_fns: ?Fns = null;
var g_conn: ?*Connection = null;
var g_loaded = false; // dlopen attempted (success or failure), so it runs once
var g_cookie: u32 = 0; // 0 = not inhibited

// Inhibit (on) or release (off) the screensaver/idle-sleep. Cached against the
// current cookie, so a per-frame re-assert hits dbus only on a real change.
pub fn set(on: bool) void {
    if ((g_cookie != 0) == on) return;
    const f = load() orelse return;
    const conn = connection(f) orelse return;
    if (on) {
        g_cookie = inhibit(f, conn) orelse return;
    } else {
        uninhibit(f, conn, g_cookie);
        g_cookie = 0;
    }
}

fn load() ?Fns {
    if (g_loaded) return g_fns;
    g_loaded = true;
    const lib = dlopen("libdbus-1.so.3", RTLD_NOW) orelse return null;
    // Resolved in the Fns field order; a single missing symbol fails the whole load.
    const names = [_]Str{
        "dbus_bus_get",
        "dbus_message_new_method_call",
        "dbus_message_iter_init_append",
        "dbus_message_iter_append_basic",
        "dbus_connection_send_with_reply_and_block",
        "dbus_message_iter_init",
        "dbus_message_iter_get_basic",
        "dbus_message_unref",
        "dbus_error_free",
    };
    var s: [names.len]*anyopaque = undefined;
    for (names, 0..) |n, i| s[i] = dlsym(lib, n) orelse return null;
    g_fns = .{
        .bus_get = @ptrCast(@alignCast(s[0])),
        .new_call = @ptrCast(@alignCast(s[1])),
        .iter_append_start = @ptrCast(@alignCast(s[2])),
        .iter_append = @ptrCast(@alignCast(s[3])),
        .send_block = @ptrCast(@alignCast(s[4])),
        .iter_read_start = @ptrCast(@alignCast(s[5])),
        .iter_read = @ptrCast(@alignCast(s[6])),
        .unref = @ptrCast(@alignCast(s[7])),
        .error_free = @ptrCast(@alignCast(s[8])),
    };
    return g_fns;
}

fn connection(f: Fns) ?*Connection {
    if (g_conn) |c| return c;
    var err = Error{};
    const c = f.bus_get(DBUS_BUS_SESSION, &err) orelse {
        f.error_free(&err);
        return null;
    };
    g_conn = c;
    return c;
}

// Inhibit(app, reason) -> uint cookie. The string args pass a pointer to the char*,
// the dbus_message_iter_append_basic contract for DBUS_TYPE_STRING.
fn inhibit(f: Fns, conn: *Connection) ?u32 {
    const msg = f.new_call(SS_NAME, SS_PATH, SS_NAME, "Inhibit") orelse return null;
    defer f.unref(msg);
    var it: Iter = .{};
    f.iter_append_start(msg, &it);
    const app: Str = "zigui";
    const reason: Str = "keep awake";
    // DBUS_TYPE_STRING takes a pointer to the char*, hence &app (a double pointer).
    _ = f.iter_append(&it, DBUS_TYPE_STRING, @ptrCast(&app));
    _ = f.iter_append(&it, DBUS_TYPE_STRING, @ptrCast(&reason));
    var err = Error{};
    const reply = f.send_block(conn, msg, 1000, &err) orelse {
        f.error_free(&err);
        return null;
    };
    defer f.unref(reply);
    var rit: Iter = .{};
    if (f.iter_read_start(reply, &rit) == 0) return null;
    var cookie: u32 = 0;
    f.iter_read(&rit, &cookie);
    std.debug.assert(cookie != 0); // a live inhibitor always has a nonzero cookie
    return cookie;
}

fn uninhibit(f: Fns, conn: *Connection, cookie: u32) void {
    std.debug.assert(cookie != 0); // only called while an inhibitor is held
    const msg = f.new_call(SS_NAME, SS_PATH, SS_NAME, "UnInhibit") orelse return;
    defer f.unref(msg);
    var it: Iter = .{};
    f.iter_append_start(msg, &it);
    var c = cookie;
    _ = f.iter_append(&it, DBUS_TYPE_UINT32, &c);
    var err = Error{};
    if (f.send_block(conn, msg, 1000, &err)) |reply| f.unref(reply) else f.error_free(&err);
}
