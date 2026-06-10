const std = @import("std");
const platform_app = @import("app.zig");
const window = @import("window.zig");
const paint = @import("window/paint.zig");
const types = @import("window/types.zig");
const layout = @import("layout.zig");
const node = @import("node.zig");
const geometry = @import("geometry.zig");
const display_link = @import("display_link.zig");
const frame_ctx = @import("frame_ctx.zig");
const custom_shell = @import("custom_shell.zig");

// What `render` receives each frame. Read it for layout; do not retain it - the
// arena is reset on the next frame.
pub const Frame = struct {
    size: geometry.SizeF,
    body: geometry.BoundsF, // content rect below the title band
    titlebar: geometry.BoundsF, // the title band's content rect (past the traffic lights)
    theme: *const types.Theme,
    arena: std.mem.Allocator,
    time: f64, // monotonic seconds, for time-based animation (with zigui.animate)
};

// The window's region views. titlebar/overlay/hud are optional. The lib always
// draws the band and repositions the traffic lights (titlebar fills its content);
// overlay is the modal/anchored layer (it blocks the body), hud is the non-modal
// layer drawn last over everything (toasts, hover tooltips).
pub fn Views(comptime State: type) type {
    return struct {
        body: *const fn (*Frame, State) *node.Node,
        titlebar: ?*const fn (*Frame, State) *node.Node = null,
        // null return = nothing floating this frame (so the body stays interactive).
        overlay: ?*const fn (*Frame, State) ?*node.Node = null,
        // Non-modal top layer above the overlay (toasts, hover tooltips). NEVER
        // blocks body hover - it renders last and leaves block_hover untouched.
        hud: ?*const fn (*Frame, State) ?*node.Node = null,
    };
}

// Everything scoped to one window, kept apart from the process-level platform app
// and run loop that live on App.
// Max title bytes a window owns. A window copies its title so the view can read
// it back without the caller keeping the string alive.
const TITLE_MAX = 128;

// Smallest a window may shrink to when the caller sets no min, kept well under
// common opening sizes so a window can always resize down rather than snap up.
const MIN_W: f32 = 320;
const MIN_H: f32 = 240;

pub const Window = struct {
    handle: window.CustomShellHandle,
    pc: paint.PaintContext,
    eng: layout.LayoutEngine,
    arena: std.heap.ArenaAllocator,
    theme: types.Theme,
    alloc: std.mem.Allocator,
    dl: ?display_link.DisplayLink = null,
    // Owns this window's render-loop state so the display link drives it without a
    // shared global; each window gets an independent vsync loop.
    run_state: paint.RunState = undefined,
    user_state: ?*anyopaque = null,
    id: u32 = 1, // window identity a shared view reads via window_id(); first is 1
    title: []const u8 = "", // slice into title_buf
    title_buf: [TITLE_MAX]u8 = undefined,

    fn set_title(self: *Window, s: []const u8) void {
        const n = @min(s.len, self.title_buf.len);
        @memcpy(self.title_buf[0..n], s[0..n]);
        self.title = self.title_buf[0..n];
    }

    pub fn deinit(self: *Window) void {
        if (self.dl) |*dl| dl.stop(); // stop the link before the paint context it drives
        self.pc.deinit();
        self.eng.deinit();
        self.arena.deinit();
        self.handle.deinit();
    }

    // Teardown on the user-close path. The OS releases the NSWindow itself once
    // the close finishes, so this frees everything except the handle and fully
    // tears the link down (cancel, not just stop) before its context goes away.
    fn close_teardown(self: *Window) void {
        std.debug.assert(self.dl != null); // close only fires on a looped window
        std.debug.assert(@intFromPtr(self.handle.window) != 0);
        if (self.dl) |*dl| dl.deinit();
        self.dl = null;
        self.pc.deinit();
        self.eng.deinit();
        self.arena.deinit();
    }
};

// A desktop app opens a handful of windows; cap the set so its growth stays
// bounded and asserted rather than open-ended.
const WINDOWS_MAX: usize = 64;

// Extra windows past the first, tracked so the app tears them down. Allocated
// lazily on the second window so a single-window app pays for none of this.
const WindowSet = struct {
    items: std.ArrayListUnmanaged(*Window) = .empty,

    fn deinit(self: *WindowSet, alloc: std.mem.Allocator) void {
        for (self.items.items) |w| {
            w.deinit();
            alloc.destroy(w);
        }
        self.items.deinit(alloc);
    }
};

// The per-frame render bridge for one window, specialized on the view set. The
// display link hands back the *Window as its context, so every callback drives
// exactly the window it belongs to (no shared current-window global).
fn WindowRunner(comptime State: type, comptime views: Views(State)) type {
    comptime std.debug.assert(State == void or @typeInfo(State) == .pointer);
    return struct {
        fn cb(ctx: *anyopaque, pc: *paint.PaintContext, raw: paint.Frame) paint.PaintError!void {
            const w: *Window = @ptrCast(@alignCast(ctx));
            // High-water pool: reset both before building this frame's tree.
            w.eng.clear();
            _ = w.arena.reset(.retain_capacity);
            pc.blur_modal = false; // an overlay re-arms it each frame while open
            pc.text_field_active = false; // a focused input re-arms it below
            // Clear the redraw-again flag too: whatever still needs continuous
            // frames (animate(), a focused editor) re-arms it during the build, so
            // an idle window stops driving its loop instead of spinning forever.
            pc.animating = false;
            var fc = frame_ctx.FrameCtx{
                .arena = w.arena.allocator(),
                .theme = &w.theme,
                .paint = pc,
                .state = w.user_state,
                .window_id = w.id,
                .window_title = w.title,
            };
            var f = Frame{
                .size = .{ .width = raw.width, .height = raw.height },
                .body = raw.body,
                .titlebar = raw.titlebar,
                .theme = &w.theme,
                .arena = w.arena.allocator(),
                .time = pc.now_s,
            };
            // non-null whenever State != void (the loop is started from a real pointer)
            const st: State = if (State == void) {} else @ptrCast(@alignCast(w.user_state.?));
            frame_ctx.enter(&fc);
            defer frame_ctx.leave();
            var builder = raw.builder;
            // Build the overlay first: a non-null tree means a modal is up, so
            // the body behind it must be inert (no hover) as well as covered.
            const ov_root: ?*node.Node = if (views.overlay) |overlay_view|
                overlay_view(&f, st)
            else
                null;
            pc.block_hover = ov_root != null;
            if (views.titlebar) |titlebar_view| {
                const tb_root = titlebar_view(&f, st);
                try node.render_at(&w.eng, &builder, &w.theme, tb_root, raw.titlebar, pc);
            }
            const body_root = views.body(&f, st);
            try node.render_at(&w.eng, &builder, &w.theme, body_root, raw.body, pc);
            if (ov_root) |root| {
                pc.block_hover = false; // the modal layer itself is live
                const full = geometry.BoundsF{ .origin = .{ .x = 0, .y = 0 }, .size = f.size };
                try node.render_at(&w.eng, &builder, &w.theme, root, full, pc);
            }
            // Non-modal layer on top; block_hover stays as-is so the body keeps
            // its hover (a tooltip needs its trigger live to stay visible).
            if (views.hud) |hud_view| if (hud_view(&f, st)) |hud_root| {
                const full = geometry.BoundsF{ .origin = .{ .x = 0, .y = 0 }, .size = f.size };
                try node.render_at(&w.eng, &builder, &w.theme, hud_root, full, pc);
            };
            // No focused input claimed the singleton editor this frame -> hide it.
            if (!pc.text_field_active) pc.hide_text_field();
        }
    };
}

// The one public entry: opens a custom-rendered window and owns the render loop.
pub const App = struct {
    rt: platform_app.App,
    win: Window,
    alloc: std.mem.Allocator,
    // Windows past the first; null until open_window is called a first time.
    windows: ?*WindowSet = null,
    // Defaults an extra window inherits when its options leave them unset.
    main_size: [2]f32 = .{ 0, 0 },
    main_min: [2]f32 = .{ MIN_W, MIN_H },
    next_id: u32 = 2, // the first id auto-assigned to an opened window (main is 1)
    // Fires when a non-main window closes, so the app can drop per-window state.
    closed_cb: ?*const fn (?*anyopaque, u32) void = null,

    pub const Options = struct {
        title: []const u8 = "",
        size: [2]f32,
        min_size: ?[2]f32 = null,
    };

    // What open_window takes: just the window's identity. Its state + views come
    // alongside. An empty title / zero id let the engine fill a default; a null
    // size inherits the main window's. A caller-set id should be unique (it is the
    // value window_id() reports); 0 lets the engine assign a fresh one.
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

        var rt = try platform_app.App.init();
        errdefer rt.deinit();
        rt.set_activation_policy(.regular);
        rt.quit_on_last_window_closed();
        rt.install_edit_menu();

        const theme = types.Theme.default_dark();
        const handle = try window.open_custom_shell(.{
            .title = opts.title,
            .width = @floatCast(opts.size[0]),
            .height = @floatCast(opts.size[1]),
            .min_width = if (opts.min_size) |m| @floatCast(m[0]) else MIN_W,
            .min_height = if (opts.min_size) |m| @floatCast(m[1]) else MIN_H,
            .chrome = .custom,
            .feel = .liquid_glass,
            .theme = theme,
        });
        errdefer handle.deinit();

        self.* = .{
            .rt = rt,
            .alloc = alloc,
            .win = .{
                .handle = handle,
                .pc = undefined,
                .eng = layout.LayoutEngine.init(alloc),
                .arena = std.heap.ArenaAllocator.init(alloc),
                .theme = theme,
                .alloc = alloc,
            },
        };
        errdefer self.win.arena.deinit();
        errdefer self.win.eng.deinit();

        try self.win.pc.init(self.win.handle, alloc);
        self.win.pc.icon_system.set_source(.bundled);
        self.win.id = 1;
        self.win.set_title(opts.title);
        self.main_size = opts.size;
        if (opts.min_size) |m| self.main_min = m;
        return self;
    }

    // views.body builds the body tree each frame; views.titlebar (optional) fills
    // the title band. The free builders read the per-frame context this sets, so
    // the views need no allocator.
    pub fn run(self: *App, state: anytype, comptime views: Views(@TypeOf(state))) !void {
        std.debug.assert(self.win.dl == null);
        const StateArg = @TypeOf(state);
        comptime std.debug.assert(StateArg == void or @typeInfo(StateArg) == .pointer);
        self.win.user_state = if (StateArg == void) null else @ptrCast(state);
        custom_shell.register_window_close(on_window_close, @ptrCast(self));
        self.win.dl = try paint.start_paint_loop(
            &self.win.run_state,
            &self.win.pc,
            @ptrCast(&self.win),
            WindowRunner(StateArg, views).cb,
        );
        self.win.pc.request_redraw();
        self.win.handle.focus();
        self.rt.run_forever();
    }

    // Registers a handler called (with the user state + window id) when a non-main
    // window closes, so the app can forget that window's state.
    pub fn on_window_closed(self: *App, cb: *const fn (?*anyopaque, u32) void) void {
        self.closed_cb = cb;
    }

    // Fired from the window's close: the main window quits the whole app (it is the
    // app's root and cannot be torn down on its own); an extra window stops its
    // loop, drops out of the set, and frees - the OS releases the window itself.
    fn on_window_close(ctx: *anyopaque, ns_window: ?*anyopaque) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        const target = @intFromPtr(ns_window orelse return);
        if (@intFromPtr(self.win.handle.window) == target) {
            self.rt.quit();
            return;
        }
        const set = self.windows orelse return;
        for (set.items.items, 0..) |w, i| {
            if (@intFromPtr(w.handle.window) != target) continue;
            if (self.closed_cb) |cb| cb(self.win.user_state, w.id);
            w.close_teardown();
            _ = set.items.orderedRemove(i);
            self.alloc.destroy(w);
            return;
        }
    }

    // Opens an additional window onto the already-running app. Its display link
    // joins the main loop, so this returns at once rather than blocking like run.
    // Call it while run is pumping (e.g. from a click), each window with its own
    // state + views; the identity (title/id/size) rides in opts. Platform
    // backends route input by native window so callbacks reach the right state.
    pub fn open_window(
        self: *App,
        opts: WindowOptions,
        state: anytype,
        comptime views: Views(@TypeOf(state)),
    ) !void {
        const StateArg = @TypeOf(state);
        comptime std.debug.assert(StateArg == void or @typeInfo(StateArg) == .pointer);

        const id = if (opts.id != 0) opts.id else blk: {
            const next = self.next_id;
            self.next_id += 1;
            break :blk next;
        };
        var name_buf: [TITLE_MAX]u8 = undefined;
        const title = if (opts.title.len > 0)
            opts.title
        else
            std.fmt.bufPrint(&name_buf, "Window {d}", .{id}) catch "Window";
        const size = opts.size orelse self.main_size;
        const min = opts.min_size orelse self.main_min;
        std.debug.assert(size[0] > 0);
        std.debug.assert(size[1] > 0);

        const theme = types.Theme.default_dark();
        const handle = try window.open_custom_shell(.{
            .title = title,
            .width = @floatCast(size[0]),
            .height = @floatCast(size[1]),
            .min_width = @floatCast(min[0]),
            .min_height = @floatCast(min[1]),
            .chrome = .custom,
            .feel = .liquid_glass,
            .theme = theme,
        });
        errdefer handle.deinit();

        const w = try self.alloc.create(Window);
        errdefer self.alloc.destroy(w);
        w.* = .{
            .handle = handle,
            .pc = undefined,
            .eng = layout.LayoutEngine.init(self.alloc),
            .arena = std.heap.ArenaAllocator.init(self.alloc),
            .theme = theme,
            .alloc = self.alloc,
            .user_state = if (StateArg == void) null else @ptrCast(state),
            .id = id,
        };
        w.set_title(title);
        errdefer w.arena.deinit();
        errdefer w.eng.deinit();
        try w.pc.init(w.handle, self.alloc);
        errdefer w.pc.deinit();
        w.pc.icon_system.set_source(.bundled);

        w.dl = try paint.start_paint_loop(
            &w.run_state,
            &w.pc,
            @ptrCast(w),
            WindowRunner(StateArg, views).cb,
        );
        errdefer if (w.dl) |*dl| dl.stop();

        // Track w only once it is fully live, so no error branch above can leave a
        // freed pointer in the set for deinit to free a second time.
        if (self.windows == null) {
            const set = try self.alloc.create(WindowSet);
            set.* = .{};
            self.windows = set;
        }
        std.debug.assert(self.windows.?.items.items.len < WINDOWS_MAX);
        try self.windows.?.items.append(self.alloc, w);

        w.pc.request_redraw();
        w.handle.focus();
    }

    pub fn deinit(self: *App) void {
        if (self.windows) |set| {
            set.deinit(self.alloc);
            self.alloc.destroy(set);
        }
        self.win.deinit();
        self.rt.deinit();
        self.alloc.destroy(self);
    }
};
