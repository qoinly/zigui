// Background work: run a job off the UI thread so a heavy computation never holds
// the frame. The result rides the same publish/poll handoff the android napi sinks
// use - a worker writes it into a caller-owned slot, publishes with a release store,
// and the view reads it once per frame with an acquire load. So "view is a function
// of state" holds: nothing mutates state off a frame.
//
// A job runs on its own detached thread, capped at MAX_INFLIGHT concurrent jobs, so
// an idle app has zero threads (not even parked ones) and a flood cannot spawn
// without bound - past the cap, or if a thread will not start, the job runs inline
// (correct, just on the calling thread). A job is short-lived; its thread exits when
// the work returns. This suits heavy-but-occasional GUI work, not a fire-hose.
//
// Contract: a job is pure Zig / syscalls / sockets. It must NOT call zigui.napi.*
// (JNI is bound to the UI thread; off it, napi refuses the call - a warn-once + no-op).
// A result that needs a JNI call is handed back first, then made on the UI thread.

const std = @import("std");

const MAX_INFLIGHT = 8; // bounded concurrency; past this a submit runs inline

pub const Status = enum(u8) { idle, queued, running, done, cancelled };

// A cooperative cancel signal a job polls at safe points. Cancelling never kills a
// thread mid-work; the job sees the flag and returns null (-> Status.cancelled).
pub const Cancel = struct {
    flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn requested(self: *const Cancel) bool {
        return self.flag.load(.acquire);
    }
};

// A caller-owned task handle: lives in app state (stable address) so a worker can
// back-point into it. Holds the result by value, no per-task heap. Submit binds a
// comptime work fn; the view reads the result once with poll().
pub fn Task(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const Result = T;

        status: std.atomic.Value(u8) = std.atomic.Value(u8).init(@intFromEnum(Status.idle)),
        result: T = undefined,
        cancel: Cancel = .{},
        ctx: ?*anyopaque = null,

        pub fn state(self: *Self) Status {
            return @enumFromInt(self.status.load(.acquire));
        }

        // The app must not re-submit while a job is in flight; this gates that.
        pub fn busy(self: *Self) bool {
            const s = self.state();
            return s == .queued or s == .running;
        }

        // The result, exactly once, the frame after the job finished; null otherwise.
        // Consuming resets to idle so a re-poll (and a re-submit) is clean.
        pub fn poll(self: *Self) ?T {
            if (self.state() != .done) return null;
            const out = self.result;
            self.status.store(@intFromEnum(Status.idle), .release);
            return out;
        }

        // Ask the job to stop at its next cancel check. The slot lands in .cancelled.
        pub fn request_cancel(self: *Self) void {
            self.cancel.flag.store(true, .release);
        }
    };
}

// Submit `work` to run on a background thread with `ctx` (a caller-owned pointer).
// `work` returns the result, or null if it bailed on cancel. The task must not
// already be busy. Both `task` and `ctx` must outlive the job - on Android, where
// deinit does not drain, that means process lifetime; on desktop, App.deinit drains.
pub fn submit(
    task: anytype,
    ctx: anytype,
    comptime work: fn (@TypeOf(ctx), *const Cancel) ?@TypeOf(task.*).Result,
) void {
    const TaskT = @TypeOf(task.*);
    const Ctx = @TypeOf(ctx);
    comptime std.debug.assert(@typeInfo(Ctx) == .pointer); // ctx is a caller-owned pointer
    std.debug.assert(!task.busy());

    task.cancel = .{};
    task.ctx = @ptrCast(ctx);

    const Thunk = struct {
        fn run(arg: *anyopaque) void {
            const t: *TaskT = @ptrCast(@alignCast(arg));
            const c: Ctx = @ptrCast(@alignCast(t.ctx.?));
            t.status.store(@intFromEnum(Status.running), .release);
            if (work(c, &t.cancel)) |val| {
                t.result = val;
                t.status.store(@intFromEnum(Status.done), .release); // publishes result
            } else {
                t.status.store(@intFromEnum(Status.cancelled), .release);
            }
            g_completion.store(true, .release); // nudge the loop to render + poll
        }
        // Decrement here, not in run(): the inline fallback never claimed a slot.
        fn threaded(arg: *anyopaque) void {
            run(arg);
            _ = g_inflight.fetchSub(1, .release);
        }
    };
    task.status.store(@intFromEnum(Status.queued), .release);

    // Claim an in-flight slot; over the cap or on a spawn failure, run inline so the
    // job is never dropped (it just costs the calling thread this once).
    if (g_inflight.fetchAdd(1, .acquire) >= MAX_INFLIGHT) {
        _ = g_inflight.fetchSub(1, .release);
        Thunk.run(@ptrCast(task));
        return;
    }
    const th = std.Thread.spawn(.{}, Thunk.threaded, .{@as(*anyopaque, @ptrCast(task))}) catch {
        _ = g_inflight.fetchSub(1, .release);
        Thunk.run(@ptrCast(task));
        return;
    };
    th.detach();
}

// One frame consumes the completion edge: true once after any job finishes, so the
// paint loop forces a redraw and the view's poll() runs. Idle frames stay idle.
pub fn took_completion() bool {
    return g_completion.swap(false, .acquire);
}

// Wait for in-flight jobs to finish. Desktop App.deinit calls this before tearing
// down state a detached job might still write; Android leaves it to process teardown.
pub fn drain() void {
    var spins: usize = 0;
    while (g_inflight.load(.acquire) > 0) : (spins += 1) {
        std.debug.assert(spins < 1 << 40); // a job that never returns is a caller bug
        std.Thread.yield() catch {};
    }
}

var g_inflight = std.atomic.Value(u32).init(0);
var g_completion = std.atomic.Value(bool).init(false);

test "task runs off-thread and the result polls back once" {
    const Ctx = struct { in: u32 };
    const job = struct {
        fn run(c: *Ctx, cancel: *const Cancel) ?u32 {
            _ = cancel;
            return c.in * 2;
        }
    };
    var ctx = Ctx{ .in = 21 };
    var task = Task(u32){};
    submit(&task, &ctx, job.run);

    // Spin like the paint loop would, bounded so a stuck job fails instead of hangs.
    var spins: usize = 0;
    const got = while (spins < 100_000_000) : (spins += 1) {
        if (task.poll()) |v| break v;
        std.Thread.yield() catch {};
    } else null;
    drain();

    try std.testing.expectEqual(@as(?u32, 42), got);
    try std.testing.expectEqual(@as(?u32, null), task.poll()); // consumed once
}
