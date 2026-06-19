const std = @import("std");
const zigui = @import("zigui");
const Node = zigui.Node;
const Frame = zigui.Frame;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const page = @import("../scaffold/page.zig");

// The headless handler runs on the binder / receiver thread (no UI), possibly while
// the app is backgrounded or even cold-started for this one event. To prove it ran
// without any foreground, it appends a line to a log file in the public Download
// folder - pure Zig (std.posix), no napi, no Java. Pull it with no UI:
//   adb pull /sdcard/Download/zigui-headless.log
//
// The in-memory count/last below is only for the page when the app IS open; the file
// is what shows the handler ran when the app was closed.

const LOG_PATH = "/storage/emulated/0/Download/zigui-headless.log";

var g_count = std.atomic.Value(u32).init(0);
var g_last: [256]u8 = undefined;
var g_last_len: usize = 0;
var g_last_valid = std.atomic.Value(bool).init(false);

// Called from the app root's on_background_event for every notification / broadcast.
pub fn on_event(ev: zigui.BackgroundEvent) void {
    remember(ev);
    append_to_log(ev);
}

// Append one line describing the event to the Download log. Any failure is swallowed -
// a headless handler must not crash the process (e.g. when storage is not granted).
fn append_to_log(ev: zigui.BackgroundEvent) void {
    var line: [512]u8 = undefined;
    var n: usize = 0;
    switch (ev) {
        .notification => |x| {
            const s = std.fmt.bufPrint(&line, "notification\tpackage={s}\ttext={s}\n", .{
                x.package,
                x.text,
            }) catch return;
            n = s.len;
        },
        .broadcast => |b| {
            const head = "broadcast\t";
            @memcpy(line[0..head.len], head);
            n = head.len + app_mod.flatten_broadcast(line[head.len..], b);
            if (n < line.len) {
                line[n] = '\n';
                n += 1;
            }
        },
    }

    // Raw syscalls: std.Io would need a runtime instance the binder thread does not
    // have, and these are all this needs. Android is linux, so std.os.linux applies.
    const fd = std.posix.openatZ(
        std.posix.AT.FDCWD,
        LOG_PATH,
        .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true },
        0o644,
    ) catch return;
    defer _ = std.os.linux.close(fd);
    _ = std.os.linux.write(fd, line[0..n].ptr, n);
}

// The in-memory store the page reads when the app is open. Published release/acquire
// like the napi sinks (binder-thread write, foreground read).
fn remember(ev: zigui.BackgroundEvent) void {
    g_last_valid.store(false, .monotonic); // mark in-progress so a read skips a half-write
    switch (ev) {
        .notification => |n| {
            const w = std.fmt.bufPrint(&g_last, "notif {s}: {s}", .{ n.package, n.text }) catch
                g_last[0..0]; // a too-long event just shows empty, never overflows
            g_last_len = w.len;
        },
        .broadcast => |b| {
            const head = "bcast ";
            @memcpy(g_last[0..head.len], head);
            g_last_len = head.len + app_mod.flatten_broadcast(g_last[head.len..], b);
        },
    }
    g_last_valid.store(true, .release); // publish
    _ = g_count.fetchAdd(1, .monotonic);
}

pub fn open(app: *App) void {
    app.nav.push("headless", "Headless");
}

pub fn view(f: *Frame, app: *App) *Node {
    _ = app;
    const count = g_count.load(.acquire);
    const last = if (g_last_valid.load(.acquire))
        g_last[0..@min(g_last_len, g_last.len)]
    else
        "(none yet)";
    const count_line = std.fmt.allocPrint(f.arena, "Events handled: {d}", .{count}) catch
        "Events handled: ?";
    return page.screen(&.{
        page.header("Headless events."),
        zigui.text("Each event appends to Download/zigui-headless.log from pure Zig, " ++
            "even with the app closed. Pull it with: adb pull " ++
            "/sdcard/Download/zigui-headless.log", .{
            .size = 13,
            .muted = true,
        }),
        page.status(count_line),
        zigui.text("Last:", .{ .size = 14 }),
        page.note(last),
    });
}
