// The custom-chrome Win32 window: a borderless HWND (the native frame is removed
// in WM_NCCALCSIZE) backing a D3D11 swapchain, with ONE unified title bar (the
// painted band) that hosts both the consumer's titlebar components and the
// window controls (minimize / maximize / close) drawn on the right - the Zed /
// VS Code model. The window buttons are routed to native behavior via
// WM_NCHITTEST (HTMINBUTTON/HTMAXBUTTON/HTCLOSE); empty band areas drag the
// window (HTCAPTION); the consumer's interactive components stay clickable
// (HTCLIENT) via a hitbox query. Mirrors the macOS custom_shell contract the
// cross-platform paint loop drives.

const std = @import("std");
const win32 = @import("win32.zig");
const loop = @import("loop.zig");
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
    on_middle_down: *const fn (ctx: *anyopaque, x: f32, y: f32) void,
    on_drag: *const fn (ctx: *anyopaque, x: f32, y: f32) void,
    on_up: *const fn (ctx: *anyopaque) void,
    on_scroll: *const fn (ctx: *anyopaque, dx: f32, dy: f32) void,
    on_key: *const fn (ctx: *anyopaque, ev: KeyEvent) void,
    ctx: *anyopaque,
};

pub const CursorKind = enum { default, col_resize, row_resize };

pub const CaptionButton = enum { none, minimize, maximize, close };

// Returns true if the point (in points) is over an interactive titlebar
// component CONTAINED within the band (height band_h, in points), so
// WM_NCHITTEST yields HTCLIENT there instead of a drag. Band-containment
// excludes any full-window backstop hitbox the consumer may register, so empty
// band area still drags.
pub const HitTestFn = *const fn (ctx: *anyopaque, x: f32, y: f32, band_h: f32) bool;
pub const RedrawFn = *const fn (ctx: *anyopaque) void;

// Width of one window-control button, in points (matches the Win11 caption).
pub const CAPTION_BTN_W: f32 = 46;
pub const CAPTION_CLUSTER_W: f32 = CAPTION_BTN_W * 3;

pub const Error = error{
    ClassRegisterFailed,
    WindowCreateFailed,
    RawInputRegisterFailed,
};

pub const ContentSize = extern struct { width: f64, height: f64 };

pub const CustomShellHandle = struct {
    window: win32.HWND,
    // cross-platform "render surface" handle (CAMetalLayer on macOS); the HWND
    // here, which the D3D11 renderer turns into a swapchain.
    metal_layer: *anyopaque,
    height: f32,
    theme: types.Theme,
    titlebar: types.TitlebarOptions,

    pub fn focus(self: CustomShellHandle) void {
        _ = win32.SetForegroundWindow(self.window);
        _ = win32.SetFocus(self.window);
    }

    pub fn is_fullscreen(self: CustomShellHandle) bool {
        _ = self;
        return g_fullscreen;
    }

    // Borderless monitor-cover, not exclusive fullscreen - it composites with the
    // rest of the desktop and switches instantly, which a remote view wants.
    pub fn set_fullscreen(self: CustomShellHandle, on: bool) void {
        std.debug.assert(@intFromPtr(self.window) != 0);
        if (on == g_fullscreen) return;
        const hwnd = self.window;
        if (on) {
            g_saved_style = win32.GetWindowLongPtrW(hwnd, win32.GWL_STYLE);
            _ = win32.GetWindowRect(hwnd, &g_saved_rect);
            const mon = win32.MonitorFromWindow(hwnd, win32.MONITOR_DEFAULTTONEAREST) orelse return;
            var mi: win32.MONITORINFO = .{
                .cbSize = @sizeOf(win32.MONITORINFO),
                .rcMonitor = undefined,
                .rcWork = undefined,
                .dwFlags = 0,
            };
            if (win32.GetMonitorInfoW(mon, &mi) == 0) return;
            const bare = g_saved_style & ~@as(isize, win32.WS_OVERLAPPEDWINDOW);
            _ = win32.SetWindowLongPtrW(hwnd, win32.GWL_STYLE, bare);
            const r = mi.rcMonitor;
            place(hwnd, r.left, r.top, r.right - r.left, r.bottom - r.top);
            g_fullscreen = true;
        } else {
            _ = win32.SetWindowLongPtrW(hwnd, win32.GWL_STYLE, g_saved_style);
            const r = g_saved_rect;
            place(hwnd, r.left, r.top, r.right - r.left, r.bottom - r.top);
            g_fullscreen = false;
        }
    }

    pub fn backing_scale_factor(self: CustomShellHandle) f32 {
        return scale_for(self.window);
    }

    pub fn is_maximized(self: CustomShellHandle) bool {
        return win32.IsZoomed(self.window) != 0;
    }

    pub fn is_minimized(self: CustomShellHandle) bool {
        return win32.IsIconic(self.window) != 0;
    }

    pub fn is_key(self: CustomShellHandle) bool {
        return win32.GetForegroundWindow() == self.window;
    }

    pub fn sync_drawable_size(self: CustomShellHandle) ContentSize {
        var rect: win32.RECT = undefined;
        _ = win32.GetClientRect(self.window, &rect);
        const scale = scale_for(self.window);
        std.debug.assert(scale > 0); // divisor below
        return .{
            .width = @as(f64, @floatFromInt(rect.right - rect.left)) / scale,
            .height = @as(f64, @floatFromInt(rect.bottom - rect.top)) / scale,
        };
    }

    pub fn deinit(self: CustomShellHandle) void {
        _ = win32.DestroyWindow(self.window);
    }
};

// Process-wide shell state. Callback tables stay global; HWND-local context
// lives in GWLP_USERDATA and is selected in WndProc.
var g_dispatch: ?MouseDispatch = null;
var g_class_registered: bool = false;
var g_titlebar_height: f32 = 37;
var g_min_w_pt: f32 = 0;
var g_min_h_pt: f32 = 0;
var g_cursor: CursorKind = .default;
var g_tracking_mouse: bool = false;
var g_tracking_nc: bool = false;
var g_hover_caption: CaptionButton = .none;
var g_pressed_caption: CaptionButton = .none;
var g_fullscreen: bool = false;
var g_saved_style: isize = 0;
var g_saved_rect: win32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };

fn place(hwnd: win32.HWND, x: i32, y: i32, w: i32, h: i32) void {
    const flags = win32.SWP_NOZORDER | win32.SWP_FRAMECHANGED | win32.SWP_SHOWWINDOW;
    _ = win32.SetWindowPos(hwnd, null, x, y, w, h, flags);
}
// Text-field overlay: one persistent EDIT child reused across fields.
var g_edit: ?win32.HWND = null;
var g_main_hwnd: ?win32.HWND = null;
var g_root_hwnd: ?win32.HWND = null;
var g_grab_hwnd: ?win32.HWND = null;
var g_field_visible: bool = false;
var g_active_id: u32 = 0;
var g_active_secure: bool = false;
var g_field_text: win32.COLORREF = 0xFFFFFF;
var g_field_bg: win32.COLORREF = 0;
var g_field_brush: ?win32.HBRUSH = null;
var g_edit_font: ?win32.HFONT = null;
var g_edit_font_px: i32 = 0;
var g_hit_test: ?HitTestFn = null;
var g_redraw: ?RedrawFn = null;
var g_paint_now: ?RedrawFn = null;
var g_ctx: ?*anyopaque = null;
// Windows exposes clipboard changes as one process-wide sequence.
var g_clipboard_last_seen: win32.DWORD = 0;
var g_clipboard_own: win32.DWORD = 0;
var g_clipboard_primed: bool = false;
// The single HWND owns one grab stream; WndProc needs this outside the paint stack.
var g_raw: ?RawDispatch = null;
var g_grabbed: bool = false;
var g_cursor_hide_steps: u32 = 0;
var g_window_close: ?WindowCloseFn = null;
var g_window_close_ctx: ?*anyopaque = null;

const RAW_DEVICE_COUNT: u32 = 2;
const CURSOR_SHOW_COUNT_LIMIT: u32 = 16;

fn surface_ctx(hwnd: win32.HWND) ?*anyopaque {
    const value = win32.GetWindowLongPtrW(hwnd, win32.GWLP_USERDATA);
    if (value == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(value)));
}

fn dispatch_ctx(hwnd: win32.HWND, fallback: *anyopaque) *anyopaque {
    return surface_ctx(hwnd) orelse fallback;
}

fn paint_now(hwnd: win32.HWND) void {
    if (g_paint_now) |pn| {
        const c = surface_ctx(hwnd) orelse (g_ctx orelse return);
        pn(c);
    }
}

const RESIZE_BORDER_PX: i32 = 6;
const CLASS_NAME = win32.L("ZiguiCustomShell");

fn scale_for(hwnd: win32.HWND) f32 {
    const dpi = win32.GetDpiForWindow(hwnd);
    if (dpi == 0) return 1.0;
    return @as(f32, @floatFromInt(dpi)) / win32.USER_DEFAULT_SCREEN_DPI;
}

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
    std.debug.assert(@intFromPtr(handle.window) != 0);
    std.debug.assert(@intFromPtr(ctx) != 0);
    const value: isize = @bitCast(@intFromPtr(ctx));
    _ = win32.SetWindowLongPtrW(handle.window, win32.GWLP_USERDATA, value);
}

pub fn set_grab(on: bool) void {
    if (on == g_grabbed) return;
    g_grabbed = on;
    if (on) {
        if (grab_target_hwnd()) |hwnd| {
            g_grab_hwnd = hwnd;
            register_raw_devices(hwnd) catch {
                g_grabbed = false;
                g_grab_hwnd = null;
                return;
            };
            _ = win32.SetForegroundWindow(hwnd);
            _ = win32.SetFocus(hwnd);
            confine_cursor(hwnd);
        }
        hide_cursor();
    } else {
        g_grab_hwnd = null;
        _ = win32.ClipCursor(null);
        show_cursor();
    }
}

pub fn is_grabbed() bool {
    return g_grabbed;
}

pub fn release_grab_if_blurred() void {
    if (!g_grabbed) return;
    const hwnd = g_grab_hwnd orelse return;
    const active = win32.GetForegroundWindow() orelse {
        set_grab(false);
        return;
    };
    if (active != hwnd) set_grab(false);
}

fn grab_target_hwnd() ?win32.HWND {
    const active = win32.GetForegroundWindow();
    if (active) |hwnd| {
        if (surface_ctx(hwnd) != null) return hwnd;
    }
    return g_main_hwnd orelse g_root_hwnd;
}

// Windows-only: lets WM_NCHITTEST ask the paint layer whether a band point hits
// an interactive component (-> HTCLIENT) and lets caption hover request a redraw.
pub fn register_hit_test(hit_test_cb: HitTestFn, redraw_cb: RedrawFn, ctx: *anyopaque) void {
    g_hit_test = hit_test_cb;
    g_redraw = redraw_cb;
    g_ctx = ctx;
}

// A SYNCHRONOUS repaint, used inside the modal resize loop where the vsync thread
// message is dropped: without it the swapchain stretches until the drag ends.
pub fn register_paint_now(cb: RedrawFn) void {
    g_paint_now = cb;
}

pub fn hovered_caption_button() CaptionButton {
    return g_hover_caption;
}

pub fn apply_cursor(kind: CursorKind) void {
    g_cursor = kind;
    set_cursor(kind);
}

pub fn current_shift_down() bool {
    const state = @as(u16, @bitCast(win32.GetKeyState(@intCast(win32.VK_SHIFT))));
    return (state & win32.KEY_DOWN_MASK) != 0;
}

// Keep the display + machine awake (a stream wants this). The app re-asserts it
// every frame, so a cached value keeps the call to one per change.
var g_awake: bool = false;
pub fn set_keep_awake(on: bool) void {
    if (g_awake == on) return;
    g_awake = on;
    const flags: u32 = if (on)
        win32.ES_CONTINUOUS | win32.ES_SYSTEM_REQUIRED | win32.ES_DISPLAY_REQUIRED
    else
        win32.ES_CONTINUOUS;
    _ = win32.SetThreadExecutionState(flags);
}

fn request_redraw() void {
    if (g_redraw) |r| {
        if (g_ctx) |c| r(c);
    }
}

fn request_redraw_for(hwnd: win32.HWND) void {
    if (g_redraw) |r| {
        const c = surface_ctx(hwnd) orelse (g_ctx orelse return);
        r(c);
    }
}

fn set_cursor(kind: CursorKind) void {
    const id: u16 = switch (kind) {
        .default => win32.IDC_ARROW,
        .col_resize => win32.IDC_SIZEWE,
        .row_resize => win32.IDC_SIZENS,
    };
    _ = win32.SetCursor(win32.LoadCursorW(null, win32.make_int_resource(id)));
}

fn hide_cursor() void {
    std.debug.assert(g_cursor_hide_steps == 0);
    var step: u32 = 0;
    while (step < CURSOR_SHOW_COUNT_LIMIT) : (step += 1) {
        g_cursor_hide_steps += 1;
        if (win32.ShowCursor(win32.FALSE) < 0) return;
    }
    std.debug.assert(false);
}

fn show_cursor() void {
    std.debug.assert(g_cursor_hide_steps <= CURSOR_SHOW_COUNT_LIMIT);
    while (g_cursor_hide_steps > 0) {
        _ = win32.ShowCursor(win32.TRUE);
        g_cursor_hide_steps -= 1;
    }
}

fn confine_cursor(hwnd: win32.HWND) void {
    std.debug.assert(@intFromPtr(hwnd) != 0);
    var rect: win32.RECT = undefined;
    if (win32.GetWindowRect(hwnd, &rect) == 0) return;
    std.debug.assert(rect.right > rect.left);
    std.debug.assert(rect.bottom > rect.top);
    _ = win32.ClipCursor(&rect);
}

pub fn open(opts: types.NativeShellOptions) Error!CustomShellHandle {
    const instance = win32.GetModuleHandleW(null) orelse return error.WindowCreateFailed;
    try ensure_window_class(instance);

    g_titlebar_height = @floatCast(opts.titlebar.height);
    g_min_w_pt = @floatCast(opts.min_width);
    g_min_h_pt = @floatCast(opts.min_height);

    var title_buf: [256]u16 = undefined;
    const tlen = std.unicode.utf8ToUtf16Le(&title_buf, opts.title) catch 0;
    title_buf[@min(tlen, title_buf.len - 1)] = 0;
    const title: [*:0]const u16 = @ptrCast(&title_buf);

    const hwnd = try create_shell_window(instance, title, opts.width, opts.height);
    errdefer _ = win32.DestroyWindow(hwnd);
    const was_first = g_root_hwnd == null;
    if (was_first) g_root_hwnd = hwnd;
    errdefer {
        if (was_first) g_root_hwnd = null;
    }
    g_main_hwnd = hwnd;
    try register_raw_devices(hwnd);

    style_shell_window(hwnd);
    resize_shell_window(hwnd, opts.width, opts.height);
    _ = win32.ShowWindow(hwnd, win32.SW_SHOW);
    _ = win32.UpdateWindow(hwnd);

    const theme = opts.theme orelse types.Theme.default_dark();
    return .{
        .window = hwnd,
        .metal_layer = @ptrCast(hwnd),
        .height = @floatCast(opts.height),
        .theme = theme,
        .titlebar = opts.titlebar,
    };
}

fn ensure_window_class(instance: win32.HINSTANCE) Error!void {
    if (g_class_registered) return;
    const wc = win32.WNDCLASSEXW{
        .cbSize = @sizeOf(win32.WNDCLASSEXW),
        .style = win32.CS_HREDRAW | win32.CS_VREDRAW,
        .lpfnWndProc = wnd_proc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = instance,
        .hIcon = null,
        .hCursor = win32.LoadCursorW(null, win32.make_int_resource(win32.IDC_ARROW)),
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = CLASS_NAME,
        .hIconSm = null,
    };
    if (win32.RegisterClassExW(&wc) == 0) return error.ClassRegisterFailed;
    g_class_registered = true;
}

fn create_shell_window(
    instance: win32.HINSTANCE,
    title: [*:0]const u16,
    width: f64,
    height: f64,
) Error!win32.HWND {
    // WS_OVERLAPPEDWINDOW keeps native snap; WM_NCCALCSIZE removes the frame.
    return win32.CreateWindowExW(
        win32.WS_EX_APPWINDOW,
        CLASS_NAME,
        title,
        win32.WS_OVERLAPPEDWINDOW | win32.WS_CLIPCHILDREN,
        win32.CW_USEDEFAULT,
        win32.CW_USEDEFAULT,
        @intFromFloat(width),
        @intFromFloat(height),
        null,
        null,
        instance,
        null,
    ) orelse error.WindowCreateFailed;
}

fn register_raw_devices(hwnd: win32.HWND) Error!void {
    std.debug.assert(@intFromPtr(hwnd) != 0);
    var devices = [_]win32.RAWINPUTDEVICE{
        .{
            .usUsagePage = win32.HID_USAGE_PAGE_GENERIC,
            .usUsage = win32.HID_USAGE_GENERIC_MOUSE,
            .dwFlags = 0,
            .hwndTarget = hwnd,
        },
        .{
            .usUsagePage = win32.HID_USAGE_PAGE_GENERIC,
            .usUsage = win32.HID_USAGE_GENERIC_KEYBOARD,
            .dwFlags = 0,
            .hwndTarget = hwnd,
        },
    };
    comptime std.debug.assert(devices.len == RAW_DEVICE_COUNT);
    const ok = win32.RegisterRawInputDevices(
        &devices,
        RAW_DEVICE_COUNT,
        @sizeOf(win32.RAWINPUTDEVICE),
    );
    if (ok == 0) return error.RawInputRegisterFailed;
}

fn style_shell_window(hwnd: win32.HWND) void {
    // WM_NCCALCSIZE drops Win11 auto-rounding, so request it back from DWM.
    var corner: u32 = win32.DWMWCP_ROUND;
    const corner_attr = win32.DWMWA_WINDOW_CORNER_PREFERENCE;
    _ = win32.DwmSetWindowAttribute(hwnd, corner_attr, &corner, @sizeOf(u32));
    var border: win32.COLORREF = 0x00555555;
    const border_sz: win32.DWORD = @sizeOf(win32.COLORREF);
    _ = win32.DwmSetWindowAttribute(hwnd, win32.DWMWA_BORDER_COLOR, &border, border_sz);
}

fn resize_shell_window(hwnd: win32.HWND, width: f64, height: f64) void {
    const scale = scale_for(hwnd);
    const w_px: i32 = @intFromFloat(width * @as(f64, scale));
    const h_px: i32 = @intFromFloat(height * @as(f64, scale));
    std.debug.assert(w_px > 0);
    std.debug.assert(h_px > 0);
    const flags = win32.SWP_NOMOVE | win32.SWP_NOZORDER | win32.SWP_FRAMECHANGED;
    _ = win32.SetWindowPos(hwnd, null, 0, 0, w_px, h_px, flags);
}

fn dispatch_point(hwnd: win32.HWND, l: win32.LPARAM) [2]f32 {
    const scale = scale_for(hwnd);
    std.debug.assert(scale > 0); // divisor below
    const x: f32 = @as(f32, @floatFromInt(win32.get_x_lparam(l))) / scale;
    const y: f32 = @as(f32, @floatFromInt(win32.get_y_lparam(l))) / scale;
    return .{ x, y };
}

fn track_mouse_leave(hwnd: win32.HWND) void {
    if (g_tracking_mouse) return;
    var tme = win32.TRACKMOUSEEVENT{
        .cbSize = @sizeOf(win32.TRACKMOUSEEVENT),
        .dwFlags = win32.TME_LEAVE,
        .hwndTrack = hwnd,
        .dwHoverTime = 0,
    };
    _ = win32.TrackMouseEvent(&tme);
    g_tracking_mouse = true;
}

fn track_nc_leave(hwnd: win32.HWND) void {
    if (g_tracking_nc) return;
    var tme = win32.TRACKMOUSEEVENT{
        .cbSize = @sizeOf(win32.TRACKMOUSEEVENT),
        .dwFlags = win32.TME_LEAVE | win32.TME_NONCLIENT,
        .hwndTrack = hwnd,
        .dwHoverTime = 0,
    };
    _ = win32.TrackMouseEvent(&tme);
    g_tracking_nc = true;
}

fn clear_caption_hover(hwnd: win32.HWND) void {
    if (g_hover_caption != .none) {
        g_hover_caption = .none;
        request_redraw_for(hwnd);
    }
}

fn key_mods() KeyMods {
    const down = struct {
        fn f(vk: win32.WPARAM) bool {
            return (@as(u16, @bitCast(win32.GetKeyState(@intCast(vk)))) & win32.KEY_DOWN_MASK) != 0;
        }
    }.f;
    // Windows has no separate command key: Ctrl IS the command modifier, so it
    // maps to cmd alone. The kit's shortcuts are keyed on cmd (macOS heritage)
    // and gate on !ctrl, so leaving ctrl set here would suppress copy/cut/paste.
    const ctrl = down(win32.VK_CONTROL);
    return .{
        .cmd = ctrl,
        .ctrl = false,
        .shift = down(win32.VK_SHIFT),
        .alt = down(win32.VK_MENU),
    };
}

fn key_code_for_vk(vk: win32.WPARAM) ?KeyCode {
    return switch (vk) {
        win32.VK_LEFT => .left,
        win32.VK_RIGHT => .right,
        win32.VK_UP => .up,
        win32.VK_DOWN => .down,
        win32.VK_BACK => .backspace,
        win32.VK_DELETE => .delete_fwd,
        win32.VK_RETURN => .enter,
        win32.VK_TAB => .tab,
        win32.VK_ESCAPE => .escape,
        win32.VK_HOME => .home,
        win32.VK_END => .end,
        win32.VK_PRIOR => .page_up,
        win32.VK_NEXT => .page_down,
        else => null,
    };
}

// Which window-control button a client-pixel point falls on (right-aligned),
// or .none. Buttons span the full band height.
fn caption_button_at(px: i32, cw: i32, scale: f32) CaptionButton {
    const btn_w: i32 = @intFromFloat(CAPTION_BTN_W * scale);
    const from_right = cw - px;
    if (from_right < 0) return .none;
    if (from_right < btn_w) return .close;
    if (from_right < 2 * btn_w) return .maximize;
    if (from_right < 3 * btn_w) return .minimize;
    return .none;
}

fn caption_from_ht(code: win32.WPARAM) CaptionButton {
    if (code == @as(win32.WPARAM, @intCast(win32.HTCLOSE))) return .close;
    if (code == @as(win32.WPARAM, @intCast(win32.HTMAXBUTTON))) return .maximize;
    if (code == @as(win32.WPARAM, @intCast(win32.HTMINBUTTON))) return .minimize;
    return .none;
}

// Custom-chrome window controls are handled here rather than left to
// DefWindowProc, which is unreliable for caption buttons on a frameless window.
fn perform_caption_action(hwnd: win32.HWND, cb: CaptionButton) void {
    switch (cb) {
        .minimize => _ = win32.ShowWindow(hwnd, win32.SW_MINIMIZE),
        .maximize => {
            const cmd = if (win32.IsZoomed(hwnd) != 0) win32.SW_RESTORE else win32.SW_MAXIMIZE;
            _ = win32.ShowWindow(hwnd, cmd);
        },
        .close => _ = win32.SendMessageW(hwnd, win32.WM_CLOSE, 0, 0),
        .none => {},
    }
}

fn hit_test(hwnd: win32.HWND, l: win32.LPARAM) win32.LRESULT {
    var wr: win32.RECT = undefined;
    _ = win32.GetWindowRect(hwnd, &wr);
    // NCHITTEST lParam is in screen coordinates; the borderless client starts at
    // the window's top-left.
    const px = win32.get_x_lparam(l) - wr.left;
    const py = win32.get_y_lparam(l) - wr.top;
    const cw = wr.right - wr.left;
    const ch = wr.bottom - wr.top;
    const scale = scale_for(hwnd);
    std.debug.assert(scale > 0); // feeds band_px + point divisions below

    // Resize borders (no border while maximized).
    if (win32.IsZoomed(hwnd) == 0) {
        const b = RESIZE_BORDER_PX;
        const on_left = px < b;
        const on_right = px >= cw - b;
        const on_top = py < b;
        const on_bottom = py >= ch - b;
        if (on_top and on_left) return win32.HTTOPLEFT;
        if (on_top and on_right) return win32.HTTOPRIGHT;
        if (on_bottom and on_left) return win32.HTBOTTOMLEFT;
        if (on_bottom and on_right) return win32.HTBOTTOMRIGHT;
        if (on_left) return win32.HTLEFT;
        if (on_right) return win32.HTRIGHT;
        if (on_top) return win32.HTTOP;
        if (on_bottom) return win32.HTBOTTOM;
    }

    const band_px: i32 = @intFromFloat(g_titlebar_height * scale);
    if (py < band_px) {
        switch (caption_button_at(px, cw, scale)) {
            .close => return win32.HTCLOSE,
            .maximize => return win32.HTMAXBUTTON,
            .minimize => return win32.HTMINBUTTON,
            .none => {},
        }
        if (g_hit_test) |ht| {
            const c = surface_ctx(hwnd) orelse (g_ctx orelse return win32.HTCAPTION);
            const x_pt = @as(f32, @floatFromInt(px)) / scale;
            const y_pt = @as(f32, @floatFromInt(py)) / scale;
            if (ht(c, x_pt, y_pt, g_titlebar_height)) return win32.HTCLIENT;
        }
        return win32.HTCAPTION;
    }
    return win32.HTCLIENT;
}

fn wnd_proc(
    hwnd: win32.HWND,
    msg: win32.UINT,
    w: win32.WPARAM,
    l: win32.LPARAM,
) callconv(.winapi) win32.LRESULT {
    switch (msg) {
        win32.WM_NCCALCSIZE => if (handle_nc_calc_size(hwnd, w, l)) |r| return r,
        win32.WM_GETMINMAXINFO => return handle_minmax(hwnd, l),
        win32.WM_NCHITTEST => return hit_test(hwnd, l),
        win32.WM_INPUT => return handle_raw_input(hwnd, w, l),
        win32.WM_NCMOUSEMOVE,
        win32.WM_NCMOUSELEAVE,
        win32.WM_NCLBUTTONDOWN,
        win32.WM_NCLBUTTONUP,
        => if (handle_caption_message(hwnd, msg, w)) |r| return r,
        win32.WM_ACTIVATE => handle_activate(w),
        win32.WM_KILLFOCUS => set_grab(false),
        win32.WM_ERASEBKGND => return 1,
        win32.WM_ENTERSIZEMOVE,
        win32.WM_SIZE,
        win32.WM_EXITSIZEMOVE,
        => handle_size_message(hwnd, msg),
        win32.WM_DISPLAYCHANGE,
        win32.WM_DPICHANGED,
        win32.WM_SETTINGCHANGE,
        => display_cache_reset(),
        win32.WM_CTLCOLOREDIT => if (handle_edit_color(w)) |r| return r,
        win32.WM_SETCURSOR => if (handle_set_cursor(l)) |r| return r,
        win32.WM_CLOSE => return handle_close(hwnd),
        win32.WM_DESTROY => return handle_destroy(hwnd),
        win32.WM_MOUSEMOVE,
        win32.WM_MOUSELEAVE,
        win32.WM_LBUTTONDOWN,
        win32.WM_LBUTTONUP,
        win32.WM_RBUTTONDOWN,
        win32.WM_RBUTTONUP,
        win32.WM_MBUTTONDOWN,
        win32.WM_MBUTTONUP,
        win32.WM_MOUSEWHEEL,
        win32.WM_MOUSEHWHEEL,
        => return handle_mouse_message(hwnd, msg, w, l),
        win32.WM_KEYDOWN,
        win32.WM_KEYUP,
        win32.WM_SYSKEYDOWN,
        win32.WM_SYSKEYUP,
        win32.WM_CHAR,
        => if (handle_key_message(hwnd, msg, w)) |r| return r,
        else => {},
    }
    return win32.DefWindowProcW(hwnd, msg, w, l);
}

fn handle_nc_calc_size(
    hwnd: win32.HWND,
    w: win32.WPARAM,
    l: win32.LPARAM,
) ?win32.LRESULT {
    if (w == 0) return null;
    if (win32.IsZoomed(hwnd) != 0) {
        const params: *win32.NCCALCSIZE_PARAMS = @ptrFromInt(@as(usize, @bitCast(l)));
        const padded = win32.GetSystemMetrics(win32.SM_CXPADDEDBORDER);
        const fx = win32.GetSystemMetrics(win32.SM_CXFRAME) + padded;
        const fy = win32.GetSystemMetrics(win32.SM_CYFRAME) + padded;
        params.rgrc[0].left += fx;
        params.rgrc[0].right -= fx;
        params.rgrc[0].top += fy;
        params.rgrc[0].bottom -= fy;
    }
    return 0;
}

fn handle_minmax(hwnd: win32.HWND, l: win32.LPARAM) win32.LRESULT {
    const mmi: *win32.MINMAXINFO = @ptrFromInt(@as(usize, @bitCast(l)));
    const scale = scale_for(hwnd);
    mmi.ptMinTrackSize.x = @intFromFloat(g_min_w_pt * scale);
    mmi.ptMinTrackSize.y = @intFromFloat(g_min_h_pt * scale);
    return 0;
}

fn handle_activate(w: win32.WPARAM) void {
    const state = w & 0xFFFF;
    if (state == win32.WA_INACTIVE) set_grab(false);
}

fn handle_caption_message(
    hwnd: win32.HWND,
    msg: win32.UINT,
    w: win32.WPARAM,
) ?win32.LRESULT {
    switch (msg) {
        win32.WM_NCMOUSEMOVE => {
            track_nc_leave(hwnd);
            const hovered = caption_from_ht(w);
            if (hovered != g_hover_caption) {
                g_hover_caption = hovered;
                request_redraw_for(hwnd);
            }
        },
        win32.WM_NCMOUSELEAVE => {
            g_tracking_nc = false;
            clear_caption_hover(hwnd);
        },
        win32.WM_NCLBUTTONDOWN => {
            const cb = caption_from_ht(w);
            if (cb != .none) {
                g_pressed_caption = cb;
                return 0; // act on release for a reliable custom-chrome button
            }
        },
        win32.WM_NCLBUTTONUP => {
            const cb = caption_from_ht(w);
            const pressed = g_pressed_caption;
            g_pressed_caption = .none;
            if (cb != .none and cb == pressed) {
                perform_caption_action(hwnd, cb);
                return 0;
            }
        },
        else => std.debug.assert(false),
    }
    return null;
}

fn handle_size_message(hwnd: win32.HWND, msg: win32.UINT) void {
    switch (msg) {
        win32.WM_ENTERSIZEMOVE => {
            // The modal resize loop drives WM_SIZE synchronously and starves vsync.
            loop.resizing.store(true, .seq_cst);
        },
        win32.WM_SIZE => {
            if (loop.resizing.load(.seq_cst)) {
                paint_now(hwnd);
            } else {
                request_redraw_for(hwnd);
            }
        },
        win32.WM_EXITSIZEMOVE => {
            loop.resizing.store(false, .seq_cst);
            paint_now(hwnd);
        },
        else => std.debug.assert(false),
    }
}

fn handle_edit_color(w: win32.WPARAM) ?win32.LRESULT {
    const hdc: win32.HDC = @ptrFromInt(w);
    _ = win32.SetTextColor(hdc, g_field_text);
    _ = win32.SetBkColor(hdc, g_field_bg);
    if (g_field_brush) |br| return @bitCast(@intFromPtr(br));
    return null;
}

fn handle_set_cursor(l: win32.LPARAM) ?win32.LRESULT {
    if (win32.get_x_lparam(l) != win32.HTCLIENT) return null;
    set_cursor(g_cursor);
    return 1;
}

fn handle_close(hwnd: win32.HWND) win32.LRESULT {
    std.debug.assert(@intFromPtr(hwnd) != 0);
    notify_window_close(hwnd);
    retire_surface_ctx(hwnd);
    _ = win32.DestroyWindow(hwnd);
    return 0;
}

fn handle_destroy(hwnd: win32.HWND) win32.LRESULT {
    std.debug.assert(@intFromPtr(hwnd) != 0);
    if (g_grab_hwnd == hwnd) set_grab(false);
    if (g_main_hwnd == hwnd) g_main_hwnd = g_root_hwnd;
    if (g_root_hwnd == hwnd) {
        // Stop vsync first so WM_QUIT is not starved by paints against a dying HWND.
        loop.quitting = true;
        loop.stop_all_vsync();
        win32.PostQuitMessage(0);
    }
    return 0;
}

fn notify_window_close(hwnd: win32.HWND) void {
    std.debug.assert(@intFromPtr(hwnd) != 0);
    const cb = g_window_close orelse return;
    const ctx = g_window_close_ctx orelse return;
    cb(ctx, @ptrFromInt(@intFromPtr(hwnd)));
}

fn retire_surface_ctx(hwnd: win32.HWND) void {
    std.debug.assert(@intFromPtr(hwnd) != 0);
    const closing = surface_ctx(hwnd) orelse return;
    const fallback = if (g_root_hwnd != null and g_root_hwnd != hwnd)
        surface_ctx(g_root_hwnd.?)
    else
        null;
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
    _ = win32.SetWindowLongPtrW(hwnd, win32.GWLP_USERDATA, 0);
}

fn handle_mouse_message(
    hwnd: win32.HWND,
    msg: win32.UINT,
    w: win32.WPARAM,
    l: win32.LPARAM,
) win32.LRESULT {
    if (g_grabbed) return 0;
    switch (msg) {
        win32.WM_MOUSEMOVE => handle_mouse_move(hwnd, l),
        win32.WM_MOUSELEAVE => handle_mouse_leave(hwnd),
        win32.WM_LBUTTONDOWN => handle_mouse_down(hwnd, l),
        win32.WM_LBUTTONUP => if (g_dispatch) |d| d.on_up(dispatch_ctx(hwnd, d.ctx)),
        win32.WM_RBUTTONDOWN => handle_mouse_right_down(hwnd, l),
        win32.WM_MBUTTONDOWN => handle_mouse_middle_down(hwnd, l),
        win32.WM_MOUSEWHEEL => handle_mouse_wheel(hwnd, w),
        win32.WM_RBUTTONUP,
        win32.WM_MBUTTONUP,
        win32.WM_MOUSEHWHEEL,
        => {},
        else => std.debug.assert(false),
    }
    return 0;
}

fn handle_mouse_move(hwnd: win32.HWND, l: win32.LPARAM) void {
    clear_caption_hover(hwnd);
    if (g_dispatch) |d| {
        track_mouse_leave(hwnd);
        const p = dispatch_point(hwnd, l);
        d.on_move(dispatch_ctx(hwnd, d.ctx), p[0], p[1]);
    }
}

fn handle_mouse_leave(hwnd: win32.HWND) void {
    g_tracking_mouse = false;
    if (g_dispatch) |d| d.on_exit(dispatch_ctx(hwnd, d.ctx));
}

fn handle_mouse_down(hwnd: win32.HWND, l: win32.LPARAM) void {
    if (g_dispatch) |d| {
        const p = dispatch_point(hwnd, l);
        d.on_down(dispatch_ctx(hwnd, d.ctx), p[0], p[1]);
    }
}

fn handle_mouse_right_down(hwnd: win32.HWND, l: win32.LPARAM) void {
    if (g_dispatch) |d| {
        const p = dispatch_point(hwnd, l);
        d.on_right_down(dispatch_ctx(hwnd, d.ctx), p[0], p[1]);
    }
}

fn handle_mouse_middle_down(hwnd: win32.HWND, l: win32.LPARAM) void {
    if (g_dispatch) |d| {
        const p = dispatch_point(hwnd, l);
        d.on_middle_down(dispatch_ctx(hwnd, d.ctx), p[0], p[1]);
    }
}

fn handle_mouse_wheel(hwnd: win32.HWND, w: win32.WPARAM) void {
    if (g_dispatch) |d| {
        const raw_delta = win32.get_wheel_delta_wparam(w);
        const notches = @as(f32, @floatFromInt(raw_delta)) / win32.WHEEL_DELTA;
        d.on_scroll(dispatch_ctx(hwnd, d.ctx), 0, notches * 40.0);
    }
}

fn handle_key_message(hwnd: win32.HWND, msg: win32.UINT, w: win32.WPARAM) ?win32.LRESULT {
    if (g_grabbed) return 0;
    switch (msg) {
        win32.WM_KEYDOWN, win32.WM_SYSKEYDOWN => return handle_key_down(hwnd, w),
        win32.WM_KEYUP, win32.WM_SYSKEYUP => return 0,
        win32.WM_CHAR => return handle_char(hwnd, w),
        else => std.debug.assert(false),
    }
    return null;
}

fn handle_key_down(hwnd: win32.HWND, w: win32.WPARAM) ?win32.LRESULT {
    if (g_dispatch) |d| {
        if (key_code_for_vk(w)) |code| {
            d.on_key(dispatch_ctx(hwnd, d.ctx), .{ .code = code, .ch = 0, .mods = key_mods() });
            return 0;
        }
    }
    return null;
}

fn handle_char(hwnd: win32.HWND, w: win32.WPARAM) win32.LRESULT {
    if (g_dispatch) |d| {
        const mods = key_mods();
        const raw: u21 = @intCast(w & 0x10FFFF);
        const ch: u21 = if (mods.cmd and raw >= 0x01 and raw <= 0x1A) raw + 0x60 else raw;
        const printable = ch >= 0x20 and ch != 0x7F;
        const cmd_letter = mods.cmd and ch >= 'a' and ch <= 'z';
        if (printable or cmd_letter) {
            d.on_key(dispatch_ctx(hwnd, d.ctx), .{ .code = .char, .ch = ch, .mods = mods });
        }
    }
    return 0;
}

fn handle_raw_input(hwnd: win32.HWND, w: win32.WPARAM, l: win32.LPARAM) win32.LRESULT {
    if (!g_grabbed) {
        return win32.DefWindowProcW(hwnd, win32.WM_INPUT, w, l);
    }
    if (g_raw == null) {
        return win32.DefWindowProcW(hwnd, win32.WM_INPUT, w, l);
    }
    const raw_handle: win32.HRAWINPUT = @ptrFromInt(@as(usize, @bitCast(l)));
    std.debug.assert(@intFromPtr(raw_handle) != 0);
    var raw: win32.RAWINPUT = undefined;
    var size: win32.UINT = @sizeOf(win32.RAWINPUT);
    const got = win32.GetRawInputData(
        raw_handle,
        win32.RID_INPUT,
        &raw,
        &size,
        @sizeOf(win32.RAWINPUTHEADER),
    );
    if (got == win32.RAW_INPUT_ERROR) {
        return win32.DefWindowProcW(hwnd, win32.WM_INPUT, w, l);
    }
    if (got < @sizeOf(win32.RAWINPUTHEADER)) {
        return win32.DefWindowProcW(hwnd, win32.WM_INPUT, w, l);
    }
    switch (raw.header.dwType) {
        win32.RIM_TYPEMOUSE => raw_mouse(hwnd, &raw.data.mouse),
        win32.RIM_TYPEKEYBOARD => raw_keyboard(hwnd, &raw.data.keyboard),
        else => {},
    }
    return win32.DefWindowProcW(hwnd, win32.WM_INPUT, w, l);
}

fn raw_mouse(hwnd: win32.HWND, m: *const win32.RAWMOUSE) void {
    const d = g_raw orelse return;
    const ctx = dispatch_ctx(hwnd, d.ctx);
    const relative = (m.usFlags & win32.MOUSE_MOVE_ABSOLUTE) == 0;
    if (relative and (m.lLastX != 0 or m.lLastY != 0)) {
        d.on_event(ctx, .{ .motion = .{
            .dx = @floatFromInt(m.lLastX),
            .dy = @floatFromInt(m.lLastY),
        } });
    }
    const mods = mods_from_keys();
    const flags = m.buttons.data.usButtonFlags;
    if ((flags & win32.RI_MOUSE_LEFT_BUTTON_DOWN) != 0) raw_button(ctx, .left, true, mods);
    if ((flags & win32.RI_MOUSE_LEFT_BUTTON_UP) != 0) raw_button(ctx, .left, false, mods);
    if ((flags & win32.RI_MOUSE_RIGHT_BUTTON_DOWN) != 0) raw_button(ctx, .right, true, mods);
    if ((flags & win32.RI_MOUSE_RIGHT_BUTTON_UP) != 0) raw_button(ctx, .right, false, mods);
    if ((flags & win32.RI_MOUSE_MIDDLE_BUTTON_DOWN) != 0) raw_button(ctx, .middle, true, mods);
    if ((flags & win32.RI_MOUSE_MIDDLE_BUTTON_UP) != 0) raw_button(ctx, .middle, false, mods);
    if ((flags & win32.RI_MOUSE_BUTTON_4_DOWN) != 0) raw_button(ctx, .other, true, mods);
    if ((flags & win32.RI_MOUSE_BUTTON_4_UP) != 0) raw_button(ctx, .other, false, mods);
    if ((flags & win32.RI_MOUSE_BUTTON_5_DOWN) != 0) raw_button(ctx, .other, true, mods);
    if ((flags & win32.RI_MOUSE_BUTTON_5_UP) != 0) raw_button(ctx, .other, false, mods);
    if ((flags & win32.RI_MOUSE_WHEEL) != 0) {
        raw_wheel(ctx, 0, wheel_units(m.buttons.data.usButtonData));
    }
    if ((flags & win32.RI_MOUSE_HWHEEL) != 0) {
        raw_wheel(ctx, wheel_units(m.buttons.data.usButtonData), 0);
    }
}

fn raw_keyboard(hwnd: win32.HWND, k: *const win32.RAWKEYBOARD) void {
    const d = g_raw orelse return;
    const ctx = dispatch_ctx(hwnd, d.ctx);
    const down = (k.Flags & win32.RI_KEY_BREAK) == 0;
    const scancode = raw_scancode(k.MakeCode, k.Flags);
    if (down and k.VKey == @as(win32.WORD, @intCast(win32.VK_ESCAPE))) {
        set_grab(false);
        return;
    }
    if (scancode == 0) return;
    d.on_event(ctx, .{ .key = .{
        .scancode = scancode,
        .down = down,
        .repeat = false,
        .mods = mods_from_keys(),
    } });
}

fn raw_scancode(make_code: win32.WORD, flags: win32.WORD) u16 {
    if (make_code == 0) return 0;
    if ((flags & win32.RI_KEY_E0) != 0) return 0xE000 | make_code;
    if ((flags & win32.RI_KEY_E1) != 0) return 0xE100 | make_code;
    return make_code;
}

fn raw_button(ctx: *anyopaque, button: input.Button, down: bool, mods: input.Mods) void {
    const d = g_raw orelse return;
    d.on_event(ctx, .{ .button = .{ .button = button, .down = down, .mods = mods } });
}

fn raw_wheel(ctx: *anyopaque, dx: f32, dy: f32) void {
    const d = g_raw orelse return;
    if (dx == 0 and dy == 0) return;
    d.on_event(ctx, .{ .wheel = .{ .dx = dx, .dy = dy } });
}

fn wheel_units(data: win32.WORD) f32 {
    const signed: i16 = @bitCast(data);
    return @as(f32, @floatFromInt(signed)) / win32.WHEEL_DELTA * 40.0;
}

fn mods_from_keys() input.Mods {
    return .{
        .left_shift = key_state_down(win32.VK_LSHIFT),
        .right_shift = key_state_down(win32.VK_RSHIFT),
        .left_control = key_state_down(win32.VK_LCONTROL),
        .right_control = key_state_down(win32.VK_RCONTROL),
        .left_option = key_state_down(win32.VK_LMENU),
        .right_option = key_state_down(win32.VK_RMENU),
        .left_command = key_state_down(win32.VK_LWIN),
        .right_command = key_state_down(win32.VK_RWIN),
        .caps_lock = key_state_toggled(win32.VK_CAPITAL),
    };
}

fn key_state_down(vk: win32.WPARAM) bool {
    const state = @as(u16, @bitCast(win32.GetKeyState(@intCast(vk))));
    return (state & win32.KEY_DOWN_MASK) != 0;
}

fn key_state_toggled(vk: win32.WPARAM) bool {
    const state = @as(u16, @bitCast(win32.GetKeyState(@intCast(vk))));
    return (state & 1) != 0;
}

// Focused text fields use one native EDIT child so IME/caret behavior stays native.
fn ensure_edit(parent: win32.HWND) ?win32.HWND {
    if (g_edit) |e| return e;
    const instance = win32.GetModuleHandleW(null);
    g_edit = win32.CreateWindowExW(
        0,
        win32.L("EDIT"),
        win32.L(""),
        win32.WS_CHILD | win32.ES_LEFT | win32.ES_AUTOHSCROLL,
        0,
        0,
        10,
        10,
        parent,
        null,
        instance,
        null,
    );
    return g_edit;
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
    std.debug.assert(id != 0);
    _ = numeric;
    const edit = ensure_edit(handle.window) orelse return false;
    const scale = scale_for(handle.window);

    place_text_field(edit, x, y, w, h, scale);
    update_text_field_font(edit, @intFromFloat(font_size * scale));
    update_text_field_colors(handle.theme, color);
    seed_text_field(edit, initial, secure, id);
    return true;
}

fn place_text_field(edit: win32.HWND, x: f32, y: f32, w: f32, h: f32, scale: f32) void {
    std.debug.assert(@intFromPtr(edit) != 0);
    std.debug.assert(scale > 0);
    std.debug.assert(w >= 0);
    std.debug.assert(h >= 0);
    _ = win32.SetWindowPos(
        edit,
        null,
        @intFromFloat(x * scale),
        @intFromFloat(y * scale),
        @intFromFloat(w * scale),
        @intFromFloat(h * scale),
        win32.SWP_NOZORDER | win32.SWP_SHOWWINDOW,
    );
}

fn update_text_field_font(edit: win32.HWND, font_px: i32) void {
    std.debug.assert(@intFromPtr(edit) != 0);
    std.debug.assert(font_px > 0);
    if (font_px == g_edit_font_px) return;
    if (g_edit_font) |f| _ = win32.DeleteObject(@ptrCast(f));
    g_edit_font = win32.CreateFontW(
        -font_px,
        0,
        0,
        0,
        400,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        win32.L("Segoe UI"),
    );
    g_edit_font_px = font_px;
    if (g_edit_font) |f| _ = win32.SendMessageW(edit, win32.WM_SETFONT, @intFromPtr(f), 1);
}

fn update_text_field_colors(theme: types.Theme, color: types.Rgba) void {
    std.debug.assert(color.a >= 0);
    std.debug.assert(color.a <= 1);
    g_field_text = win32.rgb_to_colorref(color.r, color.g, color.b);
    const bg = theme.background;
    const bg_cr = win32.rgb_to_colorref(bg.r, bg.g, bg.b);
    if (bg_cr == g_field_bg and g_field_brush != null) return;
    if (g_field_brush) |br| _ = win32.DeleteObject(@ptrCast(br));
    g_field_brush = win32.CreateSolidBrush(bg_cr);
    g_field_bg = bg_cr;
}

fn seed_text_field(edit: win32.HWND, initial: []const u8, secure: bool, id: u32) void {
    std.debug.assert(@intFromPtr(edit) != 0);
    std.debug.assert(id != 0);
    if (g_field_visible and g_active_secure == secure and g_active_id == id) return;
    _ = win32.SendMessageW(edit, win32.EM_SETPASSWORDCHAR, if (secure) 0x2022 else 0, 0);
    var wbuf: [512]u16 = undefined;
    const wlen = std.unicode.utf8ToUtf16Le(&wbuf, initial) catch 0;
    wbuf[@min(wlen, wbuf.len - 1)] = 0;
    _ = win32.SetWindowTextW(edit, @ptrCast(&wbuf));
    const sel_end: win32.WPARAM = @bitCast(@as(isize, std.math.maxInt(i32)));
    const sel_lp: win32.LPARAM = @bitCast(@as(isize, std.math.maxInt(i32)));
    _ = win32.SendMessageW(edit, win32.EM_SETSEL, sel_end, sel_lp);
    _ = win32.SetFocus(edit);
    g_field_visible = true;
    g_active_secure = secure;
    g_active_id = id;
}

pub fn hide_text_field(handle: CustomShellHandle) void {
    if (!g_field_visible) return;
    if (g_edit) |e| _ = win32.ShowWindow(e, win32.SW_HIDE);
    _ = win32.SetFocus(handle.window);
    g_field_visible = false;
}

pub const WindowCloseFn = *const fn (ctx: *anyopaque, ns_window: ?*anyopaque) void;
pub fn register_window_close(cb: WindowCloseFn, ctx: *anyopaque) void {
    g_window_close = cb;
    g_window_close_ctx = ctx;
}

pub fn text_field_value(buf: []u8) []const u8 {
    const edit = g_edit orelse return "";
    var wbuf: [512]u16 = undefined;
    const wlen = win32.GetWindowTextW(edit, @ptrCast(&wbuf), @intCast(wbuf.len));
    if (wlen <= 0) return "";
    const n = std.unicode.utf16LeToUtf8(buf, wbuf[0..@intCast(wlen)]) catch return "";
    return buf[0..n];
}

pub fn pasteboard_read_into(buf: []u8) []const u8 {
    if (win32.OpenClipboard(null) == 0) return "";
    defer _ = win32.CloseClipboard();
    const h = win32.GetClipboardData(win32.CF_UNICODETEXT) orelse return "";
    const ptr = win32.GlobalLock(h) orelse return "";
    defer _ = win32.GlobalUnlock(h);
    const wptr: [*:0]const u16 = @ptrCast(@alignCast(ptr));
    const wlen = std.mem.len(wptr);
    const n = std.unicode.utf16LeToUtf8(buf, wptr[0..wlen]) catch return "";
    return buf[0..n];
}

pub fn pasteboard_write_string(text: []const u8) void {
    const wlen = std.unicode.calcUtf16LeLen(text) catch return;
    const bytes = (wlen + 1) * 2;
    const mem = win32.GlobalAlloc(win32.GMEM_MOVEABLE, bytes) orelse return;
    // mem leaks unless the clipboard takes ownership via SetClipboardData; free it
    // on every early return until ownership transfers.
    var owned_by_clipboard = false;
    defer if (!owned_by_clipboard) {
        _ = win32.GlobalFree(mem);
    };
    const ptr = win32.GlobalLock(mem) orelse return;
    const dst: [*]u16 = @ptrCast(@alignCast(ptr));
    const wrote = std.unicode.utf8ToUtf16Le(dst[0..wlen], text) catch {
        _ = win32.GlobalUnlock(mem);
        return;
    };
    std.debug.assert(wrote == wlen);
    dst[wlen] = 0;
    _ = win32.GlobalUnlock(mem);
    if (win32.OpenClipboard(g_main_hwnd) == 0) return;
    const emptied = win32.EmptyClipboard() != 0;
    if (emptied and win32.SetClipboardData(win32.CF_UNICODETEXT, mem) != null) {
        owned_by_clipboard = true;
    }
    _ = win32.CloseClipboard();
    if (emptied) g_clipboard_own = win32.GetClipboardSequenceNumber();
}

pub fn clipboard_changed_external() bool {
    const sequence = win32.GetClipboardSequenceNumber();
    if (!g_clipboard_primed) {
        g_clipboard_primed = true;
        g_clipboard_last_seen = sequence;
        return false;
    }
    if (sequence == g_clipboard_last_seen) return false;
    g_clipboard_last_seen = sequence;
    return sequence != g_clipboard_own;
}

const DISPLAYS_MAX: u32 = 32;
const DISPLAY_POINT_EPSILON: f32 = 0.25;

const DisplayScale = struct {
    x: f32,
    y: f32,
};

const DisplayInfo = struct {
    monitor: win32.HMONITOR,
    rect: win32.RECT,
    scale: DisplayScale,
    bounds: geometry.BoundsF = .{},
    primary: bool = false,
    placed: bool = false,
    invalid: bool = false,
};

const DisplayList = struct {
    items: [DISPLAYS_MAX]DisplayInfo = undefined,
    count: u32 = 0,
};

// Count-then-bounds callers reuse this until Windows reports display or DPI changes.
var g_display_cache: DisplayList = .{};
var g_display_cache_valid: bool = false;

fn lparam_from_pointer(ptr: anytype) win32.LPARAM {
    const address = @intFromPtr(ptr);
    std.debug.assert(address != 0);
    return @bitCast(address);
}

fn pointer_from_lparam(comptime T: type, value: win32.LPARAM) *T {
    std.debug.assert(value != 0);
    return @ptrFromInt(@as(usize, @bitCast(value)));
}

fn monitor_scale(monitor: win32.HMONITOR) ?DisplayScale {
    std.debug.assert(@intFromPtr(monitor) != 0);
    var dpi_x: win32.UINT = 0;
    var dpi_y: win32.UINT = 0;
    const hr = win32.GetDpiForMonitor(monitor, .effective, &dpi_x, &dpi_y);
    if (hr < 0) return null;
    if (dpi_x == 0) return null;
    if (dpi_y == 0) return null;
    return .{
        .x = @as(f32, @floatFromInt(dpi_x)) / win32.USER_DEFAULT_SCREEN_DPI,
        .y = @as(f32, @floatFromInt(dpi_y)) / win32.USER_DEFAULT_SCREEN_DPI,
    };
}

fn display_info(monitor: win32.HMONITOR) ?DisplayInfo {
    var info: win32.MONITORINFO = .{
        .cbSize = @sizeOf(win32.MONITORINFO),
        .rcMonitor = undefined,
        .rcWork = undefined,
        .dwFlags = 0,
    };
    if (win32.GetMonitorInfoW(monitor, &info) == 0) return null;
    const rect = info.rcMonitor;
    const width = rect.right - rect.left;
    const height = rect.bottom - rect.top;
    if (width <= 0) return null;
    if (height <= 0) return null;
    const scale = monitor_scale(monitor) orelse return null;
    std.debug.assert(scale.x > 0);
    std.debug.assert(scale.y > 0);
    return .{
        .monitor = monitor,
        .rect = rect,
        .scale = scale,
        .bounds = display_size(rect, scale),
        .primary = (info.dwFlags & win32.MONITORINFOF_PRIMARY) != 0,
    };
}

fn display_size(rect: win32.RECT, scale: DisplayScale) geometry.BoundsF {
    const width = rect.right - rect.left;
    const height = rect.bottom - rect.top;
    std.debug.assert(width > 0);
    std.debug.assert(height > 0);
    std.debug.assert(scale.x > 0);
    std.debug.assert(scale.y > 0);
    return geometry.BoundsF.init(
        0,
        0,
        @as(f32, @floatFromInt(width)) / scale.x,
        @as(f32, @floatFromInt(height)) / scale.y,
    );
}

fn ranges_overlap(a0: i32, a1: i32, b0: i32, b1: i32) bool {
    std.debug.assert(a0 < a1);
    std.debug.assert(b0 < b1);
    return a0 < b1 and b0 < a1;
}

fn display_candidate_origin(
    anchor: *const DisplayInfo,
    target: *const DisplayInfo,
) ?geometry.Point(f32) {
    std.debug.assert(anchor.placed);
    std.debug.assert(!anchor.invalid);
    std.debug.assert(!target.invalid);
    const a = anchor.rect;
    const b = target.rect;
    if (a.right == b.left and ranges_overlap(a.top, a.bottom, b.top, b.bottom)) {
        return .{
            .x = anchor.bounds.right(),
            .y = anchor.bounds.origin.y +
                @as(f32, @floatFromInt(b.top - a.top)) / anchor.scale.y,
        };
    } else if (b.right == a.left and ranges_overlap(a.top, a.bottom, b.top, b.bottom)) {
        return .{
            .x = anchor.bounds.origin.x - target.bounds.size.width,
            .y = anchor.bounds.origin.y +
                @as(f32, @floatFromInt(b.top - a.top)) / anchor.scale.y,
        };
    } else if (a.bottom == b.top and ranges_overlap(a.left, a.right, b.left, b.right)) {
        return .{
            .x = anchor.bounds.origin.x +
                @as(f32, @floatFromInt(b.left - a.left)) / anchor.scale.x,
            .y = anchor.bounds.bottom(),
        };
    } else if (b.bottom == a.top and ranges_overlap(a.left, a.right, b.left, b.right)) {
        return .{
            .x = anchor.bounds.origin.x +
                @as(f32, @floatFromInt(b.left - a.left)) / anchor.scale.x,
            .y = anchor.bounds.origin.y - target.bounds.size.height,
        };
    }
    return null;
}

fn display_origin_matches(a: geometry.Point(f32), b: geometry.Point(f32)) bool {
    return @abs(a.x - b.x) <= DISPLAY_POINT_EPSILON and
        @abs(a.y - b.y) <= DISPLAY_POINT_EPSILON;
}

fn display_try_place(anchor: *const DisplayInfo, target: *DisplayInfo) bool {
    std.debug.assert(anchor.placed);
    std.debug.assert(!target.placed);
    std.debug.assert(!target.invalid);
    const origin = display_candidate_origin(anchor, target) orelse return false;
    target.bounds.origin = origin;
    target.placed = true;
    return true;
}

fn display_anchor_index(list: *const DisplayList) ?u32 {
    std.debug.assert(list.count <= DISPLAYS_MAX);
    var i: u32 = 0;
    while (i < list.count) : (i += 1) {
        if (!list.items[i].invalid and list.items[i].primary) return i;
    }
    i = 0;
    while (i < list.count) : (i += 1) {
        if (!list.items[i].invalid) return i;
    }
    return null;
}

fn display_place_all(list: *DisplayList) void {
    std.debug.assert(list.count <= DISPLAYS_MAX);
    if (list.count == 0) return;
    // Mixed-DPI edge conflicts retry under the fixed display cap.
    var invalidations: u32 = 0;
    while (invalidations < DISPLAYS_MAX) : (invalidations += 1) {
        display_reset_placements(list);
        if (!display_seed_anchor(list)) return;
        display_grow_placements(list);
        if (display_conflict_index(list)) |index| {
            list.items[index].invalid = true;
        } else {
            return;
        }
    }
    std.debug.assert(false);
}

fn display_reset_placements(list: *DisplayList) void {
    std.debug.assert(list.count <= DISPLAYS_MAX);
    var i: u32 = 0;
    while (i < list.count) : (i += 1) {
        list.items[i].placed = false;
    }
}

fn display_seed_anchor(list: *DisplayList) bool {
    const anchor = display_anchor_index(list) orelse return false;
    std.debug.assert(!list.items[anchor].invalid);
    list.items[anchor].bounds.origin = .{
        .x = @as(f32, @floatFromInt(list.items[anchor].rect.left)) / list.items[anchor].scale.x,
        .y = @as(f32, @floatFromInt(list.items[anchor].rect.top)) / list.items[anchor].scale.y,
    };
    list.items[anchor].placed = true;
    return true;
}

fn display_grow_placements(list: *DisplayList) void {
    std.debug.assert(list.count <= DISPLAYS_MAX);
    var pass: u32 = 0;
    while (pass < DISPLAYS_MAX) : (pass += 1) {
        if (!display_place_pass(list)) return;
    }
    std.debug.assert(false);
}

fn display_place_pass(list: *DisplayList) bool {
    std.debug.assert(list.count <= DISPLAYS_MAX);
    var changed = false;
    var i: u32 = 0;
    while (i < list.count) : (i += 1) {
        if (!list.items[i].placed or list.items[i].invalid) continue;
        var j: u32 = 0;
        while (j < list.count) : (j += 1) {
            if (list.items[j].placed) continue;
            if (list.items[j].invalid) continue;
            if (display_try_place(&list.items[i], &list.items[j])) changed = true;
        }
    }
    return changed;
}

fn display_conflict_index(list: *const DisplayList) ?u32 {
    std.debug.assert(list.count <= DISPLAYS_MAX);
    var i: u32 = 0;
    while (i < list.count) : (i += 1) {
        if (!list.items[i].placed or list.items[i].invalid) continue;
        var j: u32 = 0;
        while (j < list.count) : (j += 1) {
            if (i == j) continue;
            if (!list.items[j].placed or list.items[j].invalid) continue;
            const origin = display_candidate_origin(&list.items[i], &list.items[j]) orelse continue;
            if (display_origin_matches(list.items[j].bounds.origin, origin)) continue;
            if (!list.items[j].primary) return j;
            if (!list.items[i].primary) return i;
            std.debug.assert(false);
        }
    }
    return null;
}

fn display_compact(list: *DisplayList) void {
    std.debug.assert(list.count <= DISPLAYS_MAX);
    var write: u32 = 0;
    var read: u32 = 0;
    while (read < list.count) : (read += 1) {
        if (!list.items[read].placed) continue;
        if (list.items[read].invalid) continue;
        if (write != read) list.items[write] = list.items[read];
        write += 1;
    }
    list.count = write;
}

fn display_list_callback(
    monitor: win32.HMONITOR,
    hdc: ?win32.HDC,
    rect: *win32.RECT,
    data: win32.LPARAM,
) callconv(.winapi) win32.BOOL {
    _ = hdc;
    _ = rect;
    const list = pointer_from_lparam(DisplayList, data);
    if (list.count >= DISPLAYS_MAX) {
        std.debug.assert(false);
        return win32.FALSE;
    }
    const info = display_info(monitor) orelse return win32.TRUE;
    list.items[list.count] = info;
    list.count += 1;
    return win32.TRUE;
}

fn display_list() DisplayList {
    var list: DisplayList = .{};
    _ = win32.EnumDisplayMonitors(
        null,
        null,
        display_list_callback,
        lparam_from_pointer(&list),
    );
    std.debug.assert(list.count <= DISPLAYS_MAX);
    display_place_all(&list);
    display_compact(&list);
    std.debug.assert(list.count <= DISPLAYS_MAX);
    return list;
}

fn display_snapshot() *const DisplayList {
    if (!g_display_cache_valid) {
        g_display_cache = display_list();
        g_display_cache_valid = true;
    }
    std.debug.assert(g_display_cache.count <= DISPLAYS_MAX);
    return &g_display_cache;
}

fn display_cache_reset() void {
    g_display_cache_valid = false;
}

pub fn display_count() u32 {
    return display_snapshot().count;
}

pub fn display_bounds(index: u32) geometry.BoundsF {
    if (index >= DISPLAYS_MAX) return .{};
    const list = display_snapshot();
    if (index >= list.count) return .{};
    return list.items[index].bounds;
}
