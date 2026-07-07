// The high-level Android App: zigui.App on Android (root.zig picks it ahead of
// the desktop app_runtime.App). It reuses the desktop render bridge and paint
// machinery verbatim - the per-window Window bundle, WindowRunner.cb, and
// start_paint_loop - and forks only the lifecycle: the surface arrives async via
// onNativeWindowCreated and the framework owns the run loop, so init/run defer
// the real setup and return at once instead of opening a window and blocking.
//
// App.init stores the config; App.run stores the erased render callback + state
// and registers a surface delegate with the lifecycle layer (app.zig). When the
// surface is created the delegate builds the Window (renderer, paint context,
// Choreographer-driven paint loop); when it is destroyed the Window tears down,
// to be rebuilt on the next create (a resume, a rotation).

const std = @import("std");
const app_runtime = @import("../../app_runtime.zig");
const android_app = @import("app.zig");
const native = @import("native.zig");
const paint = @import("../../window/paint.zig");
const custom_shell = @import("../../custom_shell.zig");
const layout = @import("../../layout.zig");
const types = @import("../../window/types.zig");

pub const Views = app_runtime.Views;
pub const Frame = app_runtime.Frame;
const Window = app_runtime.Window;

pub const App = struct {
    // The process-level platform app (inert on Android). Held for parity with the
    // desktop App and, as a field of the lib's exposed App type, it keeps app.zig
    // - and its NativeActivity entry export - in the binary's analysis.
    rt: android_app.App,
    alloc: std.mem.Allocator,
    opts: Options,
    // Built on surface-ready, torn down on surface-lost; null in between.
    win: ?Window = null,
    user_state: ?*anyopaque = null,
    paint_cb: ?paint.PaintCallback = null,
    closed_cb: ?*const fn (?*anyopaque, u32) void = null,

    pub const Options = app_runtime.App.Options;
    pub const WindowOptions = app_runtime.App.WindowOptions;

    pub fn init(opts: Options) !*App {
        std.debug.assert(opts.size[0] > 0);
        std.debug.assert(opts.size[1] > 0);
        const alloc = std.heap.page_allocator;
        const self = try alloc.create(App);
        errdefer alloc.destroy(self);
        self.* = .{ .rt = try android_app.App.init(), .alloc = alloc, .opts = opts };
        return self;
    }

    // Stores the comptime-specialized render bridge + state, then registers for
    // the surface. Returns immediately: the framework drives the loop, so unlike
    // the desktop run there is nothing to block on. The state must outlive this
    // call (the framework calls back later) - a container-scoped var, not a stack
    // local, the one shape difference an example main needs from desktop.
    pub fn run(self: *App, state: anytype, comptime views: Views(@TypeOf(state))) !void {
        const StateArg = @TypeOf(state);
        comptime std.debug.assert(StateArg == void or @typeInfo(StateArg) == .pointer);
        self.user_state = if (StateArg == void) null else @ptrCast(state);
        self.paint_cb = app_runtime.WindowRunner(StateArg, views).cb;
        android_app.set_surface_delegate(.{
            .ctx = @ptrCast(self),
            .on_ready = on_surface_ready,
            .on_lost = on_surface_lost,
            .on_resized = on_surface_resized,
        });
    }

    pub fn on_window_closed(self: *App, cb: *const fn (?*anyopaque, u32) void) void {
        self.closed_cb = cb;
    }

    // One fullscreen surface per Activity; additional windows are a desktop
    // concept with no Activity analogue. Kept for API parity, always rejected.
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

    fn on_surface_ready(ctx: *anyopaque, window: *native.AndroidWindow) void {
        std.debug.assert(@intFromPtr(window) != 0);
        const self: *App = @ptrCast(@alignCast(ctx));
        self.build(window);
    }

    fn on_surface_lost(ctx: *anyopaque) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        self.teardown();
    }

    fn on_surface_resized(ctx: *anyopaque) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        if (self.win) |*w| w.pc.request_redraw();
    }

    // The deferred App.init body: now that the surface exists, stand up the
    // renderer, paint context, and Choreographer-driven paint loop. A failure
    // here leaves no half-built window (teardown unwinds) - the surface will be
    // re-offered on the next create.
    fn build(self: *App, window: *native.AndroidWindow) void {
        std.debug.assert(self.win == null);
        std.debug.assert(window.in_use);
        const cb = self.paint_cb orelse return; // run() always sets it before any surface event
        const theme = types.Theme.default_dark();
        const handle = custom_shell.open(.{
            .title = self.opts.title,
            .width = @floatCast(self.opts.size[0]),
            .height = @floatCast(self.opts.size[1]),
            .chrome = .custom,
            .feel = .liquid_glass,
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
        // live (handle/eng/arena) - teardown() would deinit the still-undefined
        // pc. Once init succeeds, pc is valid and teardown() is safe (dl null).
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

    // Releases the Window. Unlike the desktop close, this fully deinits the vsync
    // link (the single Choreographer slot) so the next surface can re-init it -
    // stop alone would leave the slot allocated and the rebuild would assert.
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
