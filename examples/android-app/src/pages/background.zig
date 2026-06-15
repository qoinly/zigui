const std = @import("std");
const zigui = @import("zigui");
const Node = zigui.Node;
const Frame = zigui.Frame;
const App = @import("../app.zig").App;
const page = @import("../scaffold/page.zig");

pub fn open(app: *App) void {
    app.nav.push("work", "Background");
}

// Bound by wall-clock, not an iteration count: a fixed count's duration swings
// wildly by device and optimize mode, where seconds stay seconds.
const JOB_SECONDS: f64 = 120;

const timespec = extern struct { tv_sec: isize, tv_nsec: isize };
extern "c" fn clock_gettime(clk: c_int, tp: *timespec) c_int;

fn monotonic_seconds() f64 {
    var ts: timespec = undefined;
    _ = clock_gettime(1, &ts); // CLOCK_MONOTONIC
    return @as(f64, @floatFromInt(ts.tv_sec)) + @as(f64, @floatFromInt(ts.tv_nsec)) * 1e-9;
}

fn heavy(app: *App, cancel: *const zigui.background.Cancel) ?u64 {
    _ = app;
    const start = monotonic_seconds();
    var acc: u64 = 0;
    var i: u64 = 0;
    while (true) : (i += 1) {
        acc +%= (i ^ (i << 7) ^ (i >> 3)) *% 2654435761;
        if (i & 0xFFFFF == 0) { // amortize the clock + cancel-flag reads
            if (cancel.requested()) return null;
            if (monotonic_seconds() - start >= JOB_SECONDS) break;
        }
    }
    return acc;
}

fn run_job(app: *App) void {
    if (app.bg_task.busy()) return;
    app.bg_result = null;
    zigui.background.submit(&app.bg_task, app, heavy);
}
fn cancel_job(app: *App) void {
    app.bg_task.request_cancel();
}

pub fn view(f: *Frame, app: *App) *Node {
    const t = f.theme;
    const busy = app.bg_task.busy();
    // The loop idles when nothing is dirty; tick it while busy so the spinner moves
    // and the result poll keeps running.
    if (busy) zigui.animate();

    const status = if (busy)
        "Running off the UI thread..."
    else switch (app.bg_task.state()) {
        .cancelled => "Cancelled.",
        else => if (app.bg_result) |r| done_label(f, r) else "Idle - tap Run job.",
    };
    const head = if (busy)
        zigui.row(.{ .gap = .md, .cross = .center }, &.{
            zigui.spinner(14, t.primary),
            page.status(status),
        })
    else
        page.status(status);

    return page.screen(&.{
        page.header("Background work."),
        zigui.text("A ~2 min job runs off-thread; the spinner stays smooth.", .{
            .size = 13,
            .muted = true,
        }),
        head,
        zigui.button("Run job", .{ .on_click = zigui.on(App, run_job), .disabled = busy }),
        zigui.button("Cancel", .{
            .variant = .outline,
            .on_click = zigui.on(App, cancel_job),
            .disabled = !busy,
        }),
    });
}

fn done_label(f: *Frame, r: u64) []const u8 {
    return std.fmt.allocPrint(f.arena, "Done off-thread: {d}", .{r}) catch "Done.";
}
