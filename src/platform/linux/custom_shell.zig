// The custom-chrome Wayland window: a wl_surface + xdg_toplevel with client-side
// decorations, mirroring the macOS/Windows custom_shell contract. The surface
// shows a wl_shm buffer filled with the theme background - a window must attach
// SOME buffer or the compositor never maps it. Input, cursor, text-field,
// clipboard, grab, and display enumeration are unimplemented no-ops that keep
// the facade surface complete, the windows/window.zig precedent.

const std = @import("std");
const wl = @import("wayland.zig");
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

// Linux draws its own window controls like Windows; same Win11-width caption.
pub const CAPTION_BTN_W: f32 = 46;
pub const CAPTION_CLUSTER_W: f32 = CAPTION_BTN_W * 3;

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

fn destroy_window(win: *ShellWindow) void {
    std.debug.assert(win.in_use);
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
    win.pending_w = width; // 0 = the client picks; resolved at the ack
    win.pending_h = height;
    win.activated = false;
    win.maximized = false;
    win.fullscreen = false;
    const array = states orelse return;
    const entries: u32 = @intCast(@min(array.size / 4, TOPLEVEL_STATES_MAX));
    const items: [*]const u32 = @ptrCast(@alignCast(array.data orelse return));
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

fn on_toplevel_close(data: ?*anyopaque, toplevel: ?*wl.wl_proxy) callconv(.c) void {
    std.debug.assert(data != null);
    std.debug.assert(toplevel != null);
    const win: *ShellWindow = @ptrCast(@alignCast(data.?));
    std.debug.assert(win.in_use);
    if (g_window_close) |cb| cb(g_window_close_ctx.?, @ptrCast(win));
    // Closing the first window quits the app; extra windows just close (their
    // teardown is the registered close callback's job, the windows model).
    if (window_index(win) == 0) wl.quit_requested = true;
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

// ---- unimplemented API-parity surface ----

pub fn set_grab(on: bool) void {
    _ = on;
}

pub fn is_grabbed() bool {
    return false;
}

pub fn release_grab_if_blurred() void {}

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

pub fn display_count() u32 {
    return 0;
}

pub fn display_bounds(index: u32) geometry.BoundsF {
    _ = index;
    return .{};
}
