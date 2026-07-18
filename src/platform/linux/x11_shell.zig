// The X11 arm of the linux custom shell (custom_shell.zig dispatches here):
// an undecorated xcb window (motif hints strip the WM frame) carrying the
// same CSD chrome as the Wayland arm, so the two backends are visually
// identical. Covers window lifecycle, the event tap, input routing
// (pointer, keyboard via xkbcommon, CSD drag/resize via _NET_WM_MOVERESIZE),
// and the system surface: clipboard selections, the raw-capture pointer
// grab (XInput2 raw motion), RandR displays, EWMH fullscreen, and the
// Xft.dpi integer scale.

const std = @import("std");
const xcb = @import("xcb.zig");
const xcb_randr = @import("xcb_randr.zig");
const xcb_xfixes = @import("xcb_xfixes.zig");
const xcb_input = @import("xcb_input.zig");
const xkb = @import("xkbcommon.zig");
const desktop_theme = @import("desktop_theme.zig");
const types = @import("../../window/types.zig");
const input = @import("../../input.zig");
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
    // Set by configure/expose during an event drain; the drain paints once at the
    // end (coalesced) instead of per event, so a resize storm doesn't trigger one
    // full relayout + swapchain recreate per intermediate size.
    needs_paint: bool = false,
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
var g_atom_clipboard: u32 = 0;
var g_atom_targets: u32 = 0;
var g_atom_incr: u32 = 0;
var g_atom_text: u32 = 0;
var g_atom_clip_prop: u32 = 0;

// ---- XDND (drag-and-drop of files onto the window) ----
var g_atom_xdnd_aware: u32 = 0;
var g_atom_xdnd_enter: u32 = 0;
var g_atom_xdnd_position: u32 = 0;
var g_atom_xdnd_status: u32 = 0;
var g_atom_xdnd_drop: u32 = 0;
var g_atom_xdnd_finished: u32 = 0;
var g_atom_xdnd_selection: u32 = 0;
var g_atom_xdnd_action_copy: u32 = 0;
var g_atom_xdnd_type_list: u32 = 0;
var g_atom_uri_list: u32 = 0;
var g_atom_xdnd_prop: u32 = 0;
// The in-flight drag: the source window and whether it offered text/uri-list, kept
// from XdndEnter to the XdndDrop's selection reply.
var g_xdnd_source: u32 = 0;
var g_xdnd_win: u32 = 0;
var g_xdnd_accept: bool = false;
var g_xdnd_x: f32 = 0;
var g_xdnd_y: f32 = 0;
var g_xdnd_scratch: [16384]u8 = undefined; // the dropped uri-list (own buffer, not the clipboard's)

// ---- clipboard state (the X CLIPBOARD selection) ----
const MAX_CLIPBOARD_BYTES: usize = 64 * 1024;
const CLIPBOARD_POLL_MS: c_int = 10;
const CLIPBOARD_POLL_MAX: u32 = 50;
const INCR_CHUNKS_MAX: u32 = 64;

var g_own_active: bool = false;
var g_own_text: [MAX_CLIPBOARD_BYTES]u8 = undefined;
var g_own_len: usize = 0;
var g_clipboard_seq: u32 = 0;
var g_clipboard_seen: u32 = 0;
var g_clipboard_own_seq: u32 = 0;
var g_clipboard_primed: bool = false;
var g_own_echo_pending: bool = false;
var g_clip_reading: bool = false;
var g_selection_notify: ?xcb.SelectionNotifyEvent = null;
var g_incr_chunk_ready: bool = false;
// One static scratch for property reads: the read path is single-threaded
// (g_clip_reading guards reentry) and two stack copies would cost 128KiB.
var g_clip_scratch: [MAX_CLIPBOARD_BYTES]u8 = undefined;

// ---- grab state (raw capture, the windows RegisterRawInputDevices model) ----
var g_grabbed: bool = false;
var g_grab_win: ?*X11Window = null;
var g_raw_mods: input.Mods = .{};
var g_mod_caps: u32 = xkb.MOD_INVALID;
var g_blank_cursor: u32 = 0;
var g_xi_ready: bool = false;

// The Xft.dpi integer scale resolved once at connect; X11 has no per-output
// scale protocol, so every window shares it (the windows DPI model).
var g_scale: i32 = 1;

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

    // The WM owns the transition; win.fullscreen flips when the resulting
    // _NET_WM_STATE PropertyNotify lands.
    pub fn set_fullscreen(self: CustomShellHandle, on: bool) void {
        std.debug.assert(self.window.in_use);
        if (g_atom_net_wm_state == 0 or g_atom_state_fullscreen == 0) return;
        const action: u32 = @intFromBool(on); // _NET_WM_STATE_REMOVE / _ADD
        send_net_message(
            self.window.window,
            g_atom_net_wm_state,
            .{ action, g_atom_state_fullscreen, 0, 1, 0 },
        );
        xcb.flush();
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
    init_extensions();
    resolve_scale();
    _ = desktop_theme.accent_color(); // warm the resolve outside the paint tick
    std.debug.assert(opts.width > 0);
    std.debug.assert(opts.height > 0);
    g_titlebar_height = @floatCast(opts.titlebar.height);

    const win = alloc_window() orelse return error.WindowCreateFailed;
    errdefer destroy_window(win);
    const theme = opts.theme orelse types.Theme.default_dark();
    win.width_pt = @intFromFloat(opts.width);
    win.height_pt = @intFromFloat(opts.height);
    win.scale = g_scale;
    win.window = xcb.generate_id();
    // The wire size is u16; the scale clamp (<=4) keeps any sane point
    // size inside it, asserted rather than silently truncated.
    std.debug.assert(win.width_pt * win.scale <= 0xFFFF);
    std.debug.assert(win.height_pt * win.scale <= 0xFFFF);
    xcb.create_window(
        win.window,
        @intCast(win.width_pt * win.scale),
        @intCast(win.height_pt * win.scale),
        pack_xrgb(theme.background),
    );
    apply_motif_undecorated(win.window);
    apply_title(win.window, opts.title);
    apply_delete_protocol(win.window);
    apply_xdnd_aware(win.window);
    apply_size_hints(
        win.window,
        @intCast(@as(i32, @intFromFloat(opts.min_width)) * win.scale),
        @intCast(@as(i32, @intFromFloat(opts.min_height)) * win.scale),
    );
    if (xcb_xfixes.first_event != 0 and g_atom_clipboard != 0) {
        xcb_xfixes.watch_selection(win.window, g_atom_clipboard);
    }
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

// Extensions are conveniences, never requirements: a server without any of
// them still gets windows, input, and a working (poll-based) clipboard.
fn init_extensions() void {
    xcb_randr.load() catch {};
    xcb_xfixes.load() catch {};
    xcb_input.load() catch {};
}

// Xft.dpi from the root RESOURCE_MANAGER property, the place desktops
// publish the user's scale on X11 (Cinnamon writes 192 for 2x). Integer
// scale only; fractional values round to the nearest whole step.
fn resolve_scale() void {
    const RESOURCE_MANAGER: u32 = 23;
    var buf: [16 * 1024]u8 = undefined;
    const screen = xcb.screen orelse return;
    const value = xcb.read_property(screen.root, RESOURCE_MANAGER, false, &buf) orelse return;
    const parsed = parse_xft_dpi(value.bytes) orelse return;
    // The property is writable by any client: bound the value BEFORE the
    // rounding arithmetic so a hostile dpi cannot overflow it.
    const dpi = std.math.clamp(parsed, 1, 960);
    g_scale = std.math.clamp(@divTrunc(dpi + 48, 96), 1, 4);
    std.debug.assert(g_scale >= 1);
    std.debug.assert(g_scale <= 4);
}

fn parse_xft_dpi(text: []const u8) ?i32 {
    const prefix = "Xft.dpi:";
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, prefix)) continue;
        const trimmed = std.mem.trim(u8, line[prefix.len..], " \t");
        return std.fmt.parseInt(i32, trimmed, 10) catch null;
    }
    return null;
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
    g_atom_clipboard = xcb.intern_atom("CLIPBOARD");
    g_atom_targets = xcb.intern_atom("TARGETS");
    g_atom_incr = xcb.intern_atom("INCR");
    g_atom_text = xcb.intern_atom("TEXT");
    g_atom_clip_prop = xcb.intern_atom("ZIGUI_CLIP");
    g_atom_xdnd_aware = xcb.intern_atom("XdndAware");
    g_atom_xdnd_enter = xcb.intern_atom("XdndEnter");
    g_atom_xdnd_position = xcb.intern_atom("XdndPosition");
    g_atom_xdnd_status = xcb.intern_atom("XdndStatus");
    g_atom_xdnd_drop = xcb.intern_atom("XdndDrop");
    g_atom_xdnd_finished = xcb.intern_atom("XdndFinished");
    g_atom_xdnd_selection = xcb.intern_atom("XdndSelection");
    g_atom_xdnd_action_copy = xcb.intern_atom("XdndActionCopy");
    g_atom_xdnd_type_list = xcb.intern_atom("XdndTypeList");
    g_atom_uri_list = xcb.intern_atom("text/uri-list");
    g_atom_xdnd_prop = xcb.intern_atom("ZIGUI_XDND");
}

// Advertise XDND v5 so file managers offer file drops onto this window.
fn apply_xdnd_aware(window: u32) void {
    if (g_atom_xdnd_aware == 0) return;
    const version: u32 = 5;
    xcb.change_property(window, g_atom_xdnd_aware, xcb.ATOM_ATOM, 32, 1, &version);
}

// WM_NORMAL_HINTS with PMinSize so the window manager refuses to resize below the min. The property
// is the ICCCM WM_SIZE_HINTS wire format: 18 CARD32s, min_width/min_height at slots 5/6.
fn apply_size_hints(window: u32, min_w: u32, min_h: u32) void {
    const P_MIN_SIZE: u32 = 16;
    var hints = [_]u32{0} ** 18;
    hints[0] = P_MIN_SIZE;
    hints[5] = min_w;
    hints[6] = min_h;
    xcb.change_property(window, xcb.ATOM_WM_NORMAL_HINTS, xcb.ATOM_WM_SIZE_HINTS, 32, 18, &hints);
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

// The global callback ctx pointers may still name the closing window's
// (freed) paint; repoint them at the root window so the next hover or key
// does not dispatch into torn-down state.
fn retire_surface_ctx(win: *X11Window) void {
    const closing = win.surface_ctx orelse return;
    const root = &g_windows[0];
    const fallback = if (root != win and root.in_use) root.surface_ctx else null;
    if (g_ctx == closing) g_ctx = fallback;
    if (g_dispatch) |*d| {
        if (d.ctx == closing) {
            if (fallback) |f| d.ctx = f;
        }
    }
    if (g_raw) |*d| {
        if (d.ctx == closing) {
            if (fallback) |f| d.ctx = f;
        }
    }
    win.surface_ctx = null;
}

fn destroy_window(win: *X11Window) void {
    std.debug.assert(win.in_use);
    retire_surface_ctx(win);
    // The slab slot is reused by the next open(); a stale focus pointer would
    // route input into it. No leave event is guaranteed on programmatic close.
    if (g_pointer_focus == win) {
        g_pointer_focus = null;
        g_left_down = false;
        g_pressed_caption = .none;
        set_hover_caption(.none);
    }
    if (g_keyboard_focus == win) g_keyboard_focus = null;
    if (g_grab_win == win) set_grab(false);
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
    // Coalesced paint: one repaint per window per drain, so a burst of
    // ConfigureNotify/Expose events collapses to a single relayout + render at the
    // final size rather than one per intermediate event (the resize-storm hot path).
    for (&g_windows) |*win| {
        if (win.in_use and win.needs_paint) {
            win.needs_paint = false;
            paint_now(win);
        }
    }
}

fn handle_event(event: *xcb.GenericEvent) void {
    const kind = event.response_type & 0x7f;
    switch (kind) {
        xcb.CONFIGURE_NOTIFY => {
            const configure: *const xcb.ConfigureNotifyEvent = @ptrCast(event);
            const win = window_by_id(configure.window) orelse return;
            std.debug.assert(win.scale >= 1);
            const w = @max(@divTrunc(@as(i32, @intCast(configure.width)), win.scale), 1);
            const h = @max(@divTrunc(@as(i32, @intCast(configure.height)), win.scale), 1);
            if (w == win.width_pt and h == win.height_pt) return;
            win.width_pt = w;
            win.height_pt = h;
            win.needs_paint = true; // coalesced: painted once after the drain
        },
        xcb.EXPOSE => {
            const expose: *const xcb.ExposeEvent = @ptrCast(event);
            const win = window_by_id(expose.window) orelse return;
            win.needs_paint = true; // coalesced: painted once after the drain
        },
        xcb.CLIENT_MESSAGE => {
            const message: *const xcb.ClientMessageEvent = @ptrCast(event);
            if (message.type == g_atom_xdnd_enter) return xdnd_enter(message);
            if (message.type == g_atom_xdnd_position) return xdnd_position(message);
            if (message.type == g_atom_xdnd_drop) return xdnd_drop(message);
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
        xcb.KEY_RELEASE => on_key_release(@ptrCast(event)),
        // A layout change invalidates the compiled keymap (core mapping or
        // xkb group switch both raise this).
        xcb.MAPPING_NOTIFY => rebuild_keymap(),
        xcb.PROPERTY_NOTIFY => on_property(@ptrCast(event)),
        xcb.SELECTION_REQUEST => on_selection_request(@ptrCast(event)),
        xcb.SELECTION_CLEAR => on_selection_clear(@ptrCast(event)),
        // Replies to our convert_selection; the read loop consumes the stash.
        xcb.SELECTION_NOTIFY => {
            const notify: *const xcb.SelectionNotifyEvent = @ptrCast(event);
            if (notify.selection == g_atom_xdnd_selection) return xdnd_selection_notify(notify);
            g_selection_notify = notify.*;
        },
        xcb.GE_GENERIC => on_ge_event(@ptrCast(event)),
        else => on_extension_event(kind),
    }
}

// XFixes selection events land at a runtime offset (first_event), so they
// route from the switch's else arm.
fn on_extension_event(kind: u8) void {
    if (xcb_xfixes.first_event == 0 or kind != xcb_xfixes.first_event) return;
    g_clipboard_seq +%= 1;
    if (g_own_echo_pending) {
        g_clipboard_own_seq = g_clipboard_seq;
        g_own_echo_pending = false;
    }
}

fn on_ge_event(event: *const xcb.GeGenericEvent) void {
    if (xcb_input.opcode == 0 or event.extension != xcb_input.opcode) return;
    if (event.event_type != xcb_input.RAW_MOTION) return;
    if (!g_grabbed) return;
    const d = g_raw orelse return;
    const delta = xcb_input.raw_motion_delta(event);
    if (delta.dx == 0 and delta.dy == 0) return;
    // Unaccelerated deltas: the remote end applies its own pointer
    // ballistics, the same channel windows raw input reports.
    d.on_event(ctx_for(g_grab_win, d.ctx), .{ .motion = .{
        .dx = delta.dx,
        .dy = delta.dy,
    } });
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

fn px_to_pt(win: *const X11Window, value: i16) f32 {
    std.debug.assert(win.scale >= 1);
    return @as(f32, @floatFromInt(value)) / @as(f32, @floatFromInt(win.scale));
}

fn on_motion(ev: *const xcb.InputDeviceEvent) void {
    if (g_grabbed) return; // a grabbed pointer reports motion only via XI raw
    const win = window_by_id(ev.event) orelse return;
    g_pointer_focus = win;
    g_pointer_x = px_to_pt(win, ev.event_x);
    g_pointer_y = px_to_pt(win, ev.event_y);
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
    g_pointer_x = px_to_pt(win, ev.event_x);
    g_pointer_y = px_to_pt(win, ev.event_y);
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
    if (g_grabbed) {
        raw_button_event(ev.detail, true);
        return;
    }
    const win = window_by_id(ev.event) orelse return;
    g_pointer_focus = win;
    g_pointer_x = px_to_pt(win, ev.event_x);
    g_pointer_y = px_to_pt(win, ev.event_y);
    sync_mods(ev.state);
    switch (ev.detail) {
        1 => handle_left_press(win, ev),
        2 => if (g_dispatch) |d| {
            d.on_middle_down(ctx_for(win, d.ctx), g_pointer_x, g_pointer_y);
        },
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
    if (g_grabbed) {
        raw_button_event(ev.detail, false);
        return;
    }
    const win = window_by_id(ev.event) orelse return;
    if (ev.detail != 1) return;
    sync_mods(ev.state);
    handle_left_release(win);
}

fn raw_button_event(button: u8, down: bool) void {
    std.debug.assert(g_grabbed);
    const d = g_raw orelse return;
    const ctx = ctx_for(g_grab_win, d.ctx);
    // Wheel detents stream as wheel events, not buttons, mirroring the
    // Wayland arm's grabbed-axis path.
    if (button >= 4 and button <= 7) {
        if (!down) return;
        const notch = shell_types.WHEEL_NOTCH_PT;
        const ev: input.InputEvent = switch (button) {
            4 => .{ .wheel = .{ .dx = 0, .dy = notch } },
            5 => .{ .wheel = .{ .dx = 0, .dy = -notch } },
            6 => .{ .wheel = .{ .dx = notch, .dy = 0 } },
            else => .{ .wheel = .{ .dx = -notch, .dy = 0 } },
        };
        d.on_event(ctx, ev);
        return;
    }
    const mapped: input.Button = switch (button) {
        1 => .left,
        2 => .middle,
        3 => .right,
        else => .other,
    };
    d.on_event(ctx, .{ .button = .{
        .button = mapped,
        .down = down,
        .mods = g_raw_mods,
    } });
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

// ---- XDND target: receive a file drop (advertised via apply_xdnd_aware) ----

fn xdnd_enter(m: *const xcb.ClientMessageEvent) void {
    g_xdnd_source = m.data32[0];
    g_xdnd_win = m.window;
    g_xdnd_accept = false;
    if ((m.data32[1] & 1) == 0) {
        // Up to three offered types are inline in data32[2..5].
        for (m.data32[2..5]) |ty| {
            if (ty != 0 and ty == g_atom_uri_list) g_xdnd_accept = true;
        }
    } else {
        // More than three types: read the full list from the source's XdndTypeList.
        var buf: [1024]u8 = undefined;
        if (xcb.get_property_into(g_xdnd_source, g_atom_xdnd_type_list, xcb.ATOM_ATOM, &buf)) |bytes| {
            var i: usize = 0;
            while (i + 4 <= bytes.len) : (i += 4) {
                if (std.mem.readInt(u32, bytes[i..][0..4], .little) == g_atom_uri_list) g_xdnd_accept = true;
            }
        }
    }
}

fn xdnd_position(m: *const xcb.ClientMessageEvent) void {
    // data32[2] packs the pointer's root coords as (x << 16 | y).
    const packed_xy = m.data32[2];
    g_xdnd_x = @floatFromInt(@as(u16, @truncate(packed_xy >> 16)));
    g_xdnd_y = @floatFromInt(@as(u16, @truncate(packed_xy & 0xffff)));
    // Reply with our willingness: accept the whole window (no per-region rects).
    const accept: u32 = if (g_xdnd_accept) 1 else 0;
    const action: u32 = if (g_xdnd_accept) g_atom_xdnd_action_copy else 0;
    send_client_message(g_xdnd_source, g_atom_xdnd_status, .{ m.window, accept, 0, 0, action });
}

fn xdnd_drop(m: *const xcb.ClientMessageEvent) void {
    if (!g_xdnd_accept or g_xdnd_source == 0) {
        send_client_message(m.data32[0], g_atom_xdnd_finished, .{ m.window, 0, 0, 0, 0 });
        g_xdnd_source = 0;
        return;
    }
    // Ask the source for the file list; the reply arrives as SELECTION_NOTIFY below.
    xcb.convert_selection(m.window, g_atom_xdnd_selection, g_atom_uri_list, g_atom_xdnd_prop);
    xcb.flush();
}

fn xdnd_selection_notify(n: *const xcb.SelectionNotifyEvent) void {
    var delivered = false;
    if (n.property != 0) {
        if (xcb.read_property(n.requestor, g_atom_xdnd_prop, true, &g_xdnd_scratch)) |pv| {
            if (pv.bytes.len > 0) if (g_dispatch) |d| {
                const win = window_by_id(n.requestor);
                d.on_file_drop(ctx_for(win, d.ctx), pv.bytes.ptr, pv.bytes.len, g_xdnd_x, g_xdnd_y);
                delivered = true;
            };
        }
    }
    // Tell the source the transfer finished (accepted iff we delivered the data).
    if (g_xdnd_source != 0) {
        const flags: u32 = if (delivered) 1 else 0;
        const action: u32 = if (delivered) g_atom_xdnd_action_copy else 0;
        send_client_message(g_xdnd_source, g_atom_xdnd_finished, .{ g_xdnd_win, flags, action, 0, 0 });
    }
    g_xdnd_source = 0;
    g_xdnd_accept = false;
}

// A 32-byte ClientMessage delivered to one window (the XDND status/finished replies).
fn send_client_message(dest: u32, message_type: u32, data: [5]u32) void {
    if (dest == 0 or message_type == 0) return;
    var buf = [_]u32{0} ** 8;
    const message: *xcb.ClientMessageEvent = @ptrCast(&buf);
    message.response_type = xcb.CLIENT_MESSAGE;
    message.format = 32;
    message.window = dest;
    message.type = message_type;
    message.data32 = data;
    xcb.send_event_to(dest, @ptrCast(&buf));
    xcb.flush();
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
    g_mod_caps = xkb.mod_index(keymap, "Lock");
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
    if (g_grabbed) {
        raw_key_event(@as(u32, ev.detail) - 8, true);
        return;
    }
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

// Server-side autorepeat re-sends KeyPress while held; outside a grab a
// release carries no input of its own, so no client repeat timer exists.
fn on_key_release(ev: *const xcb.InputDeviceEvent) void {
    if (!g_grabbed) return;
    raw_key_event(@as(u32, ev.detail) - 8, false);
}

fn raw_key_event(key: u32, down: bool) void {
    std.debug.assert(g_grabbed);
    key_translate.update_raw_mods(&g_raw_mods, key, down, g_xkb_state, g_mod_caps);
    if (down and key == key_translate.KEY_ESC) {
        set_grab(false);
        return;
    }
    const d = g_raw orelse return;
    std.debug.assert(key <= std.math.maxInt(u16));
    d.on_event(ctx_for(g_grab_win, d.ctx), .{ .key = .{
        .scancode = @intCast(key),
        .down = down,
        .mods = g_raw_mods,
    } });
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
    // state 0 is NewValue: an INCR sender wrote the next clipboard chunk.
    if (ev.atom != 0 and ev.atom == g_atom_clip_prop and ev.state == 0) {
        g_incr_chunk_ready = true;
        return;
    }
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

// ---- pointer grab (remote-control capture) ----

// Confine + hide the pointer with a core grab and stream raw input through
// the registered RawDispatch; relative motion rides XInput2 raw events (the
// channel that skips pointer acceleration). Without the XInput extension
// the grab still confines but streams no motion, and is_grabbed() reports
// the grab honestly either way.
pub fn set_grab(on: bool) void {
    if (on == g_grabbed) return;
    if (on) {
        const win = g_keyboard_focus orelse g_pointer_focus orelse return;
        const mask: u16 = @intCast(xcb.EVENT_MASK_BUTTON_PRESS |
            xcb.EVENT_MASK_BUTTON_RELEASE | xcb.EVENT_MASK_POINTER_MOTION);
        std.debug.assert(win.in_use);
        if (!xcb.grab_pointer(win.window, mask, win.window, ensure_blank_cursor())) return;
        if (xcb_input.opcode != 0) xcb_input.select_raw_motion(xcb.screen.?.root);
        g_grab_win = win;
        g_grabbed = true;
    } else {
        g_grabbed = false;
        g_grab_win = null;
        g_raw_mods = .{};
        xcb.ungrab_pointer(xcb.TIME_CURRENT);
        if (xcb_input.opcode != 0) xcb_input.clear_raw_motion(xcb.screen.?.root);
    }
    xcb.flush();
}

pub fn is_grabbed() bool {
    return g_grabbed;
}

// The windows foreground-window check, in X11 terms: keyboard focus gone
// means another window took over, so the capture must not linger.
pub fn release_grab_if_blurred() void {
    if (!g_grabbed) return;
    if (g_keyboard_focus == null) set_grab(false);
}

// A cursor whose source and mask pixmaps are both empty draws nothing: the
// core protocol's way to hide the pointer for the duration of a grab.
fn ensure_blank_cursor() u32 {
    if (g_blank_cursor != 0) return g_blank_cursor;
    const pixmap = xcb.generate_id();
    xcb.create_pixmap(1, pixmap, xcb.screen.?.root, 1, 1);
    g_blank_cursor = xcb.generate_id();
    xcb.create_cursor_from_pixmap(g_blank_cursor, pixmap, pixmap);
    xcb.free_pixmap(pixmap);
    std.debug.assert(g_blank_cursor != 0);
    return g_blank_cursor;
}

// ---- clipboard (the X CLIPBOARD selection) ----

// Serves a selection request from the owned local copy: TARGETS, then the
// text targets; anything else is refused with property None.
fn on_selection_request(ev: *const xcb.SelectionRequestEvent) void {
    var granted_property: u32 = 0;
    if (g_own_active and ev.property != 0) {
        if (ev.target == g_atom_targets) {
            const targets = [_]u32{ g_atom_targets, g_atom_utf8_string, xcb.ATOM_STRING };
            xcb.change_property(ev.requestor, ev.property, xcb.ATOM_ATOM, 32, 3, &targets);
            granted_property = ev.property;
        } else if (is_text_target(ev.target)) {
            std.debug.assert(g_own_len <= MAX_CLIPBOARD_BYTES);
            xcb.change_property(
                ev.requestor,
                ev.property,
                ev.target,
                8,
                @intCast(g_own_len),
                &g_own_text,
            );
            granted_property = ev.property;
        }
    }
    var reply = [_]u32{0} ** 8;
    const notify: *xcb.SelectionNotifyEvent = @ptrCast(&reply);
    notify.response_type = xcb.SELECTION_NOTIFY;
    notify.time = ev.time;
    notify.requestor = ev.requestor;
    notify.selection = ev.selection;
    notify.target = ev.target;
    notify.property = granted_property;
    xcb.send_event_to(ev.requestor, @ptrCast(&reply));
    xcb.flush();
}

fn is_text_target(target: u32) bool {
    return target == g_atom_utf8_string or target == xcb.ATOM_STRING or target == g_atom_text;
}

fn on_selection_clear(ev: *const xcb.SelectionClearEvent) void {
    if (ev.selection != g_atom_clipboard) return;
    g_own_active = false;
}

pub fn pasteboard_write_string(text: []const u8) void {
    if (g_atom_clipboard == 0) return;
    const win = g_keyboard_focus orelse g_pointer_focus orelse first_window() orelse return;
    std.debug.assert(win.in_use);
    g_own_len = @min(text.len, MAX_CLIPBOARD_BYTES);
    @memcpy(g_own_text[0..g_own_len], text[0..g_own_len]);
    g_own_active = true;
    g_own_echo_pending = true;
    xcb.set_selection_owner(win.window, g_atom_clipboard);
    xcb.flush();
}

fn first_window() ?*X11Window {
    for (&g_windows) |*win| {
        if (win.in_use) return win;
    }
    return null;
}

pub fn pasteboard_read_into(buf: []u8) []const u8 {
    if (buf.len == 0) return "";
    if (g_atom_clipboard == 0 or g_atom_clip_prop == 0) return "";
    // Our own selection reads back from the local copy: a conversion would
    // route to OUR request handler, which cannot answer while this thread
    // waits on the reply (one thread owns both ends of that dance).
    if (g_own_active) {
        const n = @min(g_own_len, buf.len);
        @memcpy(buf[0..n], g_own_text[0..n]);
        return buf[0..n];
    }
    if (g_clip_reading) return ""; // a nested paste re-entered the wait loop
    const win = first_window() orelse return "";
    g_clip_reading = true;
    defer g_clip_reading = false;
    if (read_selection(win, g_atom_utf8_string, buf)) |text| return text;
    // Older owners only speak STRING (Latin-1; ASCII reads fine either way).
    if (read_selection(win, xcb.ATOM_STRING, buf)) |text| return text;
    return "";
}

fn read_selection(win: *X11Window, target: u32, buf: []u8) ?[]const u8 {
    std.debug.assert(win.in_use);
    g_selection_notify = null;
    xcb.convert_selection(win.window, g_atom_clipboard, target, g_atom_clip_prop);
    xcb.flush();
    const notify = wait_selection_notify() orelse return null;
    if (notify.property == 0) return null; // the owner refused this target
    const value = xcb.read_property(win.window, g_atom_clip_prop, true, &g_clip_scratch) orelse
        return buf[0..0];
    if (value.property_type == g_atom_incr) return read_incr(win, buf);
    const n = @min(value.bytes.len, buf.len);
    @memcpy(buf[0..n], value.bytes[0..n]);
    return buf[0..n];
}

// Blocks bounded on the xcb fd while the owner answers; selection traffic is
// consumed here, everything else flows through the normal handler. Key
// events are dropped for the wait's duration - a keystroke racing a paste
// reply has no sound ordering anyway.
fn wait_selection_notify() ?xcb.SelectionNotifyEvent {
    var spins: u32 = 0;
    while (spins < CLIPBOARD_POLL_MAX) : (spins += 1) {
        drain_for_selection();
        if (g_selection_notify) |notify| return notify;
        var pfd = clip_pollfd{ .fd = xcb.connection_fd(), .events = POLLIN, .revents = 0 };
        _ = poll(&pfd, 1, CLIPBOARD_POLL_MS);
    }
    return null;
}

fn drain_for_selection() void {
    var guard: u32 = 0;
    while (xcb.poll_event()) |event| : (guard += 1) {
        std.debug.assert(guard < 4096);
        const kind = event.response_type & 0x7f;
        if (kind != xcb.KEY_PRESS and kind != xcb.KEY_RELEASE) handle_event(event);
        xcb.free_event(event);
    }
}

// INCR transfer: the owner deletes-and-refills the property chunk by chunk;
// a zero-length chunk ends the stream. Bounded by the clipboard cap.
fn read_incr(win: *X11Window, buf: []u8) []const u8 {
    std.debug.assert(win.in_use);
    var len: usize = 0;
    var chunks: u32 = 0;
    g_incr_chunk_ready = false;
    while (chunks < INCR_CHUNKS_MAX) : (chunks += 1) {
        if (!wait_incr_chunk()) break;
        g_incr_chunk_ready = false;
        const value =
            xcb.read_property(win.window, g_atom_clip_prop, true, &g_clip_scratch) orelse break;
        if (value.bytes.len == 0) break; // end-of-stream marker
        const n = @min(value.bytes.len, buf.len - len);
        @memcpy(buf[len .. len + n], value.bytes[0..n]);
        len += n;
        if (len == buf.len) break;
    }
    return buf[0..len];
}

fn wait_incr_chunk() bool {
    var spins: u32 = 0;
    while (spins < CLIPBOARD_POLL_MAX) : (spins += 1) {
        drain_for_selection();
        if (g_incr_chunk_ready) return true;
        var pfd = clip_pollfd{ .fd = xcb.connection_fd(), .events = POLLIN, .revents = 0 };
        _ = poll(&pfd, 1, CLIPBOARD_POLL_MS);
    }
    return false;
}

extern "c" fn poll(fds: *clip_pollfd, nfds: c_ulong, timeout: c_int) c_int;
const clip_pollfd = extern struct { fd: i32, events: i16, revents: i16 };
const POLLIN: i16 = 1;

// Edge-triggered external-change poll, the windows clipboard-sequence shape:
// prime on first call, then report each new selection once unless it was the
// echo of our own write. The sequence ticks from XFixes selection events.
pub fn clipboard_changed_external() bool {
    if (!g_clipboard_primed) {
        g_clipboard_primed = true;
        g_clipboard_seen = g_clipboard_seq;
        return false;
    }
    if (g_clipboard_seq == g_clipboard_seen) return false;
    g_clipboard_seen = g_clipboard_seq;
    return g_clipboard_seq != g_clipboard_own_seq;
}

// ---- text field (the singleton editor) ----

// The editing engine lives in field.zig (shared with the Wayland arm); this
// arm contributes the key-window gate and its selection-based clipboard.

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

pub fn desktop_accent_color() ?types.Rgba {
    return desktop_theme.accent_color();
}

// Live RandR queries: display lookups are user-driven (no per-frame
// callers), so a fresh roundtrip beats caching plus change events.
pub fn display_count() u32 {
    const screen = xcb.screen orelse return 0;
    var monitors: [xcb_randr.MAX_MONITORS]xcb_randr.Monitor = undefined;
    return xcb_randr.monitors(screen.root, &monitors);
}

// Bounds in points (pixels over the integer scale), origin in the X screen's
// global space - the same logical space the Wayland arm reports.
pub fn display_bounds(index: u32) geometry.BoundsF {
    const screen = xcb.screen orelse return .{};
    var monitors: [xcb_randr.MAX_MONITORS]xcb_randr.Monitor = undefined;
    const count = xcb_randr.monitors(screen.root, &monitors);
    if (index >= count) return .{};
    const monitor = monitors[index];
    std.debug.assert(g_scale >= 1);
    const scale: f32 = @floatFromInt(g_scale);
    return .{
        .origin = .{
            .x = @as(f32, @floatFromInt(monitor.x)) / scale,
            .y = @as(f32, @floatFromInt(monitor.y)) / scale,
        },
        .size = .{
            .width = @as(f32, @floatFromInt(monitor.width)) / scale,
            .height = @as(f32, @floatFromInt(monitor.height)) / scale,
        },
    };
}
