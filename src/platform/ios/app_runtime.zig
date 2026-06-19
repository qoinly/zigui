// The high-level iOS App: zigui.App on iOS (root.zig picks it ahead of the
// desktop app_runtime.App). It reuses the desktop render bridge and paint
// machinery verbatim - the per-window Window bundle, WindowRunner.cb, and
// start_paint_loop - and forks only the lifecycle: the surface arrives async via
// the delegate and UIApplicationMain owns the run loop, so run registers a surface
// delegate and then blocks instead of opening a window itself.
//
// App.run stores the erased render callback + state and registers the delegate;
// when the surface is ready the delegate builds the Window (renderer, paint
// context, CADisplayLink-driven paint loop), torn down on surface loss.

const std = @import("std");
const app_runtime = @import("../../app_runtime.zig");
const custom_shell = @import("../../custom_shell.zig");
const paint = @import("../../window/paint.zig");
const layout = @import("../../layout.zig");
const types = @import("../../window/types.zig");
const ios_app = @import("app.zig");
const native = @import("native.zig");

pub const Views = app_runtime.Views;
pub const Frame = app_runtime.Frame;
const Window = app_runtime.Window;

pub const App = struct {
    rt: ios_app.App,
    alloc: std.mem.Allocator,
    opts: Options,
    // Built on surface ready, torn down on surface loss; null in between.
    win: ?Window = null,
    user_state: ?*anyopaque = null,
    paint_cb: ?paint.PaintCallback = null,
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

    // Stores the comptime render bridge + state, then registers for the surface and
    // blocks in UIApplicationMain. The state must outlive this call (the delegate
    // fires later), so an example uses a container-scoped var, the one shape
    // difference from a desktop main.
    pub fn run(self: *App, state: anytype, comptime views: Views(@TypeOf(state))) !void {
        const StateArg = @TypeOf(state);
        comptime std.debug.assert(StateArg == void or @typeInfo(StateArg) == .pointer);
        self.user_state = if (StateArg == void) null else @ptrCast(state);
        self.paint_cb = app_runtime.WindowRunner(StateArg, views).cb;
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
        self.teardown();
        self.rt.deinit();
        self.alloc.destroy(self);
    }

    fn on_surface_ready(ctx: *anyopaque, window: *native.IOSWindow) void {
        std.debug.assert(window.in_use);
        const self: *App = @ptrCast(@alignCast(ctx));
        self.build();
    }

    fn on_surface_lost(ctx: *anyopaque) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        self.teardown();
    }

    // Now that the surface exists, stand up the renderer, paint context, and
    // CADisplayLink-driven paint loop. A failure here leaves no half-built window
    // (teardown unwinds); the surface is re-offered on the next ready.
    fn build(self: *App) void {
        std.debug.assert(self.win == null);
        const cb = self.paint_cb orelse return; // run() sets it before any surface event
        const theme = types.Theme.default_dark();
        const handle = custom_shell.open(.{
            .title = self.opts.title,
            .width = @floatCast(self.opts.size[0]),
            .height = @floatCast(self.opts.size[1]),
            .chrome = .custom,
            .theme = theme,
        }) catch return;
        self.win = .{
            .handle = handle,
            .pc = undefined,
            .eng = layout.LayoutEngine.init(self.alloc),
            .arena = std.heap.ArenaAllocator.init(self.alloc),
            .theme = theme,
            .alloc = self.alloc,
            .user_state = self.user_state,
            .id = 1,
        };
        const w = &self.win.?;
        // pc is the last undefined field; on its init failure free only what is
        // live (handle/eng/arena), then drop the window.
        w.pc.init(w.handle, self.alloc) catch {
            w.eng.deinit();
            w.arena.deinit();
            w.handle.deinit();
            self.win = null;
            return;
        };
        w.pc.icon_system.set_source(.bundled);
        w.dl = paint.start_paint_loop(&w.run_state, &w.pc, @ptrCast(w), cb) catch {
            self.teardown();
            return;
        };
        w.pc.request_redraw();
    }

    fn teardown(self: *App) void {
        const w = if (self.win) |*win| win else return;
        if (w.dl) |*dl| dl.deinit();
        w.pc.deinit();
        w.eng.deinit();
        w.arena.deinit();
        w.handle.deinit();
        self.win = null;
    }
};
