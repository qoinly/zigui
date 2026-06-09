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
pub const Window = struct {
    handle: window.CustomShellHandle,
    pc: paint.PaintContext,
    eng: layout.LayoutEngine,
    arena: std.heap.ArenaAllocator,
    theme: types.Theme,
    alloc: std.mem.Allocator,
    dl: ?display_link.DisplayLink = null,
    user_state: ?*anyopaque = null,

    pub fn deinit(self: *Window) void {
        if (self.dl) |*dl| dl.stop(); // stop the link before the paint context it drives
        self.pc.deinit();
        self.eng.deinit();
        self.arena.deinit();
        self.handle.deinit();
    }
};

// The one public entry: opens a custom-rendered window and owns the render loop.
pub const App = struct {
    rt: platform_app.App,
    win: Window,
    alloc: std.mem.Allocator,

    pub const Options = struct {
        title: []const u8 = "",
        size: [2]f32,
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
            .min_width = if (opts.min_size) |m| @floatCast(m[0]) else 720,
            .min_height = if (opts.min_size) |m| @floatCast(m[1]) else 480,
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
        const Bridge = struct {
            fn cb(
                ctx: *anyopaque,
                pc: *paint.PaintContext,
                raw: paint.Frame,
            ) paint.PaintError!void {
                const w: *Window = &(@as(*App, @ptrCast(@alignCast(ctx)))).win;
                // High-water pool: reset both before building this frame's tree.
                w.eng.clear();
                _ = w.arena.reset(.retain_capacity);
                pc.blur_modal = false; // an overlay re-arms it each frame while open
                pc.text_field_active = false; // a focused input re-arms it below
                var fc = frame_ctx.FrameCtx{
                    .arena = w.arena.allocator(),
                    .theme = &w.theme,
                    .paint = pc,
                    .state = w.user_state,
                };
                var f = Frame{
                    .size = .{ .width = raw.width, .height = raw.height },
                    .body = raw.body,
                    .titlebar = raw.titlebar,
                    .theme = &w.theme,
                    .arena = w.arena.allocator(),
                    .time = pc.now_s,
                };
                // non-null whenever StateArg != void (run sets it from a real pointer)
                const st: StateArg =
                    if (StateArg == void) {} else @ptrCast(@alignCast(w.user_state.?));
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
        self.win.dl = try paint.start_paint_loop(&self.win.pc, @ptrCast(self), Bridge.cb);
        self.win.pc.request_redraw();
        self.win.handle.focus();
        self.rt.run_forever();
    }

    pub fn deinit(self: *App) void {
        self.win.deinit();
        self.rt.deinit();
        self.alloc.destroy(self);
    }
};
