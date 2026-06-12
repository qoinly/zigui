// The custom-chrome Wayland window: a wl_surface + xdg_toplevel with client-side
// decorations, mirroring the macOS/Windows custom_shell contract. The paint
// layer draws ONE unified title bar with the window controls (the Windows
// model); this file routes wl_seat input to the registered dispatch, hands
// empty-band drags and edge resizes to the compositor (xdg_toplevel move/
// resize), and answers caption clicks. Before a renderer takes over, the
// surface shows a wl_shm buffer filled with the theme background - a window
// must attach SOME buffer or the compositor never maps it. The system glue
// lives here too: clipboard over wl_data_device, pointer grab over
// pointer-constraints + relative-pointer, display enumeration over wl_output.
// Only the native text-field overlay remains an unimplemented no-op that
// keeps the facade surface complete, the windows/window.zig precedent.

const std = @import("std");
const wl = @import("wayland.zig");
const xkb = @import("xkbcommon.zig");
const wl_cursor = @import("wayland_cursor.zig");
const desktop_theme = @import("desktop_theme.zig");
const types = @import("../../window/types.zig");
const input = @import("../../input.zig");
const geometry = @import("../../geometry.zig");

pub const KeyMods = packed struct {
    cmd: bool = false,
    shift: bool = false,
    alt: bool = false,
    ctrl: bool = false,
};

pub const KeyCode = enum(u8) {
    char,
    left,
    right,
    up,
    down,
    backspace,
    delete_fwd,
    enter,
    tab,
    escape,
    home,
    end,
    page_up,
    page_down,
};

pub const KeyEvent = struct {
    code: KeyCode = .char,
    ch: u21 = 0,
    mods: KeyMods = .{},
};

pub const MouseDispatch = struct {
    on_move: *const fn (ctx: *anyopaque, x: f32, y: f32) void,
    on_exit: *const fn (ctx: *anyopaque) void,
    on_down: *const fn (ctx: *anyopaque, x: f32, y: f32) void,
    on_right_down: *const fn (ctx: *anyopaque, x: f32, y: f32) void,
    on_drag: *const fn (ctx: *anyopaque, x: f32, y: f32) void,
    on_up: *const fn (ctx: *anyopaque) void,
    on_scroll: *const fn (ctx: *anyopaque, dx: f32, dy: f32) void,
    on_key: *const fn (ctx: *anyopaque, ev: KeyEvent) void,
    ctx: *anyopaque,
};

pub const CursorKind = enum { default, col_resize, row_resize };

pub const CaptionButton = enum { none, minimize, maximize, close };

pub const HitTestFn = *const fn (ctx: *anyopaque, x: f32, y: f32, band_h: f32) bool;
pub const RedrawFn = *const fn (ctx: *anyopaque) void;

// Linux window controls follow the desktop convention, not the full-band
// Win11 strips; the slot width matches the Mint-Y/Adwaita button_width so
// targets feel native. The cluster's extra right margin is the contract the
// paint layer derives its button centres from (margin = CLUSTER_W - 3*BTN_W).
pub const CAPTION_BTN_W: f32 = 32;
pub const CAPTION_CLUSTER_W: f32 = CAPTION_BTN_W * 3 + 6;

pub const Error = error{
    ConnectFailed,
    WindowCreateFailed,
    ShmFailed,
};

pub const ContentSize = extern struct { width: f64, height: f64 };

const MAX_WINDOWS: u32 = 16;
// The shm pool maps 2 slots x 64MiB of VIRTUAL space once; resident memory
// stays at the touched pages (~width*height*4 per slot).
const POOL_DIM_MAX: i32 = 4096;
const POOL_DIM_MAX_USIZE: usize = @intCast(POOL_DIM_MAX);
const SLOT_BYTES: usize = POOL_DIM_MAX_USIZE * POOL_DIM_MAX_USIZE * 4;
const POOL_SLOTS: u32 = 2;
const POOL_BYTES: usize = SLOT_BYTES * POOL_SLOTS;
const CONFIGURE_ROUNDTRIPS_MAX: u32 = 8;
const TOPLEVEL_STATES_MAX: u32 = 64;

const XDG_TOPLEVEL_STATE_MAXIMIZED: u32 = 1;
const XDG_TOPLEVEL_STATE_FULLSCREEN: u32 = 2;
const XDG_TOPLEVEL_STATE_ACTIVATED: u32 = 4;

extern "c" fn memfd_create(name: [*:0]const u8, flags: c_uint) c_int;
extern "c" fn ftruncate(fd: c_int, length: i64) c_int;
extern "c" fn mmap(
    addr: ?*anyopaque,
    length: usize,
    prot: c_int,
    flags: c_int,
    fd: c_int,
    offset: i64,
) ?*anyopaque;
extern "c" fn munmap(addr: *anyopaque, length: usize) c_int;
extern "c" fn close(fd: c_int) c_int;
const MFD_CLOEXEC: c_uint = 1;
const MAP_PRIVATE: c_int = 2;
const BTN_LEFT: u32 = 0x110;
const BTN_RIGHT: u32 = 0x111;
const BTN_MIDDLE: u32 = 0x112;
// Evdev keycodes (linux/input-event-codes.h) the raw-capture path reads.
const KEY_ESC: u32 = 1;
const KEY_LEFTCTRL: u32 = 29;
const KEY_LEFTSHIFT: u32 = 42;
const KEY_RIGHTSHIFT: u32 = 54;
const KEY_LEFTALT: u32 = 56;
const KEY_RIGHTCTRL: u32 = 97;
const KEY_RIGHTALT: u32 = 100;
const KEY_LEFTMETA: u32 = 125;
const KEY_RIGHTMETA: u32 = 126;
const RESIZE_BORDER: f32 = 6;
const WHEEL_NOTCH_PT: f32 = 40;
const SEAT_CAP_POINTER: u32 = 1;
const SEAT_CAP_KEYBOARD: u32 = 2;
const CURSOR_SIZE: i32 = 24;
const PROT_READ: c_int = 1;
const PROT_WRITE: c_int = 2;
const MAP_SHARED: c_int = 1;

pub const ShellWindow = struct {
    in_use: bool = false,
    surface: ?*wl.wl_proxy = null,
    xdg_surface: ?*wl.wl_proxy = null,
    toplevel: ?*wl.wl_proxy = null,
    pool: ?*wl.wl_proxy = null,
    pool_data: ?[*]u8 = null,
    shm_fd: i32 = -1,
    buffer: ?*wl.wl_proxy = null,
    retiring: ?*wl.wl_proxy = null,
    slot: u32 = 0,
    width_pt: i32 = 0,
    height_pt: i32 = 0,
    buffer_w: i32 = 0,
    buffer_h: i32 = 0,
    pending_w: i32 = 0,
    pending_h: i32 = 0,
    // Floating size remembered across maximize/fullscreen, the windows
    // g_saved_rect restore (position is the compositor's on Wayland).
    saved_w: i32 = 0,
    saved_h: i32 = 0,
    configured: bool = false,
    activated: bool = false,
    maximized: bool = false,
    fullscreen: bool = false,
    bg_pixel: u32 = 0,
    surface_ctx: ?*anyopaque = null,
    renderer_owned: bool = false,
};

// Process-wide shell state, the windows custom_shell pattern: C event callbacks
// have no instance, so windows live in a static slab and dispatch stays global.
var g_windows: [MAX_WINDOWS]ShellWindow = [_]ShellWindow{.{}} ** MAX_WINDOWS;
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
// wl_seat input state. One seat per session in practice; the slab look-up by
// surface keeps multi-window routing correct.
var g_seat_bound: bool = false;
var g_pointer: ?*wl.wl_proxy = null;
var g_keyboard: ?*wl.wl_proxy = null;
var g_pointer_focus: ?*ShellWindow = null;
var g_keyboard_focus: ?*ShellWindow = null;
var g_pointer_x: f32 = 0;
var g_pointer_y: f32 = 0;
var g_left_down: bool = false;
var g_enter_serial: u32 = 0;
var g_button_serial: u32 = 0;
var g_disc_v: i32 = 0;
var g_disc_h: i32 = 0;
var g_hover_caption: CaptionButton = .none;
var g_pressed_caption: CaptionButton = .none;
var g_xkb_context: ?*xkb.Context = null;
var g_xkb_keymap: ?*xkb.Keymap = null;
var g_xkb_state: ?*xkb.State = null;
var g_mod_shift: u32 = xkb.MOD_INVALID;
var g_mod_ctrl: u32 = xkb.MOD_INVALID;
var g_mod_alt: u32 = xkb.MOD_INVALID;
var g_shift_down: bool = false;
var g_cursor_theme: ?*wl_cursor.CursorTheme = null;
var g_cursor_surface: ?*wl.wl_proxy = null;
var g_applied_cursor: CursorKind = .default;
// Pointer grab (remote-control capture): the lock + relative-motion proxies
// plus the live modifier state raw events carry (the windows raw-input set).
var g_grabbed: bool = false;
var g_locked_pointer: ?*wl.wl_proxy = null;
var g_relative_pointer: ?*wl.wl_proxy = null;
var g_grab_win: ?*ShellWindow = null;
var g_raw_mods: input.Mods = .{};
var g_mod_caps: u32 = xkb.MOD_INVALID;

pub const CustomShellHandle = struct {
    window: *ShellWindow,
    // cross-platform "render surface" handle (CAMetalLayer on macOS); here the
    // ShellWindow that owns the wl_surface.
    metal_layer: *anyopaque,
    height: f32,
    theme: types.Theme,
    titlebar: types.TitlebarOptions,

    // Wayland has no client-side focus stealing; activation is the compositor's.
    pub fn focus(self: CustomShellHandle) void {
        std.debug.assert(self.window.in_use);
    }

    pub fn is_fullscreen(self: CustomShellHandle) bool {
        std.debug.assert(self.window.in_use);
        return self.window.fullscreen;
    }

    pub fn set_fullscreen(self: CustomShellHandle, on: bool) void {
        std.debug.assert(self.window.in_use);
        const toplevel = self.window.toplevel orelse return;
        wl.toplevel_set_fullscreen(toplevel, on);
        wl.flush();
    }

    // Fractional scaling is unread; everything renders at scale 1.
    pub fn backing_scale_factor(self: CustomShellHandle) f32 {
        std.debug.assert(self.window.in_use);
        return 1.0;
    }

    pub fn is_maximized(self: CustomShellHandle) bool {
        std.debug.assert(self.window.in_use);
        return self.window.maximized;
    }

    // xdg-shell never tells a client it is minimized; report not-minimized.
    pub fn is_minimized(self: CustomShellHandle) bool {
        std.debug.assert(self.window.in_use);
        return false;
    }

    pub fn is_key(self: CustomShellHandle) bool {
        std.debug.assert(self.window.in_use);
        return self.window.activated;
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

pub fn register_mouse_dispatch(d: MouseDispatch) void {
    g_dispatch = d;
}

pub const RawDispatch = struct {
    on_event: *const fn (ctx: *anyopaque, ev: input.InputEvent) void,
    ctx: *anyopaque,
};

pub fn register_raw_dispatch(d: RawDispatch) void {
    g_raw = d;
}

pub fn bind_surface_ctx(handle: CustomShellHandle, ctx: *anyopaque) void {
    std.debug.assert(handle.window.in_use);
    std.debug.assert(@intFromPtr(ctx) != 0);
    handle.window.surface_ctx = ctx;
}

pub const WindowCloseFn = *const fn (ctx: *anyopaque, ns_window: ?*anyopaque) void;

pub fn register_window_close(cb: WindowCloseFn, ctx: *anyopaque) void {
    g_window_close = cb;
    g_window_close_ctx = ctx;
}

pub fn open(opts: types.NativeShellOptions) Error!CustomShellHandle {
    wl.connect() catch return error.ConnectFailed;
    ensure_input();
    // Warm the one-shot accent resolve here so its process spawn never lands
    // inside a paint tick.
    _ = desktop_theme.accent_color();
    std.debug.assert(opts.width > 0);
    std.debug.assert(opts.height > 0);
    g_titlebar_height = @floatCast(opts.titlebar.height);

    const win = alloc_window() orelse return error.WindowCreateFailed;
    errdefer destroy_window(win);
    const theme = opts.theme orelse types.Theme.default_dark();
    win.bg_pixel = pack_xrgb(theme.background);
    win.width_pt = @intFromFloat(opts.width);
    win.height_pt = @intFromFloat(opts.height);

    try init_shm(win);
    try create_protocol_objects(win, opts);
    wl.surface_commit(win.surface.?);
    wait_configured(win);
    if (!win.configured) return error.WindowCreateFailed;

    return .{
        .window = win,
        .metal_layer = @ptrCast(win),
        .height = @floatCast(opts.height),
        .theme = theme,
        .titlebar = opts.titlebar,
    };
}

fn alloc_window() ?*ShellWindow {
    var index: u32 = 0;
    while (index < MAX_WINDOWS) : (index += 1) {
        const win = &g_windows[index];
        if (win.in_use) continue;
        win.* = .{ .in_use = true };
        return win;
    }
    std.debug.assert(index == MAX_WINDOWS);
    return null;
}

fn window_index(win: *const ShellWindow) u32 {
    const base = @intFromPtr(&g_windows[0]);
    const offset = @intFromPtr(win) - base;
    const index: u32 = @intCast(offset / @sizeOf(ShellWindow));
    std.debug.assert(index < MAX_WINDOWS);
    std.debug.assert(offset % @sizeOf(ShellWindow) == 0);
    return index;
}

fn create_protocol_objects(win: *ShellWindow, opts: types.NativeShellOptions) Error!void {
    std.debug.assert(win.in_use);
    std.debug.assert(win.surface == null);
    win.surface = wl.compositor_create_surface() orelse return error.WindowCreateFailed;
    win.xdg_surface = wl.wm_base_get_xdg_surface(win.surface.?) orelse
        return error.WindowCreateFailed;
    win.toplevel = wl.xdg_surface_get_toplevel(win.xdg_surface.?) orelse
        return error.WindowCreateFailed;
    wl.add_listener(win.xdg_surface.?, &xdg_surface_listener, win);
    wl.add_listener(win.toplevel.?, &toplevel_listener, win);

    var title_buf: [256]u8 = undefined;
    std.debug.assert(opts.title.len < title_buf.len); // release builds truncate
    const title_len = @min(opts.title.len, title_buf.len - 1);
    @memcpy(title_buf[0..title_len], opts.title[0..title_len]);
    title_buf[title_len] = 0;
    wl.toplevel_set_title(win.toplevel.?, @ptrCast(&title_buf));
    wl.toplevel_set_app_id(win.toplevel.?, "zigui");
    wl.toplevel_set_min_size(
        win.toplevel.?,
        @intFromFloat(opts.min_width),
        @intFromFloat(opts.min_height),
    );
}

fn init_shm(win: *ShellWindow) Error!void {
    std.debug.assert(win.in_use);
    std.debug.assert(win.shm_fd == -1);
    const fd = memfd_create("zigui-shm", MFD_CLOEXEC);
    if (fd < 0) return error.ShmFailed;
    win.shm_fd = fd;
    if (ftruncate(fd, @intCast(POOL_BYTES)) != 0) return error.ShmFailed;
    const data = mmap(null, POOL_BYTES, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0) orelse
        return error.ShmFailed;
    if (@intFromPtr(data) == std.math.maxInt(usize)) return error.ShmFailed;
    win.pool_data = @ptrCast(data);
    win.pool = wl.shm_create_pool(fd, @intCast(POOL_BYTES)) orelse return error.ShmFailed;
}

// The compositor maps a surface only after configure is acked and a buffer is
// committed; the ack + attach happen in on_xdg_surface_configure.
fn wait_configured(win: *ShellWindow) void {
    std.debug.assert(win.in_use);
    var tries: u32 = 0;
    while (!win.configured and tries < CONFIGURE_ROUNDTRIPS_MAX) : (tries += 1) {
        wl.roundtrip();
    }
    std.debug.assert(tries <= CONFIGURE_ROUNDTRIPS_MAX);
}

fn ensure_buffer(win: *ShellWindow) void {
    std.debug.assert(win.in_use);
    std.debug.assert(win.pool != null);
    const w = @min(@max(win.width_pt, 1), POOL_DIM_MAX);
    const h = @min(@max(win.height_pt, 1), POOL_DIM_MAX);
    if (win.buffer != null and w == win.buffer_w and h == win.buffer_h) return;

    win.slot = (win.slot + 1) % POOL_SLOTS;
    const offset: usize = @as(usize, win.slot) * SLOT_BYTES;
    fill_slot(win, offset, w, h);

    const created = wl.shm_pool_create_buffer(
        win.pool.?,
        @intCast(offset),
        w,
        h,
        w * 4,
        wl.WL_SHM_FORMAT_XRGB8888,
    ) orelse return;
    wl.add_listener(created, &buffer_listener, win);
    if (win.buffer) |old| {
        // The compositor may still scan the old buffer; destroy it on release.
        // A second resize before that release drops it immediately - the worst
        // case is one glitched frame mid-resize, never a protocol error.
        if (win.retiring) |stale| wl.buffer_destroy(stale);
        win.retiring = old;
    }
    win.buffer = created;
    win.buffer_w = w;
    win.buffer_h = h;
    wl.surface_attach(win.surface.?, created, 0, 0);
    wl.surface_damage(win.surface.?, 0, 0, w, h);
}

fn fill_slot(win: *ShellWindow, offset: usize, w: i32, h: i32) void {
    std.debug.assert(w >= 1);
    std.debug.assert(w <= POOL_DIM_MAX);
    std.debug.assert(h >= 1);
    std.debug.assert(h <= POOL_DIM_MAX);
    const base = win.pool_data orelse return;
    const pixel_count: usize = @as(usize, @intCast(w)) * @as(usize, @intCast(h));
    std.debug.assert(offset + pixel_count * 4 <= POOL_BYTES);
    const pixels: [*]u32 = @ptrCast(@alignCast(base + offset));
    var index: usize = 0;
    while (index < pixel_count) : (index += 1) pixels[index] = win.bg_pixel;
}

fn pack_xrgb(c: types.Rgba) u32 {
    std.debug.assert(c.r >= 0 and c.r <= 1);
    std.debug.assert(c.g >= 0 and c.g <= 1);
    std.debug.assert(c.b >= 0 and c.b <= 1);
    const r: u32 = @intFromFloat(c.r * 255.0);
    const g: u32 = @intFromFloat(c.g * 255.0);
    const b: u32 = @intFromFloat(c.b * 255.0);
    return (r << 16) | (g << 8) | b;
}

// Called by the renderer once a swapchain owns the surface: the shm
// scaffolding is freed and configure stops attaching buffers.
pub fn renderer_takeover(win: *ShellWindow) void {
    std.debug.assert(win.in_use);
    std.debug.assert(!win.renderer_owned);
    if (win.retiring) |buffer| wl.buffer_destroy(buffer);
    if (win.buffer) |buffer| wl.buffer_destroy(buffer);
    if (win.pool) |pool| wl.shm_pool_destroy(pool);
    if (win.pool_data) |data| _ = munmap(data, POOL_BYTES);
    if (win.shm_fd >= 0) _ = close(win.shm_fd);
    win.retiring = null;
    win.buffer = null;
    win.pool = null;
    win.pool_data = null;
    win.shm_fd = -1;
    win.renderer_owned = true;
}

// The dying window's paint context may be the registered global fallback;
// repoint it at the root window so a late event (a queued leave) never
// dispatches into freed memory - the windows retire_surface_ctx.
fn retire_surface_ctx(win: *ShellWindow) void {
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

fn destroy_window(win: *ShellWindow) void {
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
    if (win.retiring) |buffer| wl.buffer_destroy(buffer);
    if (win.buffer) |buffer| wl.buffer_destroy(buffer);
    if (win.toplevel) |toplevel| wl.toplevel_destroy(toplevel);
    if (win.xdg_surface) |xdg_surface| wl.xdg_surface_destroy(xdg_surface);
    if (win.surface) |surface| wl.surface_destroy(surface);
    if (win.pool) |pool| wl.shm_pool_destroy(pool);
    if (win.pool_data) |data| _ = munmap(data, POOL_BYTES);
    if (win.shm_fd >= 0) _ = close(win.shm_fd);
    wl.flush();
    win.* = .{};
    std.debug.assert(!win.in_use);
}

// ---- protocol listeners ----

const XdgSurfaceListener = extern struct {
    configure: *const fn (?*anyopaque, ?*wl.wl_proxy, u32) callconv(.c) void,
};

const xdg_surface_listener = XdgSurfaceListener{ .configure = on_xdg_surface_configure };

fn on_xdg_surface_configure(
    data: ?*anyopaque,
    xdg_surface: ?*wl.wl_proxy,
    serial: u32,
) callconv(.c) void {
    std.debug.assert(data != null);
    std.debug.assert(xdg_surface != null);
    const win: *ShellWindow = @ptrCast(@alignCast(data.?));
    std.debug.assert(win.in_use);
    wl.xdg_surface_ack_configure(xdg_surface.?, serial);
    if (win.pending_w > 0) win.width_pt = win.pending_w;
    if (win.pending_h > 0) win.height_pt = win.pending_h;
    if (win.renderer_owned) {
        // The swapchain owns the surface: present commits the ack. Repaint so
        // a resize is acked promptly instead of waiting for the next frame.
        win.configured = true;
        if (g_paint_now) |paint| {
            if (win.surface_ctx orelse g_ctx) |ctx| paint(ctx);
        }
        return;
    }
    ensure_buffer(win);
    wl.surface_commit(win.surface.?);
    win.configured = true;
}

const XdgToplevelListener = extern struct {
    configure: *const fn (?*anyopaque, ?*wl.wl_proxy, i32, i32, ?*wl.wl_array) callconv(.c) void,
    close: *const fn (?*anyopaque, ?*wl.wl_proxy) callconv(.c) void,
    configure_bounds: *const fn (?*anyopaque, ?*wl.wl_proxy, i32, i32) callconv(.c) void,
    wm_capabilities: *const fn (?*anyopaque, ?*wl.wl_proxy, ?*wl.wl_array) callconv(.c) void,
};

const toplevel_listener = XdgToplevelListener{
    .configure = on_toplevel_configure,
    .close = on_toplevel_close,
    .configure_bounds = on_toplevel_configure_bounds,
    .wm_capabilities = on_toplevel_wm_capabilities,
};

fn on_toplevel_configure(
    data: ?*anyopaque,
    toplevel: ?*wl.wl_proxy,
    width: i32,
    height: i32,
    states: ?*wl.wl_array,
) callconv(.c) void {
    std.debug.assert(data != null);
    std.debug.assert(toplevel != null);
    const win: *ShellWindow = @ptrCast(@alignCast(data.?));
    std.debug.assert(win.in_use);
    const was_zoomed = win.maximized or win.fullscreen;
    win.pending_w = width; // 0 = the client picks; resolved at the ack
    win.pending_h = height;
    win.activated = false;
    win.maximized = false;
    win.fullscreen = false;
    if (states) |array| {
        const entries: u32 = @intCast(@min(array.size / 4, TOPLEVEL_STATES_MAX));
        if (array.data) |raw| {
            const items: [*]const u32 = @ptrCast(@alignCast(raw));
            var index: u32 = 0;
            while (index < entries) : (index += 1) {
                switch (items[index]) {
                    XDG_TOPLEVEL_STATE_MAXIMIZED => win.maximized = true,
                    XDG_TOPLEVEL_STATE_FULLSCREEN => win.fullscreen = true,
                    XDG_TOPLEVEL_STATE_ACTIVATED => win.activated = true,
                    else => {},
                }
            }
        }
    }
    const zoomed = win.maximized or win.fullscreen;
    if (zoomed and !was_zoomed) {
        win.saved_w = win.width_pt;
        win.saved_h = win.height_pt;
    }
    // Leaving a zoomed state with a size-free configure: the compositor lets
    // the client pick, so restore the remembered floating size - otherwise
    // the window keeps its zoomed dimensions.
    if (!zoomed and was_zoomed and win.pending_w == 0 and win.saved_w > 0) {
        win.pending_w = win.saved_w;
        win.pending_h = win.saved_h;
    }
}

fn on_toplevel_close(data: ?*anyopaque, toplevel: ?*wl.wl_proxy) callconv(.c) void {
    std.debug.assert(data != null);
    std.debug.assert(toplevel != null);
    const win: *ShellWindow = @ptrCast(@alignCast(data.?));
    std.debug.assert(win.in_use);
    request_close(win);
}

// Closing the first window quits the app; an extra window notifies the
// registered callback (which tears down its renderer) and then drops its
// surfaces - the DestroyWindow half of the windows handle_close.
fn request_close(win: *ShellWindow) void {
    std.debug.assert(win.in_use);
    if (g_window_close) |cb| cb(g_window_close_ctx.?, @ptrCast(win));
    if (window_index(win) == 0) {
        wl.quit_requested = true;
        return;
    }
    destroy_window(win);
}

fn on_toplevel_configure_bounds(
    data: ?*anyopaque,
    toplevel: ?*wl.wl_proxy,
    width: i32,
    height: i32,
) callconv(.c) void {
    _ = data;
    _ = width;
    _ = height;
    std.debug.assert(toplevel != null);
}

fn on_toplevel_wm_capabilities(
    data: ?*anyopaque,
    toplevel: ?*wl.wl_proxy,
    capabilities: ?*wl.wl_array,
) callconv(.c) void {
    _ = data;
    _ = capabilities;
    std.debug.assert(toplevel != null);
}

const BufferListener = extern struct {
    release: *const fn (?*anyopaque, ?*wl.wl_proxy) callconv(.c) void,
};

const buffer_listener = BufferListener{ .release = on_buffer_release };

fn on_buffer_release(data: ?*anyopaque, buffer: ?*wl.wl_proxy) callconv(.c) void {
    std.debug.assert(data != null);
    std.debug.assert(buffer != null);
    const win: *ShellWindow = @ptrCast(@alignCast(data.?));
    if (!win.in_use) return;
    if (win.retiring == buffer) {
        wl.buffer_destroy(buffer.?);
        win.retiring = null;
    }
}

// ---- wl_seat input ----

fn ensure_input() void {
    if (g_seat_bound) return;
    const seat = wl.conn.seat orelse return;
    xkb.load() catch {};
    wl.add_listener(seat, &seat_listener, null);
    g_seat_bound = true;
    ensure_data_device();
    wl.roundtrip(); // deliver capabilities so pointer/keyboard exist before input
}

// The GWLP_USERDATA analogue: a window's bound paint context wins over the
// globally registered fallback, so input routes to the right window.
fn ctx_for(win: ?*ShellWindow, fallback: *anyopaque) *anyopaque {
    if (win) |w| {
        if (w.surface_ctx) |ctx| return ctx;
    }
    return fallback;
}

fn window_by_surface(surface: ?*wl.wl_proxy) ?*ShellWindow {
    const wanted = surface orelse return null;
    var index: u32 = 0;
    while (index < MAX_WINDOWS) : (index += 1) {
        const win = &g_windows[index];
        if (win.in_use and win.surface == wanted) return win;
    }
    return null;
}

fn fixed_to_f32(value: i32) f32 {
    return @as(f32, @floatFromInt(value)) / 256.0;
}

const SeatListener = extern struct {
    capabilities: *const fn (?*anyopaque, ?*wl.wl_proxy, u32) callconv(.c) void,
    name: *const fn (?*anyopaque, ?*wl.wl_proxy, ?[*:0]const u8) callconv(.c) void,
};

const seat_listener = SeatListener{ .capabilities = on_seat_capabilities, .name = on_seat_name };

fn on_seat_capabilities(data: ?*anyopaque, seat: ?*wl.wl_proxy, caps: u32) callconv(.c) void {
    _ = data;
    std.debug.assert(seat != null);
    std.debug.assert(wl.conn.seat == seat);
    if (caps & SEAT_CAP_POINTER != 0 and g_pointer == null) {
        g_pointer = wl.seat_get_pointer(seat.?);
        if (g_pointer) |pointer| wl.add_listener(pointer, &pointer_listener, null);
    }
    if (caps & SEAT_CAP_KEYBOARD != 0 and g_keyboard == null) {
        g_keyboard = wl.seat_get_keyboard(seat.?);
        if (g_keyboard) |keyboard| wl.add_listener(keyboard, &keyboard_listener, null);
    }
}

fn on_seat_name(data: ?*anyopaque, seat: ?*wl.wl_proxy, name: ?[*:0]const u8) callconv(.c) void {
    _ = data;
    _ = name;
    std.debug.assert(seat != null);
}

// ---- pointer ----

const PointerListener = extern struct {
    enter: *const fn (?*anyopaque, ?*wl.wl_proxy, u32, ?*wl.wl_proxy, i32, i32) callconv(.c) void,
    leave: *const fn (?*anyopaque, ?*wl.wl_proxy, u32, ?*wl.wl_proxy) callconv(.c) void,
    motion: *const fn (?*anyopaque, ?*wl.wl_proxy, u32, i32, i32) callconv(.c) void,
    button: *const fn (?*anyopaque, ?*wl.wl_proxy, u32, u32, u32, u32) callconv(.c) void,
    axis: *const fn (?*anyopaque, ?*wl.wl_proxy, u32, u32, i32) callconv(.c) void,
    frame: *const fn (?*anyopaque, ?*wl.wl_proxy) callconv(.c) void,
    axis_source: *const fn (?*anyopaque, ?*wl.wl_proxy, u32) callconv(.c) void,
    axis_stop: *const fn (?*anyopaque, ?*wl.wl_proxy, u32, u32) callconv(.c) void,
    axis_discrete: *const fn (?*anyopaque, ?*wl.wl_proxy, u32, i32) callconv(.c) void,
};

const pointer_listener = PointerListener{
    .enter = on_pointer_enter,
    .leave = on_pointer_leave,
    .motion = on_pointer_motion,
    .button = on_pointer_button,
    .axis = on_pointer_axis,
    .frame = on_pointer_frame,
    .axis_source = on_pointer_axis_source,
    .axis_stop = on_pointer_axis_stop,
    .axis_discrete = on_pointer_axis_discrete,
};

fn on_pointer_enter(
    data: ?*anyopaque,
    pointer: ?*wl.wl_proxy,
    serial: u32,
    surface: ?*wl.wl_proxy,
    sx: i32,
    sy: i32,
) callconv(.c) void {
    _ = data;
    std.debug.assert(pointer != null);
    g_pointer_focus = window_by_surface(surface);
    g_enter_serial = serial;
    g_pointer_x = fixed_to_f32(sx);
    g_pointer_y = fixed_to_f32(sy);
    g_applied_cursor = .default;
    set_cursor_image(g_cursor);
    if (g_dispatch) |d| d.on_move(ctx_for(g_pointer_focus, d.ctx), g_pointer_x, g_pointer_y);
}

fn on_pointer_leave(
    data: ?*anyopaque,
    pointer: ?*wl.wl_proxy,
    serial: u32,
    surface: ?*wl.wl_proxy,
) callconv(.c) void {
    _ = data;
    _ = serial;
    _ = surface;
    std.debug.assert(pointer != null);
    const win = g_pointer_focus;
    g_pointer_focus = null;
    g_left_down = false;
    set_hover_caption(.none);
    if (g_dispatch) |d| d.on_exit(ctx_for(win, d.ctx));
}

fn on_pointer_motion(
    data: ?*anyopaque,
    pointer: ?*wl.wl_proxy,
    time: u32,
    sx: i32,
    sy: i32,
) callconv(.c) void {
    _ = data;
    _ = time;
    std.debug.assert(pointer != null);
    if (g_grabbed) return; // a locked pointer reports motion only via relative_motion
    g_pointer_x = fixed_to_f32(sx);
    g_pointer_y = fixed_to_f32(sy);
    const win = g_pointer_focus orelse return;
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

fn update_hover_and_cursor(win: *ShellWindow) void {
    std.debug.assert(win.in_use);
    const edge = resize_edge_at(win, g_pointer_x, g_pointer_y);
    if (edge == 4 or edge == 8) {
        set_cursor_image(.col_resize);
    } else if (edge == 1 or edge == 2) {
        set_cursor_image(.row_resize);
    } else {
        set_cursor_image(g_cursor);
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
    if (g_redraw) |cb| {
        if (g_ctx) |ctx| cb(ctx);
    }
}

fn caption_button_at(win: *const ShellWindow, x: f32, y: f32) CaptionButton {
    std.debug.assert(win.in_use);
    if (y < 0 or y >= g_titlebar_height) return .none;
    const w: f32 = @floatFromInt(win.width_pt);
    // Slots end right_margin short of the edge, mirroring the paint layer's
    // centre formula; the margin itself stays draggable band.
    const right = w - (CAPTION_CLUSTER_W - CAPTION_BTN_W * 3);
    if (x >= right) return .none;
    if (x >= right - CAPTION_BTN_W) return .close;
    if (x >= right - CAPTION_BTN_W * 2) return .maximize;
    if (x >= right - CAPTION_BTN_W * 3) return .minimize;
    return .none;
}

// xdg resize-edge codes: top=1 bottom=2 left=4 right=8, corners are their OR.
fn resize_edge_at(win: *const ShellWindow, x: f32, y: f32) u32 {
    std.debug.assert(win.in_use);
    if (win.maximized or win.fullscreen) return 0;
    const w: f32 = @floatFromInt(win.width_pt);
    const h: f32 = @floatFromInt(win.height_pt);
    var edge: u32 = 0;
    if (y < RESIZE_BORDER) edge |= 1;
    if (y >= h - RESIZE_BORDER) edge |= 2;
    if (x < RESIZE_BORDER) edge |= 4;
    if (x >= w - RESIZE_BORDER) edge |= 8;
    // A window thinner than two borders satisfies opposite edges at once; the
    // min-size floor prevents it, but a protocol value past 10 must never ship.
    if (edge & 3 == 3 or edge & 12 == 12) return 0;
    std.debug.assert(edge <= 10);
    return edge;
}

fn on_pointer_button(
    data: ?*anyopaque,
    pointer: ?*wl.wl_proxy,
    serial: u32,
    time: u32,
    button: u32,
    state: u32,
) callconv(.c) void {
    _ = data;
    _ = time;
    std.debug.assert(pointer != null);
    if (g_grabbed) {
        raw_button_event(button, state == 1);
        return;
    }
    const win = g_pointer_focus orelse return;
    const pressed = state == 1;
    if (button == BTN_LEFT) {
        if (pressed) {
            g_button_serial = serial;
            handle_left_press(win);
        } else {
            handle_left_release(win);
        }
    } else if (button == BTN_RIGHT and pressed) {
        if (g_dispatch) |d| d.on_right_down(ctx_for(win, d.ctx), g_pointer_x, g_pointer_y);
    }
}

fn handle_left_press(win: *ShellWindow) void {
    std.debug.assert(win.in_use);
    const seat = wl.conn.seat orelse return;
    const x = g_pointer_x;
    const y = g_pointer_y;
    const edge = resize_edge_at(win, x, y);
    if (edge != 0) {
        wl.toplevel_resize(win.toplevel.?, seat, g_button_serial, edge);
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
            // Empty band area drags the window; the compositor takes the
            // pointer over (a leave event follows).
            wl.toplevel_move(win.toplevel.?, seat, g_button_serial);
            return;
        }
    }
    g_left_down = true;
    if (g_dispatch) |d| d.on_down(ctx_for(win, d.ctx), x, y);
}

fn handle_left_release(win: *ShellWindow) void {
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

fn perform_caption_action(win: *ShellWindow, button: CaptionButton) void {
    std.debug.assert(win.in_use);
    std.debug.assert(button != .none);
    switch (button) {
        .minimize => wl.toplevel_set_minimized(win.toplevel.?),
        .maximize => wl.toplevel_set_maximized(win.toplevel.?, !win.maximized),
        .close => request_close(win),
        .none => {},
    }
}

fn on_pointer_axis(
    data: ?*anyopaque,
    pointer: ?*wl.wl_proxy,
    time: u32,
    axis: u32,
    value: i32,
) callconv(.c) void {
    _ = data;
    _ = time;
    std.debug.assert(pointer != null);
    if (!g_grabbed and g_pointer_focus == null) return;
    const vertical = axis == 0;
    // A wheel detent reports axis_discrete first: one notch scrolls the
    // windows-parity 40pt. Continuous sources (touchpads) scroll 1:1.
    const disc = if (vertical) &g_disc_v else &g_disc_h;
    const delta = if (disc.* != 0)
        @as(f32, @floatFromInt(disc.*)) * WHEEL_NOTCH_PT
    else
        fixed_to_f32(value);
    disc.* = 0;
    if (g_grabbed) {
        const d = g_raw orelse return;
        const ev: input.InputEvent = if (vertical)
            .{ .wheel = .{ .dx = 0, .dy = -delta } }
        else
            .{ .wheel = .{ .dx = -delta, .dy = 0 } };
        d.on_event(ctx_for(g_grab_win, d.ctx), ev);
        return;
    }
    if (g_dispatch) |d| {
        const ctx = ctx_for(g_pointer_focus, d.ctx);
        if (vertical) {
            d.on_scroll(ctx, 0, -delta);
        } else {
            d.on_scroll(ctx, -delta, 0);
        }
    }
}

fn on_pointer_frame(data: ?*anyopaque, pointer: ?*wl.wl_proxy) callconv(.c) void {
    _ = data;
    std.debug.assert(pointer != null);
}

fn on_pointer_axis_source(
    data: ?*anyopaque,
    pointer: ?*wl.wl_proxy,
    source: u32,
) callconv(.c) void {
    _ = data;
    _ = source;
    std.debug.assert(pointer != null);
}

fn on_pointer_axis_stop(
    data: ?*anyopaque,
    pointer: ?*wl.wl_proxy,
    time: u32,
    axis: u32,
) callconv(.c) void {
    _ = data;
    _ = time;
    _ = axis;
    std.debug.assert(pointer != null);
}

fn on_pointer_axis_discrete(
    data: ?*anyopaque,
    pointer: ?*wl.wl_proxy,
    axis: u32,
    discrete: i32,
) callconv(.c) void {
    _ = data;
    std.debug.assert(pointer != null);
    if (axis == 0) {
        g_disc_v = discrete;
    } else {
        g_disc_h = discrete;
    }
}

// ---- cursor image ----

fn set_cursor_image(kind: CursorKind) void {
    const pointer = g_pointer orelse return;
    if (g_grabbed) return; // the cursor stays hidden for the whole grab
    if (g_pointer_focus == null) return;
    if (kind == g_applied_cursor and g_cursor_surface != null) return;
    ensure_cursor_theme();
    const theme = g_cursor_theme orelse return;
    const surface = g_cursor_surface orelse return;
    const names: []const [*:0]const u8 = switch (kind) {
        .default => &.{ "left_ptr", "default" },
        .col_resize => &.{ "ew-resize", "sb_h_double_arrow" },
        .row_resize => &.{ "ns-resize", "sb_v_double_arrow" },
    };
    const cursor = wl_cursor.get_cursor(theme, names) orelse return;
    std.debug.assert(cursor.image_count >= 1);
    const image = cursor.images[0];
    const buffer = wl_cursor.image_buffer(image) orelse return;
    wl.pointer_set_cursor(
        pointer,
        g_enter_serial,
        surface,
        @intCast(image.hotspot_x),
        @intCast(image.hotspot_y),
    );
    wl.surface_attach(surface, buffer, 0, 0);
    wl.surface_damage(surface, 0, 0, @intCast(image.width), @intCast(image.height));
    wl.surface_commit(surface);
    g_applied_cursor = kind;
}

fn ensure_cursor_theme() void {
    if (g_cursor_theme != null) return;
    wl_cursor.load() catch return;
    const shm = wl.conn.shm orelse return;
    g_cursor_theme = wl_cursor.theme_load(CURSOR_SIZE, shm);
    g_cursor_surface = wl.compositor_create_surface();
}

// ---- keyboard ----

const KeyboardListener = extern struct {
    keymap: *const fn (?*anyopaque, ?*wl.wl_proxy, u32, i32, u32) callconv(.c) void,
    enter: *const fn (
        ?*anyopaque,
        ?*wl.wl_proxy,
        u32,
        ?*wl.wl_proxy,
        ?*wl.wl_array,
    ) callconv(.c) void,
    leave: *const fn (?*anyopaque, ?*wl.wl_proxy, u32, ?*wl.wl_proxy) callconv(.c) void,
    key: *const fn (?*anyopaque, ?*wl.wl_proxy, u32, u32, u32, u32) callconv(.c) void,
    modifiers: *const fn (?*anyopaque, ?*wl.wl_proxy, u32, u32, u32, u32, u32) callconv(.c) void,
    repeat_info: *const fn (?*anyopaque, ?*wl.wl_proxy, i32, i32) callconv(.c) void,
};

const keyboard_listener = KeyboardListener{
    .keymap = on_keyboard_keymap,
    .enter = on_keyboard_enter,
    .leave = on_keyboard_leave,
    .key = on_keyboard_key,
    .modifiers = on_keyboard_modifiers,
    .repeat_info = on_keyboard_repeat_info,
};

fn on_keyboard_keymap(
    data: ?*anyopaque,
    keyboard: ?*wl.wl_proxy,
    format: u32,
    fd: i32,
    size: u32,
) callconv(.c) void {
    _ = data;
    std.debug.assert(keyboard != null);
    std.debug.assert(size > 0);
    defer _ = close(fd);
    if (format != 1) return; // only xkb_v1 keymaps exist in practice
    const mapped = mmap(null, size, PROT_READ, MAP_PRIVATE, fd, 0) orelse return;
    if (@intFromPtr(mapped) == std.math.maxInt(usize)) return;
    defer _ = munmap(mapped, size);
    rebuild_keymap(@ptrCast(mapped));
}

fn rebuild_keymap(keymap_text: [*:0]const u8) void {
    if (g_xkb_context == null) g_xkb_context = xkb.context_new();
    const context = g_xkb_context orelse return;
    const keymap = xkb.keymap_from_string(context, keymap_text) orelse return;
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

fn on_keyboard_enter(
    data: ?*anyopaque,
    keyboard: ?*wl.wl_proxy,
    serial: u32,
    surface: ?*wl.wl_proxy,
    keys: ?*wl.wl_array,
) callconv(.c) void {
    _ = data;
    _ = serial;
    _ = keys;
    std.debug.assert(keyboard != null);
    g_keyboard_focus = window_by_surface(surface);
}

fn on_keyboard_leave(
    data: ?*anyopaque,
    keyboard: ?*wl.wl_proxy,
    serial: u32,
    surface: ?*wl.wl_proxy,
) callconv(.c) void {
    _ = data;
    _ = serial;
    _ = surface;
    std.debug.assert(keyboard != null);
    g_keyboard_focus = null;
}

fn on_keyboard_key(
    data: ?*anyopaque,
    keyboard: ?*wl.wl_proxy,
    serial: u32,
    time: u32,
    key: u32,
    state: u32,
) callconv(.c) void {
    _ = data;
    _ = serial;
    _ = time;
    std.debug.assert(keyboard != null);
    if (g_grabbed) {
        // Raw capture needs releases too; the dispatch filter below drops them.
        raw_key_event(key, state == 1);
        return;
    }
    if (state != 1) return; // wl_keyboard repeats nothing; releases carry no input
    if (g_keyboard_focus == null) return;
    const xkb_state = g_xkb_state orelse return;
    const keycode = key + 8; // evdev to xkb keycode offset
    const sym = xkb.key_sym(xkb_state, keycode);
    const mods = KeyMods{
        .cmd = xkb.mod_active(xkb_state, g_mod_ctrl), // ctrl plays cmd, the windows mapping
        .shift = xkb.mod_active(xkb_state, g_mod_shift),
        .alt = xkb.mod_active(xkb_state, g_mod_alt),
        .ctrl = xkb.mod_active(xkb_state, g_mod_ctrl),
    };
    if (key_event_for(sym, keycode, xkb_state, mods)) |event| {
        if (g_dispatch) |d| d.on_key(ctx_for(g_keyboard_focus, d.ctx), event);
    }
}

fn key_event_for(sym: u32, keycode: u32, state: *xkb.State, mods: KeyMods) ?KeyEvent {
    std.debug.assert(keycode >= 8);
    const code: ?KeyCode = switch (sym) {
        0xff51 => .left,
        0xff53 => .right,
        0xff52 => .up,
        0xff54 => .down,
        0xff08 => .backspace,
        0xffff => .delete_fwd,
        0xff0d, 0xff8d => .enter,
        0xff09 => .tab,
        0xff1b => .escape,
        0xff50 => .home,
        0xff57 => .end,
        0xff55 => .page_up,
        0xff56 => .page_down,
        else => null,
    };
    if (code) |c| return .{ .code = c, .mods = mods };
    const ch = xkb.key_utf32(state, keycode);
    if (ch < 0x20 or ch == 0x7f) return null;
    std.debug.assert(ch <= 0x10FFFF);
    return .{ .code = .char, .ch = @intCast(ch), .mods = mods };
}

fn on_keyboard_modifiers(
    data: ?*anyopaque,
    keyboard: ?*wl.wl_proxy,
    serial: u32,
    depressed: u32,
    latched: u32,
    locked: u32,
    group: u32,
) callconv(.c) void {
    _ = data;
    _ = serial;
    std.debug.assert(keyboard != null);
    const state = g_xkb_state orelse return;
    xkb.update_mask(state, depressed, latched, locked, group);
    g_shift_down = xkb.mod_active(state, g_mod_shift);
}

fn on_keyboard_repeat_info(
    data: ?*anyopaque,
    keyboard: ?*wl.wl_proxy,
    rate: i32,
    delay: i32,
) callconv(.c) void {
    _ = data;
    _ = rate;
    _ = delay;
    std.debug.assert(keyboard != null);
}

// ---- pointer grab (remote-control capture) ----

// Lock the pointer to the focused surface and stream raw input through the
// registered RawDispatch (the windows RegisterRawInputDevices model). Both
// protocols or nothing: without pointer-constraints + relative-pointer the
// grab silently stays off and is_grabbed() reports it.
pub fn set_grab(on: bool) void {
    if (on == g_grabbed) return;
    if (on) {
        const pointer = g_pointer orelse return;
        const win = g_keyboard_focus orelse g_pointer_focus orelse return;
        const surface = win.surface orelse return;
        const locked = wl.lock_pointer(surface, pointer) orelse return;
        const relative = wl.get_relative_pointer(pointer) orelse {
            wl.locked_pointer_destroy(locked);
            return;
        };
        wl.add_listener(locked, &locked_pointer_listener, null);
        wl.add_listener(relative, &relative_pointer_listener, null);
        g_locked_pointer = locked;
        g_relative_pointer = relative;
        g_grab_win = win;
        g_grabbed = true;
        hide_cursor();
    } else {
        g_grabbed = false;
        if (g_relative_pointer) |relative| wl.relative_pointer_destroy(relative);
        if (g_locked_pointer) |locked| wl.locked_pointer_destroy(locked);
        g_relative_pointer = null;
        g_locked_pointer = null;
        g_grab_win = null;
        g_raw_mods = .{};
        show_cursor();
    }
    wl.flush();
}

pub fn is_grabbed() bool {
    return g_grabbed;
}

// The windows foreground-window check, in Wayland terms: keyboard focus gone
// means another surface took over, so the capture must not linger.
pub fn release_grab_if_blurred() void {
    if (!g_grabbed) return;
    if (g_keyboard_focus == null) set_grab(false);
}

const LockedPointerListener = extern struct {
    locked: *const fn (?*anyopaque, ?*wl.wl_proxy) callconv(.c) void,
    unlocked: *const fn (?*anyopaque, ?*wl.wl_proxy) callconv(.c) void,
};

const locked_pointer_listener = LockedPointerListener{
    .locked = on_pointer_locked,
    .unlocked = on_pointer_unlocked,
};

fn on_pointer_locked(data: ?*anyopaque, locked: ?*wl.wl_proxy) callconv(.c) void {
    _ = data;
    std.debug.assert(locked != null);
}

// A persistent-lifetime lock re-engages when focus returns, so an unlock is
// not a release; dropping the grab on blur is release_grab_if_blurred's call.
fn on_pointer_unlocked(data: ?*anyopaque, locked: ?*wl.wl_proxy) callconv(.c) void {
    _ = data;
    std.debug.assert(locked != null);
}

const RelativePointerListener = extern struct {
    relative_motion: *const fn (
        ?*anyopaque,
        ?*wl.wl_proxy,
        u32,
        u32,
        i32,
        i32,
        i32,
        i32,
    ) callconv(.c) void,
};

const relative_pointer_listener = RelativePointerListener{
    .relative_motion = on_relative_motion,
};

fn on_relative_motion(
    data: ?*anyopaque,
    relative: ?*wl.wl_proxy,
    utime_hi: u32,
    utime_lo: u32,
    dx: i32,
    dy: i32,
    dx_unaccel: i32,
    dy_unaccel: i32,
) callconv(.c) void {
    _ = data;
    _ = utime_hi;
    _ = utime_lo;
    _ = dx;
    _ = dy;
    std.debug.assert(relative != null);
    if (!g_grabbed) return;
    const d = g_raw orelse return;
    // Unaccelerated deltas: the remote end applies its own pointer ballistics,
    // the same channel windows raw input reports.
    d.on_event(ctx_for(g_grab_win, d.ctx), .{ .motion = .{
        .dx = fixed_to_f32(dx_unaccel),
        .dy = fixed_to_f32(dy_unaccel),
    } });
}

fn raw_button_event(button: u32, down: bool) void {
    std.debug.assert(g_grabbed);
    const d = g_raw orelse return;
    const mapped: input.Button = switch (button) {
        BTN_LEFT => .left,
        BTN_RIGHT => .right,
        BTN_MIDDLE => .middle,
        else => .other,
    };
    d.on_event(ctx_for(g_grab_win, d.ctx), .{ .button = .{
        .button = mapped,
        .down = down,
        .mods = g_raw_mods,
    } });
}

fn raw_key_event(key: u32, down: bool) void {
    std.debug.assert(g_grabbed);
    update_raw_mods(key, down);
    if (down and key == KEY_ESC) {
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

// Left/right modifiers tracked from the raw evdev stream itself; xkb only
// folds them, and the remote needs the sides apart (the input.Mods contract).
fn update_raw_mods(key: u32, down: bool) void {
    switch (key) {
        KEY_LEFTSHIFT => g_raw_mods.left_shift = down,
        KEY_RIGHTSHIFT => g_raw_mods.right_shift = down,
        KEY_LEFTCTRL => g_raw_mods.left_control = down,
        KEY_RIGHTCTRL => g_raw_mods.right_control = down,
        KEY_LEFTALT => g_raw_mods.left_option = down,
        KEY_RIGHTALT => g_raw_mods.right_option = down,
        KEY_LEFTMETA => g_raw_mods.left_command = down,
        KEY_RIGHTMETA => g_raw_mods.right_command = down,
        else => {},
    }
    if (g_xkb_state) |state| g_raw_mods.caps_lock = xkb.mod_active(state, g_mod_caps);
}

fn hide_cursor() void {
    const pointer = g_pointer orelse return;
    if (g_enter_serial == 0) return; // never entered: nothing is showing
    wl.pointer_set_cursor(pointer, g_enter_serial, null, 0, 0);
}

fn show_cursor() void {
    // Force a re-attach: set_cursor_image dedupes on the last applied kind,
    // which the hide bypassed.
    g_applied_cursor = if (g_cursor == .default) .col_resize else .default;
    set_cursor_image(g_cursor);
}

// ---- clipboard (wl_data_device) ----

const MAX_CLIPBOARD_BYTES: usize = 64 * 1024;
const CLIPBOARD_POLL_MS: c_int = 10;
const CLIPBOARD_POLL_MAX: u32 = 50;
const O_CLOEXEC: c_int = 0x80000;
const POLLIN: i16 = 1;

const MIME_UTF8_PLAIN = "text/plain;charset=utf-8";
const MIME_UTF8_STRING = "UTF8_STRING";
const MIME_PLAIN = "text/plain";

// Ranked: a reader picks the best text flavor an offer advertised.
const TextMime = enum(u8) { none, plain, utf8_string, utf8_plain };

extern "c" fn pipe2(fds: *[2]i32, flags: c_int) c_int;
extern "c" fn read(fd: i32, buf: [*]u8, count: usize) isize;
extern "c" fn write(fd: i32, buf: [*]const u8, count: usize) isize;
const clip_pollfd = extern struct { fd: i32, events: i16, revents: i16 };
extern "c" fn poll(fds: [*]clip_pollfd, count: c_ulong, timeout_ms: c_int) c_int;

var g_data_device: ?*wl.wl_proxy = null;
// The offer being announced (mimes still arriving) vs the one holding the
// current selection; a selection event promotes pending to selection.
var g_pending_offer: ?*wl.wl_proxy = null;
var g_pending_mime: TextMime = .none;
var g_selection_offer: ?*wl.wl_proxy = null;
var g_selection_mime: TextMime = .none;
// Our outstanding claim: the source plus a local copy of the text it serves.
var g_own_source: ?*wl.wl_proxy = null;
var g_own_text: [MAX_CLIPBOARD_BYTES]u8 = undefined;
var g_own_len: usize = 0;
// Selection generation counter, the windows GetClipboardSequenceNumber shape.
var g_clipboard_seq: u32 = 0;
var g_clipboard_seen: u32 = 0;
var g_clipboard_own_seq: u32 = 0;
var g_clipboard_primed: bool = false;
var g_own_echo_pending: bool = false;

fn ensure_data_device() void {
    if (g_data_device != null) return;
    const seat = wl.conn.seat orelse return;
    const device = wl.get_data_device(seat) orelse return;
    wl.add_listener(device, &data_device_listener, null);
    g_data_device = device;
}

fn mime_string(mime: TextMime) ?[*:0]const u8 {
    return switch (mime) {
        .none => null,
        .plain => MIME_PLAIN,
        .utf8_string => MIME_UTF8_STRING,
        .utf8_plain => MIME_UTF8_PLAIN,
    };
}

// The source app writes the pipe on its own schedule; the bounded poll keeps
// a dead source from wedging the paint loop (500ms worst case, only on the
// read that follows a changed() edge).
fn read_pipe_bounded(fd: i32, buf: []u8) usize {
    std.debug.assert(fd >= 0);
    std.debug.assert(buf.len > 0);
    var total: usize = 0;
    var spins: u32 = 0;
    while (total < buf.len and spins < CLIPBOARD_POLL_MAX) : (spins += 1) {
        var pfd = [_]clip_pollfd{.{ .fd = fd, .events = POLLIN, .revents = 0 }};
        const rc = poll(&pfd, 1, CLIPBOARD_POLL_MS);
        if (rc < 0) break;
        if (rc == 0) continue;
        const got = read(fd, buf.ptr + total, buf.len - total);
        if (got <= 0) break; // EOF or error: the transfer is over either way
        total += @intCast(got);
    }
    return total;
}

fn write_all(fd: i32, bytes: []const u8) void {
    std.debug.assert(fd >= 0);
    var at: usize = 0;
    var spins: u32 = 0;
    while (at < bytes.len and spins < CLIPBOARD_POLL_MAX) : (spins += 1) {
        const put = write(fd, bytes.ptr + at, bytes.len - at);
        if (put <= 0) return; // reader hung up: nothing left to deliver
        at += @intCast(put);
    }
}

const DataDeviceListener = extern struct {
    data_offer: *const fn (?*anyopaque, ?*wl.wl_proxy, ?*wl.wl_proxy) callconv(.c) void,
    enter: *const fn (
        ?*anyopaque,
        ?*wl.wl_proxy,
        u32,
        ?*wl.wl_proxy,
        i32,
        i32,
        ?*wl.wl_proxy,
    ) callconv(.c) void,
    leave: *const fn (?*anyopaque, ?*wl.wl_proxy) callconv(.c) void,
    motion: *const fn (?*anyopaque, ?*wl.wl_proxy, u32, i32, i32) callconv(.c) void,
    drop: *const fn (?*anyopaque, ?*wl.wl_proxy) callconv(.c) void,
    selection: *const fn (?*anyopaque, ?*wl.wl_proxy, ?*wl.wl_proxy) callconv(.c) void,
};

const data_device_listener = DataDeviceListener{
    .data_offer = on_data_offer,
    .enter = on_data_enter,
    .leave = on_data_leave,
    .motion = on_data_motion,
    .drop = on_data_drop,
    .selection = on_data_selection,
};

fn on_data_offer(
    data: ?*anyopaque,
    device: ?*wl.wl_proxy,
    offer: ?*wl.wl_proxy,
) callconv(.c) void {
    _ = data;
    std.debug.assert(device != null);
    // An announced offer that never became the selection (a DND offer this
    // shell does not accept) is dead once the next announcement arrives; one
    // such proxy may linger until then, deliberately not reaped earlier.
    if (g_pending_offer) |old| {
        if (old != g_selection_offer) wl.data_offer_destroy(old);
    }
    g_pending_offer = offer;
    g_pending_mime = .none;
    if (offer) |o| wl.add_listener(o, &data_offer_listener, null);
}

fn on_data_enter(
    data: ?*anyopaque,
    device: ?*wl.wl_proxy,
    serial: u32,
    surface: ?*wl.wl_proxy,
    x: i32,
    y: i32,
    offer: ?*wl.wl_proxy,
) callconv(.c) void {
    _ = data;
    _ = serial;
    _ = surface;
    _ = x;
    _ = y;
    _ = offer;
    std.debug.assert(device != null);
}

fn on_data_leave(data: ?*anyopaque, device: ?*wl.wl_proxy) callconv(.c) void {
    _ = data;
    std.debug.assert(device != null);
}

fn on_data_motion(
    data: ?*anyopaque,
    device: ?*wl.wl_proxy,
    time: u32,
    x: i32,
    y: i32,
) callconv(.c) void {
    _ = data;
    _ = time;
    _ = x;
    _ = y;
    std.debug.assert(device != null);
}

fn on_data_drop(data: ?*anyopaque, device: ?*wl.wl_proxy) callconv(.c) void {
    _ = data;
    std.debug.assert(device != null);
}

fn on_data_selection(
    data: ?*anyopaque,
    device: ?*wl.wl_proxy,
    offer: ?*wl.wl_proxy,
) callconv(.c) void {
    _ = data;
    std.debug.assert(device != null);
    if (g_selection_offer) |old| {
        if (old != offer) wl.data_offer_destroy(old);
    }
    g_selection_offer = offer;
    if (offer != null and offer == g_pending_offer) {
        g_selection_mime = g_pending_mime;
        g_pending_offer = null;
        g_pending_mime = .none;
    } else if (offer == null) {
        g_selection_mime = .none;
    }
    g_clipboard_seq +%= 1;
    // The first selection after our own write is its echo. A foreign claim
    // racing in between mislabels one edge; the next change reports normally.
    if (g_own_echo_pending) {
        g_clipboard_own_seq = g_clipboard_seq;
        g_own_echo_pending = false;
    }
}

const DataOfferListener = extern struct {
    offer: *const fn (?*anyopaque, ?*wl.wl_proxy, ?[*:0]const u8) callconv(.c) void,
    source_actions: *const fn (?*anyopaque, ?*wl.wl_proxy, u32) callconv(.c) void,
    action: *const fn (?*anyopaque, ?*wl.wl_proxy, u32) callconv(.c) void,
};

const data_offer_listener = DataOfferListener{
    .offer = on_offer_mime,
    .source_actions = on_offer_source_actions,
    .action = on_offer_action,
};

fn on_offer_mime(
    data: ?*anyopaque,
    offer: ?*wl.wl_proxy,
    mime_z: ?[*:0]const u8,
) callconv(.c) void {
    _ = data;
    if (offer == null or offer != g_pending_offer) return;
    const mime = std.mem.span(mime_z orelse return);
    const rank: TextMime = if (std.mem.eql(u8, mime, MIME_UTF8_PLAIN))
        .utf8_plain
    else if (std.mem.eql(u8, mime, MIME_UTF8_STRING))
        .utf8_string
    else if (std.mem.eql(u8, mime, MIME_PLAIN))
        .plain
    else
        return;
    if (@intFromEnum(rank) > @intFromEnum(g_pending_mime)) g_pending_mime = rank;
}

fn on_offer_source_actions(
    data: ?*anyopaque,
    offer: ?*wl.wl_proxy,
    actions: u32,
) callconv(.c) void {
    _ = data;
    _ = actions;
    std.debug.assert(offer != null);
}

fn on_offer_action(data: ?*anyopaque, offer: ?*wl.wl_proxy, action: u32) callconv(.c) void {
    _ = data;
    _ = action;
    std.debug.assert(offer != null);
}

const DataSourceListener = extern struct {
    target: *const fn (?*anyopaque, ?*wl.wl_proxy, ?[*:0]const u8) callconv(.c) void,
    send: *const fn (?*anyopaque, ?*wl.wl_proxy, ?[*:0]const u8, i32) callconv(.c) void,
    cancelled: *const fn (?*anyopaque, ?*wl.wl_proxy) callconv(.c) void,
    dnd_drop_performed: *const fn (?*anyopaque, ?*wl.wl_proxy) callconv(.c) void,
    dnd_finished: *const fn (?*anyopaque, ?*wl.wl_proxy) callconv(.c) void,
    action: *const fn (?*anyopaque, ?*wl.wl_proxy, u32) callconv(.c) void,
};

const data_source_listener = DataSourceListener{
    .target = on_source_target,
    .send = on_source_send,
    .cancelled = on_source_cancelled,
    .dnd_drop_performed = on_source_dnd_drop,
    .dnd_finished = on_source_dnd_finished,
    .action = on_source_action,
};

fn on_source_target(
    data: ?*anyopaque,
    source: ?*wl.wl_proxy,
    mime_z: ?[*:0]const u8,
) callconv(.c) void {
    _ = data;
    _ = mime_z;
    std.debug.assert(source != null);
}

fn on_source_send(
    data: ?*anyopaque,
    source: ?*wl.wl_proxy,
    mime_z: ?[*:0]const u8,
    fd: i32,
) callconv(.c) void {
    _ = data;
    _ = mime_z;
    std.debug.assert(fd >= 0);
    defer _ = close(fd);
    if (source != g_own_source) return;
    write_all(fd, g_own_text[0..g_own_len]);
}

fn on_source_cancelled(data: ?*anyopaque, source: ?*wl.wl_proxy) callconv(.c) void {
    _ = data;
    std.debug.assert(source != null);
    if (source != g_own_source) return;
    wl.data_source_destroy(source.?);
    g_own_source = null;
    g_own_len = 0;
}

fn on_source_dnd_drop(data: ?*anyopaque, source: ?*wl.wl_proxy) callconv(.c) void {
    _ = data;
    std.debug.assert(source != null);
}

fn on_source_dnd_finished(data: ?*anyopaque, source: ?*wl.wl_proxy) callconv(.c) void {
    _ = data;
    std.debug.assert(source != null);
}

fn on_source_action(data: ?*anyopaque, source: ?*wl.wl_proxy, action: u32) callconv(.c) void {
    _ = data;
    _ = action;
    std.debug.assert(source != null);
}

// ---- unimplemented API-parity surface ----

pub fn register_hit_test(hit_test_cb: HitTestFn, redraw_cb: RedrawFn, ctx: *anyopaque) void {
    std.debug.assert(@intFromPtr(ctx) != 0);
    g_hit_test = hit_test_cb;
    g_redraw = redraw_cb;
    g_ctx = ctx;
}

pub fn register_paint_now(cb: RedrawFn) void {
    g_paint_now = cb;
}

pub fn hovered_caption_button() CaptionButton {
    return g_hover_caption;
}

pub fn apply_cursor(kind: CursorKind) void {
    g_cursor = kind;
    set_cursor_image(kind);
}

pub fn current_shift_down() bool {
    return g_shift_down;
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

pub fn pasteboard_read_into(buf: []u8) []const u8 {
    if (buf.len == 0) return "";
    // Our own selection reads back from the local copy: receive() would route
    // to OUR send handler, which cannot run while this thread blocks on the
    // pipe (one thread owns both ends of that dance).
    if (g_own_source != null) {
        const n = @min(g_own_len, buf.len);
        @memcpy(buf[0..n], g_own_text[0..n]);
        return buf[0..n];
    }
    const offer = g_selection_offer orelse return "";
    const mime = mime_string(g_selection_mime) orelse return "";
    var fds: [2]i32 = .{ -1, -1 };
    if (pipe2(&fds, O_CLOEXEC) != 0) return "";
    wl.data_offer_receive(offer, mime, fds[1]);
    _ = close(fds[1]);
    wl.flush();
    const len = read_pipe_bounded(fds[0], buf);
    _ = close(fds[0]);
    return buf[0..len];
}

pub fn pasteboard_write_string(text: []const u8) void {
    const device = g_data_device orelse return;
    // A selection claim needs the serial of a real input event; without any
    // interaction yet there is nothing to anchor it to and compositors drop it.
    const serial = if (g_button_serial != 0) g_button_serial else g_enter_serial;
    if (serial == 0) return;
    const source = wl.create_data_source() orelse return;
    wl.add_listener(source, &data_source_listener, null);
    wl.data_source_offer(source, MIME_UTF8_PLAIN);
    wl.data_source_offer(source, MIME_UTF8_STRING);
    wl.data_source_offer(source, MIME_PLAIN);
    wl.data_device_set_selection(device, source, serial);
    if (g_own_source) |old| wl.data_source_destroy(old);
    g_own_source = source;
    g_own_len = @min(text.len, MAX_CLIPBOARD_BYTES);
    @memcpy(g_own_text[0..g_own_len], text[0..g_own_len]);
    g_own_echo_pending = true;
    wl.flush();
}

// Edge-triggered external-change poll, the windows clipboard-sequence shape:
// prime on first call, then report each new selection once unless it was the
// echo of our own write.
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

pub fn desktop_accent_color() ?types.Rgba {
    return desktop_theme.accent_color();
}

pub fn display_count() u32 {
    var count: u32 = 0;
    for (&wl.outputs) |*info| {
        if (output_usable(info)) count += 1;
    }
    return count;
}

// Bounds in the compositor's global logical space (the cross-platform
// "points"): origin straight from wl_output geometry, size = current mode
// divided by the integer scale, axes swapped for 90/270 transforms.
pub fn display_bounds(index: u32) geometry.BoundsF {
    var at: u32 = 0;
    for (&wl.outputs) |*info| {
        if (!output_usable(info)) continue;
        if (at != index) {
            at += 1;
            continue;
        }
        std.debug.assert(info.scale >= 1);
        std.debug.assert(info.mode_h > 0);
        const rotated = @rem(info.transform, 2) == 1;
        const logical_w = if (rotated) info.mode_h else info.mode_w;
        const logical_h = if (rotated) info.mode_w else info.mode_h;
        return .{
            .origin = .{ .x = @floatFromInt(info.x), .y = @floatFromInt(info.y) },
            .size = .{
                .width = @floatFromInt(@divTrunc(logical_w, info.scale)),
                .height = @floatFromInt(@divTrunc(logical_h, info.scale)),
            },
        };
    }
    return .{};
}

fn output_usable(info: *const wl.OutputInfo) bool {
    return info.proxy != null and info.mode_w > 0;
}
