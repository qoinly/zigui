// The X11 arm of the linux custom shell (custom_shell.zig dispatches here):
// an undecorated xcb window (motif hints strip the WM frame) carrying the
// same CSD chrome as the Wayland arm, so the two backends are visually
// identical. Covers window lifecycle, the event tap, and input routing
// (pointer, keyboard via xkbcommon, CSD drag/resize via _NET_WM_MOVERESIZE);
// the system surface (clipboard, grab, displays) is no-op stubs that keep
// the dispatcher surface complete.

const std = @import("std");
const xcb = @import("xcb.zig");
const xkb = @import("xkbcommon.zig");
const desktop_theme = @import("desktop_theme.zig");
const types = @import("../../window/types.zig");
const geometry = @import("../../geometry.zig");
const shell_types = @import("shell_types.zig");
const csd = @import("csd.zig");
const key_translate = @import("key_translate.zig");
const field = @import("field.zig");

pub const Error = shell_types.Error;
pub const ContentSize = shell_types.ContentSize;
pub const KeyMods = shell_types.KeyMods;
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
    minimized: bool = false,
    focused: bool = false,
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

// ---- pointer state ----
var g_pointer_focus: ?*X11Window = null;
var g_keyboard_focus: ?*X11Window = null;
var g_pointer_x: f32 = 0;
var g_pointer_y: f32 = 0;
var g_left_down: bool = false;
var g_shift_down: bool = false;
var g_hover_caption: CaptionButton = .none;
var g_pressed_caption: CaptionButton = .none;

// ---- keyboard state (xkbcommon over core keycodes) ----
var g_xkb_context: ?*xkb.Context = null;
var g_xkb_keymap: ?*xkb.Keymap = null;
var g_xkb_state: ?*xkb.State = null;
var g_mod_shift: u32 = xkb.MOD_INVALID;
var g_mod_ctrl: u32 = xkb.MOD_INVALID;
var g_mod_alt: u32 = xkb.MOD_INVALID;

// ---- cursor state (glyphs from the core cursor font, created lazily) ----
var g_cursor_font: u32 = 0;
var g_cursors: [3]u32 = .{ 0, 0, 0 };
var g_applied_cursor: CursorKind = .default;
// The cursor is a per-window attribute and there is one pointer, so one
// (kind, window) pair is cache enough: entering a sibling window misses on
// the window check and re-applies there.
var g_cursor_window: u32 = 0;

// Atoms interned once at connect; 0 means the intern failed and the feature
// degrades (a frame from the WM instead of none, no close message match).
var g_atom_protocols: u32 = 0;
var g_atom_delete_window: u32 = 0;
var g_atom_net_wm_name: u32 = 0;
var g_atom_utf8_string: u32 = 0;
var g_atom_motif_hints: u32 = 0;
var g_atom_moveresize: u32 = 0;
var g_atom_change_state: u32 = 0;
var g_atom_net_wm_state: u32 = 0;
var g_atom_max_horz: u32 = 0;
var g_atom_max_vert: u32 = 0;
var g_atom_state_hidden: u32 = 0;
var g_atom_state_fullscreen: u32 = 0;
var g_atom_xkb_rules: u32 = 0;

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
        return self.window.minimized;
    }

    pub fn is_key(self: CustomShellHandle) bool {
        std.debug.assert(self.window.in_use);
        return self.window.focused;
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
    if (g_xkb_state == null) rebuild_keymap();
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
    g_atom_moveresize = xcb.intern_atom("_NET_WM_MOVERESIZE");
    g_atom_change_state = xcb.intern_atom("WM_CHANGE_STATE");
    g_atom_net_wm_state = xcb.intern_atom("_NET_WM_STATE");
    g_atom_max_horz = xcb.intern_atom("_NET_WM_STATE_MAXIMIZED_HORZ");
    g_atom_max_vert = xcb.intern_atom("_NET_WM_STATE_MAXIMIZED_VERT");
    g_atom_state_hidden = xcb.intern_atom("_NET_WM_STATE_HIDDEN");
    g_atom_state_fullscreen = xcb.intern_atom("_NET_WM_STATE_FULLSCREEN");
    g_atom_xkb_rules = xcb.intern_atom("_XKB_RULES_NAMES");
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
    // The slab slot is reused by the next open(); a stale focus pointer would
    // route input into it. No leave event is guaranteed on programmatic close.
    if (g_pointer_focus == win) {
        g_pointer_focus = null;
        g_left_down = false;
        g_pressed_caption = .none;
        set_hover_caption(.none);
    }
    if (g_keyboard_focus == win) g_keyboard_focus = null;
    field.forget_window(win);
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
        xcb.MOTION_NOTIFY => on_motion(@ptrCast(event)),
        xcb.BUTTON_PRESS => on_button_press(@ptrCast(event)),
        xcb.BUTTON_RELEASE => on_button_release(@ptrCast(event)),
        xcb.ENTER_NOTIFY => on_enter(@ptrCast(event)),
        xcb.LEAVE_NOTIFY => on_leave(@ptrCast(event)),
        xcb.FOCUS_IN => on_focus(@ptrCast(event), true),
        xcb.FOCUS_OUT => on_focus(@ptrCast(event), false),
        xcb.KEY_PRESS => on_key_press(@ptrCast(event)),
        // Server-side autorepeat re-sends KeyPress while held; releases
        // carry no input of their own, so no client repeat timer exists.
        xcb.KEY_RELEASE => {},
        // A layout change invalidates the compiled keymap (core mapping or
        // xkb group switch both raise this).
        xcb.MAPPING_NOTIFY => rebuild_keymap(),
        xcb.PROPERTY_NOTIFY => on_property(@ptrCast(event)),
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

// ---- pointer ----

fn ctx_for(win: ?*X11Window, fallback: *anyopaque) *anyopaque {
    if (win) |w| {
        if (w.surface_ctx) |ctx| return ctx;
    }
    return fallback;
}

fn request_redraw() void {
    if (g_redraw) |cb| {
        if (g_ctx) |ctx| cb(ctx);
    }
}

fn caption_button_at(win: *const X11Window, x: f32, y: f32) CaptionButton {
    std.debug.assert(win.in_use);
    const w: f32 = @floatFromInt(win.width_pt);
    return csd.caption_button_at(w, g_titlebar_height, x, y);
}

fn resize_edge_at(win: *const X11Window, x: f32, y: f32) u32 {
    std.debug.assert(win.in_use);
    const w: f32 = @floatFromInt(win.width_pt);
    const h: f32 = @floatFromInt(win.height_pt);
    return csd.resize_edge_at(w, h, win.maximized or win.fullscreen, x, y);
}

// Core modifier state rides every input event: bits 0..7 are the real
// modifiers in xkb index order, bits 13..14 the layout group.
fn sync_mods(state: u16) void {
    g_shift_down = state & 1 != 0;
    const xkb_state = g_xkb_state orelse return;
    xkb.update_mask(xkb_state, state & 0xff, 0, 0, (state >> 13) & 3);
}

fn on_motion(ev: *const xcb.InputDeviceEvent) void {
    const win = window_by_id(ev.event) orelse return;
    g_pointer_focus = win;
    g_pointer_x = @floatFromInt(ev.event_x);
    g_pointer_y = @floatFromInt(ev.event_y);
    sync_mods(ev.state);
    update_hover_and_cursor(win);
    if (g_dispatch) |d| {
        const ctx = ctx_for(win, d.ctx);
        if (g_left_down) {
            d.on_drag(ctx, g_pointer_x, g_pointer_y);
        } else {
            d.on_move(ctx, g_pointer_x, g_pointer_y);
        }
    }
}

fn update_hover_and_cursor(win: *X11Window) void {
    std.debug.assert(win.in_use);
    const edge = resize_edge_at(win, g_pointer_x, g_pointer_y);
    if (edge == 4 or edge == 8) {
        set_cursor_image(win, .col_resize);
    } else if (edge == 1 or edge == 2) {
        set_cursor_image(win, .row_resize);
    } else {
        set_cursor_image(win, g_cursor);
    }
    if (g_pointer_y < g_titlebar_height and !win.fullscreen) {
        set_hover_caption(caption_button_at(win, g_pointer_x, g_pointer_y));
    } else {
        set_hover_caption(.none);
    }
}

fn set_hover_caption(button: CaptionButton) void {
    if (g_hover_caption == button) return;
    g_hover_caption = button;
    request_redraw();
}

fn on_enter(ev: *const xcb.EnterLeaveEvent) void {
    const win = window_by_id(ev.event) orelse return;
    g_pointer_focus = win;
    g_pointer_x = @floatFromInt(ev.event_x);
    g_pointer_y = @floatFromInt(ev.event_y);
    sync_mods(ev.state);
    update_hover_and_cursor(win);
}

fn on_leave(ev: *const xcb.EnterLeaveEvent) void {
    const win = window_by_id(ev.event) orelse return;
    if (g_pointer_focus != win) return;
    g_pointer_focus = null;
    g_left_down = false;
    g_pressed_caption = .none;
    set_hover_caption(.none);
    if (g_dispatch) |d| d.on_exit(ctx_for(win, d.ctx));
}

fn on_button_press(ev: *const xcb.InputDeviceEvent) void {
    const win = window_by_id(ev.event) orelse return;
    g_pointer_focus = win;
    g_pointer_x = @floatFromInt(ev.event_x);
    g_pointer_y = @floatFromInt(ev.event_y);
    sync_mods(ev.state);
    switch (ev.detail) {
        1 => handle_left_press(win, ev),
        3 => if (g_dispatch) |d| {
            d.on_right_down(ctx_for(win, d.ctx), g_pointer_x, g_pointer_y);
        },
        // Core wheel buttons, one detent per press: 4 up, 5 down, 6 left,
        // 7 right; signs match the Wayland arm's discrete-axis mapping.
        4 => scroll(win, 0, shell_types.WHEEL_NOTCH_PT),
        5 => scroll(win, 0, -shell_types.WHEEL_NOTCH_PT),
        6 => scroll(win, shell_types.WHEEL_NOTCH_PT, 0),
        7 => scroll(win, -shell_types.WHEEL_NOTCH_PT, 0),
        else => {},
    }
}

fn scroll(win: *X11Window, dx: f32, dy: f32) void {
    std.debug.assert(win.in_use);
    const d = g_dispatch orelse return;
    d.on_scroll(ctx_for(win, d.ctx), dx, dy);
}

fn handle_left_press(win: *X11Window, ev: *const xcb.InputDeviceEvent) void {
    std.debug.assert(win.in_use);
    const x = g_pointer_x;
    const y = g_pointer_y;
    const edge = resize_edge_at(win, x, y);
    if (edge != 0) {
        start_move_resize(win, ev, moveresize_direction(edge));
        return;
    }
    if (y < g_titlebar_height and !win.fullscreen) {
        const button = caption_button_at(win, x, y);
        if (button != .none) {
            g_pressed_caption = button;
            return;
        }
        const over_control = if (g_hit_test) |ht|
            if (g_ctx) |ctx| ht(ctx, x, y, g_titlebar_height) else false
        else
            false;
        if (!over_control) {
            // Empty band area drags the window; the WM takes the pointer
            // over (a leave event follows).
            start_move_resize(win, ev, MOVERESIZE_MOVE);
            return;
        }
    }
    g_left_down = true;
    if (g_dispatch) |d| d.on_down(ctx_for(win, d.ctx), x, y);
}

fn on_button_release(ev: *const xcb.InputDeviceEvent) void {
    const win = window_by_id(ev.event) orelse return;
    if (ev.detail != 1) return;
    sync_mods(ev.state);
    handle_left_release(win);
}

fn handle_left_release(win: *X11Window) void {
    std.debug.assert(win.in_use);
    const pressed = g_pressed_caption;
    g_pressed_caption = .none;
    if (pressed != .none) {
        if (caption_button_at(win, g_pointer_x, g_pointer_y) == pressed) {
            perform_caption_action(win, pressed);
        }
        return;
    }
    if (!g_left_down) return;
    g_left_down = false;
    if (g_dispatch) |d| d.on_up(ctx_for(win, d.ctx));
}

fn perform_caption_action(win: *X11Window, button: CaptionButton) void {
    std.debug.assert(win.in_use);
    std.debug.assert(button != .none);
    switch (button) {
        .minimize => {
            // ICCCM WM_CHANGE_STATE with IconicState(3); EWMH kept it as
            // THE iconify request.
            if (g_atom_change_state == 0) return;
            send_net_message(win.window, g_atom_change_state, .{ 3, 0, 0, 0, 0 });
            xcb.flush();
        },
        .maximize => {
            if (g_atom_net_wm_state == 0) return;
            const TOGGLE: u32 = 2;
            send_net_message(
                win.window,
                g_atom_net_wm_state,
                .{ TOGGLE, g_atom_max_horz, g_atom_max_vert, 1, 0 },
            );
            xcb.flush();
        },
        .close => request_close(win),
        .none => {},
    }
}

// _NET_WM_MOVERESIZE directions for the xdg edge codes csd.resize_edge_at
// returns (top=1 bottom=2 left=4 right=8, corners OR'd).
const MOVERESIZE_MOVE: u32 = 8;

fn moveresize_direction(edge: u32) u32 {
    std.debug.assert(edge >= 1);
    std.debug.assert(edge <= 10);
    return switch (edge) {
        1 => 1, // top
        2 => 5, // bottom
        4 => 7, // left
        8 => 3, // right
        5 => 0, // top-left
        9 => 2, // top-right
        6 => 6, // bottom-left
        10 => 4, // bottom-right
        else => unreachable, // csd never returns 3, 7, or 11+
    };
}

fn start_move_resize(win: *X11Window, ev: *const xcb.InputDeviceEvent, direction: u32) void {
    std.debug.assert(win.in_use);
    std.debug.assert(direction <= MOVERESIZE_MOVE);
    if (g_atom_moveresize == 0) return;
    // EWMH requires the client to drop its implicit button grab first, or
    // the WM cannot take the drag over.
    xcb.ungrab_pointer(ev.time);
    send_net_message(win.window, g_atom_moveresize, .{
        @bitCast(@as(i32, ev.root_x)),
        @bitCast(@as(i32, ev.root_y)),
        direction,
        1,
        1,
    });
    xcb.flush();
    set_hover_caption(.none);
}

// Builds the 32-byte ClientMessage wire event the EWMH root-window
// protocols expect; u32-backed so the event view is properly aligned.
fn send_net_message(window: u32, message_type: u32, data: [5]u32) void {
    std.debug.assert(window != 0);
    std.debug.assert(message_type != 0);
    var buf = [_]u32{0} ** 8;
    const message: *xcb.ClientMessageEvent = @ptrCast(&buf);
    message.response_type = xcb.CLIENT_MESSAGE;
    message.format = 32;
    message.window = window;
    message.type = message_type;
    message.data32 = data;
    xcb.send_event_to_root(@ptrCast(&buf));
}

// ---- cursor ----

fn set_cursor_image(win: *X11Window, kind: CursorKind) void {
    std.debug.assert(win.in_use);
    if (kind == g_applied_cursor and win.window == g_cursor_window) return;
    const cursor = ensure_cursor(kind) orelse return;
    xcb.set_window_cursor(win.window, cursor);
    xcb.flush();
    g_applied_cursor = kind;
    g_cursor_window = win.window;
}

fn ensure_cursor(kind: CursorKind) ?u32 {
    const index: usize = @intFromEnum(kind);
    std.debug.assert(index < g_cursors.len);
    if (g_cursors[index] != 0) return g_cursors[index];
    if (xcb.conn == null) return null;
    if (g_cursor_font == 0) {
        g_cursor_font = xcb.generate_id();
        xcb.open_font(g_cursor_font, "cursor");
    }
    // Core cursor font glyphs: left_ptr, sb_h_double_arrow, sb_v_double_arrow.
    const glyph: u16 = switch (kind) {
        .default => 68,
        .col_resize => 108,
        .row_resize => 116,
    };
    const id = xcb.generate_id();
    xcb.create_glyph_cursor(id, g_cursor_font, glyph);
    g_cursors[index] = id;
    return id;
}

// ---- keyboard ----

// No compositor hands X11 clients a keymap; compile one from the server's
// _XKB_RULES_NAMES root property (RMLVO), falling back to xkbcommon's
// defaults when the property is missing. Core keycodes ARE xkb keycodes.
fn rebuild_keymap() void {
    xkb.load() catch return; // without xkbcommon key input degrades to none
    if (g_xkb_context == null) g_xkb_context = xkb.context_new();
    const context = g_xkb_context orelse return;
    var names_buf: [1024]u8 = undefined;
    var names = xkb.RuleNames{};
    if (g_atom_xkb_rules != 0) {
        const root = xcb.screen.?.root;
        if (xcb.get_property_into(root, g_atom_xkb_rules, xcb.ATOM_STRING, &names_buf)) |raw| {
            fill_rule_names(&names, raw);
        }
    }
    const keymap = xkb.keymap_from_names(context, &names) orelse return;
    const state = xkb.state_new(keymap) orelse {
        xkb.keymap_unref(keymap);
        return;
    };
    if (g_xkb_state) |old| xkb.state_unref(old);
    if (g_xkb_keymap) |old| xkb.keymap_unref(old);
    g_xkb_keymap = keymap;
    g_xkb_state = state;
    g_mod_shift = xkb.mod_index(keymap, "Shift");
    g_mod_ctrl = xkb.mod_index(keymap, "Control");
    g_mod_alt = xkb.mod_index(keymap, "Mod1");
}

// The property is five NUL-terminated strings back to back: rules, model,
// layout, variant, options. Empty fields stay null (xkbcommon defaults).
fn fill_rule_names(names: *xkb.RuleNames, raw: []const u8) void {
    var fields: [5]?[*:0]const u8 = .{ null, null, null, null, null };
    var slot: usize = 0;
    var start: usize = 0;
    for (raw, 0..) |byte, index| {
        if (byte != 0) continue;
        if (slot == fields.len) break;
        if (index > start) fields[slot] = @ptrCast(raw.ptr + start);
        slot += 1;
        start = index + 1;
    }
    names.rules = fields[0];
    names.model = fields[1];
    names.layout = fields[2];
    names.variant = fields[3];
    names.options = fields[4];
}

fn on_key_press(ev: *const xcb.InputDeviceEvent) void {
    const win = window_by_id(ev.event) orelse return;
    g_keyboard_focus = win;
    sync_mods(ev.state);
    const xkb_state = g_xkb_state orelse return;
    const keycode: u32 = ev.detail;
    std.debug.assert(keycode >= 8);
    const sym = xkb.key_sym(xkb_state, keycode);
    const mods = KeyMods{
        // Ctrl IS the command modifier here (the windows mapping): cmd alone,
        // ctrl left false - the kit's cmd-keyed shortcuts gate on !ctrl, so
        // setting both would suppress copy/cut/paste everywhere.
        .cmd = xkb.mod_active(xkb_state, g_mod_ctrl),
        .shift = xkb.mod_active(xkb_state, g_mod_shift),
        .alt = xkb.mod_active(xkb_state, g_mod_alt),
        .ctrl = false,
    };
    const event = key_translate.key_event_for(sym, keycode, xkb_state, mods) orelse return;
    // The visible editor is the windows EDIT child with focus: it consumes
    // every key; widget dispatch resumes when the field hides.
    if (field.consumes_key(g_keyboard_focus)) {
        field.apply_key(event, field_clipboard);
        return;
    }
    if (g_dispatch) |d| d.on_key(ctx_for(win, d.ctx), event);
}

// ---- focus + window state ----

fn on_focus(ev: *const xcb.FocusEvent, gained: bool) void {
    // Grab transients (mode 1/2) bracket every WM drag; only real focus
    // changes (Normal/WhileGrabbed) move the keyboard.
    if (ev.mode == 1 or ev.mode == 2) return;
    const win = window_by_id(ev.event) orelse return;
    if (win.focused == gained) return;
    win.focused = gained;
    if (gained) {
        g_keyboard_focus = win;
        refresh_desktop_prefs();
    } else if (g_keyboard_focus == win) {
        g_keyboard_focus = null;
    }
    request_redraw();
}

// Focus gain is the moment a user returns from the settings panel, so the
// accent and button-layout caches re-resolve here; the throttle keeps an
// alt-tab storm from spawning a gsettings process per switch.
const PREFS_REFRESH_MIN_MS: i64 = 1000;
var g_prefs_refresh_ms: i64 = 0;

extern "c" fn clock_gettime(clockid: c_int, tp: *prefs_timespec) c_int;
const prefs_timespec = extern struct { tv_sec: i64, tv_nsec: i64 };
const CLOCK_MONOTONIC_RAW: c_int = 4;

fn now_ms() i64 {
    var ts: prefs_timespec = undefined;
    const rc = clock_gettime(CLOCK_MONOTONIC_RAW, &ts);
    std.debug.assert(rc == 0); // fails only for an invalid clock id
    return ts.tv_sec * 1000 + @divTrunc(ts.tv_nsec, 1_000_000);
}

fn refresh_desktop_prefs() void {
    const now = now_ms();
    if (now - g_prefs_refresh_ms < PREFS_REFRESH_MIN_MS) return;
    g_prefs_refresh_ms = now;
    desktop_theme.refresh();
}

fn on_property(ev: *const xcb.PropertyNotifyEvent) void {
    if (ev.atom == 0 or ev.atom != g_atom_net_wm_state) return;
    const win = window_by_id(ev.window) orelse return;
    refresh_wm_state(win);
}

// The WM owns maximize/fullscreen/iconify on X11; _NET_WM_STATE on our
// window is the single source of truth, re-read whenever it changes.
fn refresh_wm_state(win: *X11Window) void {
    std.debug.assert(win.in_use);
    var buf: [64]u32 = undefined; // _NET_WM_STATE rarely exceeds a dozen atoms
    const raw = xcb.get_property_into(
        win.window,
        g_atom_net_wm_state,
        xcb.ATOM_ATOM,
        std.mem.sliceAsBytes(buf[0..]),
    ) orelse return apply_wm_state(win, false, false, false);
    var horz = false;
    var vert = false;
    var full = false;
    var hidden = false;
    const atoms = buf[0 .. raw.len / 4];
    for (atoms) |atom| {
        if (atom == g_atom_max_horz) horz = true;
        if (atom == g_atom_max_vert) vert = true;
        if (atom == g_atom_state_fullscreen) full = true;
        if (atom == g_atom_state_hidden) hidden = true;
    }
    apply_wm_state(win, horz and vert, full, hidden);
}

fn apply_wm_state(win: *X11Window, maximized: bool, fullscreen: bool, minimized: bool) void {
    std.debug.assert(win.in_use);
    const changed = maximized != win.maximized or
        fullscreen != win.fullscreen or minimized != win.minimized;
    win.maximized = maximized;
    win.fullscreen = fullscreen;
    win.minimized = minimized;
    if (changed) request_redraw();
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

// The X server repeats held keys itself (KeyPress re-sent at the user's
// rate), so the Wayland arm's client timer has no X11 counterpart.
pub fn tick_key_repeat() void {}

pub fn hovered_caption_button() CaptionButton {
    return g_hover_caption;
}

pub fn apply_cursor(kind: CursorKind) void {
    g_cursor = kind;
    const win = g_pointer_focus orelse return;
    update_hover_and_cursor(win);
}

pub fn current_shift_down() bool {
    return g_shift_down;
}

// ---- system surface (no-op stubs) ----

pub fn set_grab(on: bool) void {
    _ = on;
}

pub fn is_grabbed() bool {
    return false;
}

pub fn release_grab_if_blurred() void {}

// ---- text field (the singleton editor) ----

// The editing engine lives in field.zig (shared with the Wayland arm); this
// arm contributes the key-window gate. The clipboard is not wired on X11,
// so paste/copy quietly no-op.

const field_clipboard = field.Clipboard{
    .read_into = pasteboard_read_into,
    .write_string = pasteboard_write_string,
};

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
    // Geometry and style are the kit's to draw; only the macOS key-window
    // gate matters here: a background window must not steal the editor.
    _ = x;
    _ = y;
    _ = w;
    _ = h;
    _ = font_size;
    _ = color;
    if (g_keyboard_focus != handle.window) return false;
    field.show(handle.window, initial, secure, numeric, id);
    return true;
}

pub fn hide_text_field(handle: CustomShellHandle) void {
    std.debug.assert(handle.window.in_use);
    field.hide(handle.window);
}

pub fn text_field_value(buf: []u8) []const u8 {
    return field.value(buf);
}

pub fn text_field_caret() usize {
    return field.caret();
}

pub fn text_field_selection() [2]usize {
    return field.selection();
}

pub fn text_field_secure() bool {
    return field.secure();
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

pub fn display_count() u32 {
    return 0;
}

pub fn display_bounds(index: u32) geometry.BoundsF {
    _ = index;
    return .{};
}
