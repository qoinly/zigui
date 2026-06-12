// The X11 arm of the linux custom shell (custom_shell.zig dispatches here):
// an undecorated xcb window (motif hints strip the WM frame) carrying the
// same CSD chrome as the Wayland arm, so the two backends are visually
// identical. This arm covers window lifecycle + the event tap; input routing
// and the system surface follow in their own branches as honest stubs that
// keep the dispatcher surface complete.

const std = @import("std");
const xcb = @import("xcb.zig");
const desktop_theme = @import("desktop_theme.zig");
const types = @import("../../window/types.zig");
const geometry = @import("../../geometry.zig");
const shell_types = @import("shell_types.zig");

pub const Error = shell_types.Error;
pub const ContentSize = shell_types.ContentSize;
pub const CursorKind = shell_types.CursorKind;
pub const CaptionButton = shell_types.CaptionButton;
pub const CaptionSlots = shell_types.CaptionSlots;
pub const MouseDispatch = shell_types.MouseDispatch;
pub const RawDispatch = shell_types.RawDispatch;
pub const HitTestFn = shell_types.HitTestFn;
pub const RedrawFn = shell_types.RedrawFn;
pub const WindowCloseFn = shell_types.WindowCloseFn;

const MAX_WINDOWS: u32 = 16;

// MWM_HINTS_DECORATIONS with decorations = 0: the WM draws no frame and the
// CSD chrome owns the band, the Wayland/Windows model.
const MOTIF_FLAG_DECORATIONS: u32 = 2;

pub const X11Window = struct {
    in_use: bool = false,
    window: u32 = 0,
    width_pt: i32 = 0,
    height_pt: i32 = 0,
    scale: i32 = 1,
    fullscreen: bool = false,
    maximized: bool = false,
    renderer_owned: bool = false,
    surface_ctx: ?*anyopaque = null,
};

var g_windows: [MAX_WINDOWS]X11Window = [_]X11Window{.{}} ** MAX_WINDOWS;
var g_dispatch: ?MouseDispatch = null;
var g_raw: ?RawDispatch = null;
var g_hit_test: ?HitTestFn = null;
var g_redraw: ?RedrawFn = null;
var g_paint_now: ?RedrawFn = null;
var g_ctx: ?*anyopaque = null;
var g_window_close: ?WindowCloseFn = null;
var g_window_close_ctx: ?*anyopaque = null;
var g_titlebar_height: f32 = 37;
var g_cursor: CursorKind = .default;
pub var quit_requested: bool = false;

// Atoms interned once at connect; 0 means the intern failed and the feature
// degrades (a frame from the WM instead of none, no close message match).
var g_atom_protocols: u32 = 0;
var g_atom_delete_window: u32 = 0;
var g_atom_net_wm_name: u32 = 0;
var g_atom_utf8_string: u32 = 0;
var g_atom_motif_hints: u32 = 0;

pub const CustomShellHandle = struct {
    window: *X11Window,
    metal_layer: *anyopaque,
    height: f32,
    theme: types.Theme,
    titlebar: types.TitlebarOptions,

    pub fn focus(self: CustomShellHandle) void {
        std.debug.assert(self.window.in_use);
    }

    pub fn is_fullscreen(self: CustomShellHandle) bool {
        std.debug.assert(self.window.in_use);
        return self.window.fullscreen;
    }

    pub fn set_fullscreen(self: CustomShellHandle, on: bool) void {
        std.debug.assert(self.window.in_use);
        _ = on;
    }

    pub fn backing_scale_factor(self: CustomShellHandle) f32 {
        std.debug.assert(self.window.in_use);
        std.debug.assert(self.window.scale >= 1);
        return @floatFromInt(self.window.scale);
    }

    pub fn is_maximized(self: CustomShellHandle) bool {
        std.debug.assert(self.window.in_use);
        return self.window.maximized;
    }

    pub fn is_minimized(self: CustomShellHandle) bool {
        std.debug.assert(self.window.in_use);
        return false;
    }

    pub fn is_key(self: CustomShellHandle) bool {
        std.debug.assert(self.window.in_use);
        return true;
    }

    pub fn sync_drawable_size(self: CustomShellHandle) ContentSize {
        const win = self.window;
        std.debug.assert(win.in_use);
        std.debug.assert(win.width_pt > 0);
        std.debug.assert(win.height_pt > 0);
        return .{
            .width = @floatFromInt(win.width_pt),
            .height = @floatFromInt(win.height_pt),
        };
    }

    pub fn deinit(self: CustomShellHandle) void {
        destroy_window(self.window);
    }
};

pub fn open(opts: types.NativeShellOptions) Error!CustomShellHandle {
    xcb.connect() catch return error.ConnectFailed;
    intern_atoms();
    _ = desktop_theme.accent_color(); // warm the resolve outside the paint tick
    std.debug.assert(opts.width > 0);
    std.debug.assert(opts.height > 0);
    g_titlebar_height = @floatCast(opts.titlebar.height);

    const win = alloc_window() orelse return error.WindowCreateFailed;
    errdefer destroy_window(win);
    const theme = opts.theme orelse types.Theme.default_dark();
    win.width_pt = @intFromFloat(opts.width);
    win.height_pt = @intFromFloat(opts.height);
    win.window = xcb.generate_id();
    xcb.create_window(
        win.window,
        @intCast(win.width_pt),
        @intCast(win.height_pt),
        pack_xrgb(theme.background),
    );
    apply_motif_undecorated(win.window);
    apply_title(win.window, opts.title);
    apply_delete_protocol(win.window);
    xcb.map_window(win.window);
    xcb.flush();

    return .{
        .window = win,
        .metal_layer = @ptrCast(win),
        .height = @floatCast(opts.height),
        .theme = theme,
        .titlebar = opts.titlebar,
    };
}

fn intern_atoms() void {
    if (g_atom_protocols != 0) return;
    g_atom_protocols = xcb.intern_atom("WM_PROTOCOLS");
    g_atom_delete_window = xcb.intern_atom("WM_DELETE_WINDOW");
    g_atom_net_wm_name = xcb.intern_atom("_NET_WM_NAME");
    g_atom_utf8_string = xcb.intern_atom("UTF8_STRING");
    g_atom_motif_hints = xcb.intern_atom("_MOTIF_WM_HINTS");
}

fn apply_motif_undecorated(window: u32) void {
    if (g_atom_motif_hints == 0) return;
    const hints = [5]u32{ MOTIF_FLAG_DECORATIONS, 0, 0, 0, 0 };
    xcb.change_property(window, g_atom_motif_hints, g_atom_motif_hints, 32, 5, &hints);
}

fn apply_title(window: u32, title: []const u8) void {
    std.debug.assert(window != 0);
    if (title.len == 0) return;
    const len: u32 = @intCast(@min(title.len, 255));
    xcb.change_property(window, xcb.ATOM_WM_NAME, xcb.ATOM_STRING, 8, len, title.ptr);
    if (g_atom_net_wm_name != 0 and g_atom_utf8_string != 0) {
        xcb.change_property(window, g_atom_net_wm_name, g_atom_utf8_string, 8, len, title.ptr);
    }
}

fn apply_delete_protocol(window: u32) void {
    if (g_atom_protocols == 0 or g_atom_delete_window == 0) return;
    xcb.change_property(window, g_atom_protocols, xcb.ATOM_ATOM, 32, 1, &g_atom_delete_window);
}

fn pack_xrgb(rgba: types.Rgba) u32 {
    const r: u32 = @intFromFloat(@round(rgba.r * 255.0));
    const g: u32 = @intFromFloat(@round(rgba.g * 255.0));
    const b: u32 = @intFromFloat(@round(rgba.b * 255.0));
    return (r << 16) | (g << 8) | b;
}

fn alloc_window() ?*X11Window {
    for (&g_windows) |*win| {
        if (win.in_use) continue;
        win.* = .{ .in_use = true };
        return win;
    }
    return null;
}

fn destroy_window(win: *X11Window) void {
    std.debug.assert(win.in_use);
    if (win.window != 0) xcb.destroy_window(win.window);
    xcb.flush();
    win.* = .{};
    std.debug.assert(!win.in_use);
}

fn window_by_id(id: u32) ?*X11Window {
    for (&g_windows) |*win| {
        if (win.in_use and win.window == id) return win;
    }
    return null;
}

fn window_index(win: *const X11Window) u32 {
    const base = @intFromPtr(&g_windows[0]);
    const offset = @intFromPtr(win) - base;
    const index: u32 = @intCast(offset / @sizeOf(X11Window));
    std.debug.assert(index < MAX_WINDOWS);
    return index;
}

// Drains the connection's queued events; called from the run loop after the
// fd polls readable and once per tick (xcb buffers internally).
pub fn process_events() void {
    if (xcb.conn == null) return;
    var guard: u32 = 0;
    while (xcb.poll_event()) |event| : (guard += 1) {
        std.debug.assert(guard < 4096); // a tick's drain is always finite
        handle_event(event);
        xcb.free_event(event);
    }
}

fn handle_event(event: *xcb.GenericEvent) void {
    const kind = event.response_type & 0x7f;
    switch (kind) {
        xcb.CONFIGURE_NOTIFY => {
            const configure: *const xcb.ConfigureNotifyEvent = @ptrCast(event);
            const win = window_by_id(configure.window) orelse return;
            const w: i32 = @intCast(configure.width);
            const h: i32 = @intCast(configure.height);
            if (w == win.width_pt and h == win.height_pt) return;
            win.width_pt = @max(w, 1);
            win.height_pt = @max(h, 1);
            paint_now(win);
        },
        xcb.EXPOSE => {
            const expose: *const xcb.ExposeEvent = @ptrCast(event);
            const win = window_by_id(expose.window) orelse return;
            paint_now(win);
        },
        xcb.CLIENT_MESSAGE => {
            const message: *const xcb.ClientMessageEvent = @ptrCast(event);
            if (message.type != g_atom_protocols) return;
            if (message.data32[0] != g_atom_delete_window) return;
            const win = window_by_id(message.window) orelse return;
            request_close(win);
        },
        else => {},
    }
}

fn paint_now(win: *X11Window) void {
    if (!win.renderer_owned) return;
    if (g_paint_now) |paint| {
        if (win.surface_ctx orelse g_ctx) |ctx| paint(ctx);
    }
}

// Closing the first window quits the app; an extra window notifies the
// callback (which tears down its renderer) and then drops its X window,
// matching the Wayland arm.
fn request_close(win: *X11Window) void {
    std.debug.assert(win.in_use);
    if (g_window_close) |cb| {
        // register_window_close stores callback and ctx as a pair.
        std.debug.assert(g_window_close_ctx != null);
        cb(g_window_close_ctx.?, @ptrCast(win));
    }
    if (window_index(win) == 0) {
        quit_requested = true;
        return;
    }
    destroy_window(win);
}

pub fn renderer_takeover(win: *X11Window) void {
    std.debug.assert(win.in_use);
    std.debug.assert(!win.renderer_owned);
    win.renderer_owned = true;
}

pub fn register_mouse_dispatch(d: MouseDispatch) void {
    g_dispatch = d;
}

pub fn register_raw_dispatch(d: RawDispatch) void {
    g_raw = d;
}

pub fn bind_surface_ctx(handle: CustomShellHandle, ctx: *anyopaque) void {
    std.debug.assert(handle.window.in_use);
    handle.window.surface_ctx = ctx;
}

pub fn register_window_close(cb: WindowCloseFn, ctx: *anyopaque) void {
    g_window_close = cb;
    g_window_close_ctx = ctx;
}

pub fn register_hit_test(hit_test_cb: HitTestFn, redraw_cb: RedrawFn, ctx: *anyopaque) void {
    std.debug.assert(@intFromPtr(ctx) != 0);
    g_hit_test = hit_test_cb;
    g_redraw = redraw_cb;
    g_ctx = ctx;
}

pub fn register_paint_now(cb: RedrawFn) void {
    g_paint_now = cb;
}

// ---- input + system surface: the x11-input and x11-system branches ----

pub fn tick_key_repeat() void {}

pub fn set_grab(on: bool) void {
    _ = on;
}

pub fn is_grabbed() bool {
    return false;
}

pub fn release_grab_if_blurred() void {}

pub fn hovered_caption_button() CaptionButton {
    return .none;
}

pub fn apply_cursor(kind: CursorKind) void {
    g_cursor = kind;
}

pub fn current_shift_down() bool {
    return false;
}

pub fn show_text_field(
    handle: CustomShellHandle,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    initial: []const u8,
    font_size: f32,
    color: types.Rgba,
    secure: bool,
    numeric: bool,
    id: u32,
) bool {
    std.debug.assert(handle.window.in_use);
    std.debug.assert(id != 0);
    _ = x;
    _ = y;
    _ = w;
    _ = h;
    _ = initial;
    _ = font_size;
    _ = color;
    _ = secure;
    _ = numeric;
    return false;
}

pub fn hide_text_field(handle: CustomShellHandle) void {
    std.debug.assert(handle.window.in_use);
}

pub fn text_field_value(buf: []u8) []const u8 {
    _ = buf;
    return "";
}

pub fn text_field_caret() usize {
    return 0;
}

pub fn text_field_selection() [2]usize {
    return .{ 0, 0 };
}

pub fn text_field_secure() bool {
    return false;
}

pub fn pasteboard_read_into(buf: []u8) []const u8 {
    _ = buf;
    return "";
}

pub fn pasteboard_write_string(text: []const u8) void {
    _ = text;
}

pub fn clipboard_changed_external() bool {
    return false;
}

pub fn desktop_accent_color() ?types.Rgba {
    return desktop_theme.accent_color();
}

pub fn caption_slots() CaptionSlots {
    const layout = desktop_theme.caption_layout();
    std.debug.assert(layout.count >= 1);
    std.debug.assert(layout.count <= 3);
    var out = CaptionSlots{ .kinds = .{ .none, .none, .none }, .count = layout.count };
    var i: u8 = 0;
    while (i < layout.count) : (i += 1) {
        out.kinds[i] = switch (layout.kinds[layout.count - 1 - i]) {
            .minimize => .minimize,
            .maximize => .maximize,
            .close => .close,
        };
    }
    return out;
}

pub fn display_count() u32 {
    return 0;
}

pub fn display_bounds(index: u32) geometry.BoundsF {
    _ = index;
    return .{};
}
