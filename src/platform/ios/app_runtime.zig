// The high-level iOS App: zigui.App on iOS (root.zig picks it ahead of the
// desktop app_runtime.App). It reuses the desktop Views/Frame contract and forks
// only the lifecycle: init stores the config, run registers a surface delegate
// and hands control to UIApplicationMain, which owns the loop and never returns.
// The surface delegate fires once the window is up.

const std = @import("std");
const app_runtime = @import("../../app_runtime.zig");
const ios_app = @import("app.zig");
const native = @import("native.zig");

pub const Views = app_runtime.Views;
pub const Frame = app_runtime.Frame;

pub const App = struct {
    rt: ios_app.App,
    alloc: std.mem.Allocator,
    opts: Options,
    user_state: ?*anyopaque = null,
    closed_cb: ?*const fn (?*anyopaque, u32) void = null,

    pub const Options = struct {
        title: []const u8 = "",
        size: [2]f32,
        min_size: ?[2]f32 = null,
    };

    pub const WindowOptions = struct {
        title: []const u8 = "",
        id: u32 = 0,
        size: ?[2]f32 = null,
        min_size: ?[2]f32 = null,
    };

    pub fn init(opts: Options) !*App {
        std.debug.assert(opts.size[0] > 0);
        std.debug.assert(opts.size[1] > 0);
        const alloc = std.heap.page_allocator;
        const self = try alloc.create(App);
        errdefer alloc.destroy(self);
        self.* = .{ .rt = try ios_app.App.init(), .alloc = alloc, .opts = opts };
        return self;
    }

    // Registers for the surface, then blocks in UIApplicationMain. The state must
    // outlive this call (the delegate fires later), so an example uses a
    // container-scoped var, the one shape difference from a desktop main.
    pub fn run(self: *App, state: anytype, comptime views: Views(@TypeOf(state))) !void {
        const StateArg = @TypeOf(state);
        comptime std.debug.assert(StateArg == void or @typeInfo(StateArg) == .pointer);
        _ = views;
        self.user_state = if (StateArg == void) null else @ptrCast(state);
        ios_app.set_surface_delegate(.{
            .ctx = @ptrCast(self),
            .on_ready = on_surface_ready,
            .on_lost = on_surface_lost,
        });
        ios_app.run_main(); // owns the loop; never returns
    }

    pub fn on_window_closed(self: *App, cb: *const fn (?*anyopaque, u32) void) void {
        self.closed_cb = cb;
    }

    // One fullscreen surface per app; additional windows are a desktop concept
    // with no iOS analogue. Kept for API parity, always rejected.
    pub fn open_window(
        self: *App,
        opts: WindowOptions,
        state: anytype,
        comptime views: Views(@TypeOf(state)),
    ) !void {
        _ = self;
        _ = opts;
        _ = views;
        return error.MultiWindowUnsupported;
    }

    pub fn deinit(self: *App) void {
        self.rt.deinit();
        self.alloc.destroy(self);
    }

    fn on_surface_ready(ctx: *anyopaque, window: *native.IOSWindow) void {
        std.debug.assert(@intFromPtr(ctx) != 0);
        std.debug.assert(window.in_use);
    }

    fn on_surface_lost(ctx: *anyopaque) void {
        std.debug.assert(@intFromPtr(ctx) != 0);
    }
};
