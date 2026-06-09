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

// Single-window globals (the macOS backend makes the same assumption). The
// WndProc reaches the registered dispatch + chrome metrics through these.
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

fn paint_now() void {
    if (g_paint_now) |pn| if (g_ctx) |c| pn(c);
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

// Raw input capture (grab mode) is macOS-only; these satisfy the shared interface
// and capture nothing on Windows.
pub const RawDispatch = struct {
    on_event: *const fn (ctx: *anyopaque, ev: input.InputEvent) void,
    ctx: *anyopaque,
};

pub fn register_raw_dispatch(d: RawDispatch) void {
    _ = d;
}

pub fn set_grab(on: bool) void {
    _ = on;
}

pub fn is_grabbed() bool {
    return false;
}

pub fn release_grab_if_blurred() void {}

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

fn request_redraw() void {
    if (g_redraw) |r| {
        if (g_ctx) |c| r(c);
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

pub fn open(opts: types.NativeShellOptions) Error!CustomShellHandle {
    const instance = win32.GetModuleHandleW(null) orelse return error.WindowCreateFailed;

    if (!g_class_registered) {
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

    g_titlebar_height = @floatCast(opts.titlebar.height);
    g_min_w_pt = @floatCast(opts.min_width);
    g_min_h_pt = @floatCast(opts.min_height);

    var title_buf: [256]u16 = undefined;
    const tlen = std.unicode.utf8ToUtf16Le(&title_buf, opts.title) catch 0;
    title_buf[@min(tlen, title_buf.len - 1)] = 0;
    const title: [*:0]const u16 = @ptrCast(&title_buf);

    // WS_OVERLAPPEDWINDOW keeps the native min/maximize/snap behavior and the DWM
    // drop shadow; WM_NCCALCSIZE then removes the visible frame so the painted
    // band becomes the whole title bar.
    const hwnd = win32.CreateWindowExW(
        win32.WS_EX_APPWINDOW,
        CLASS_NAME,
        title,
        win32.WS_OVERLAPPEDWINDOW | win32.WS_CLIPCHILDREN,
        win32.CW_USEDEFAULT,
        win32.CW_USEDEFAULT,
        @intFromFloat(opts.width),
        @intFromFloat(opts.height),
        null,
        null,
        instance,
        null,
    ) orelse return error.WindowCreateFailed;

    // Stripping the frame in WM_NCCALCSIZE drops Win11's auto-rounding, so ask
    // DWM for it back; tint the 1px border so the window edge reads against a
    // backdrop of the same color.
    var corner: u32 = win32.DWMWCP_ROUND;
    const corner_attr = win32.DWMWA_WINDOW_CORNER_PREFERENCE;
    _ = win32.DwmSetWindowAttribute(hwnd, corner_attr, &corner, @sizeOf(u32));
    var border: win32.COLORREF = 0x00555555;
    const border_sz: win32.DWORD = @sizeOf(win32.COLORREF);
    _ = win32.DwmSetWindowAttribute(hwnd, win32.DWMWA_BORDER_COLOR, &border, border_sz);

    // CreateWindowExW sizes in raw pixels, but opts.width/height are logical
    // (DIP); scale to the window's monitor DPI so a high-DPI display opens at the
    // requested logical size instead of clamping up to the DPI-scaled minimum (a
    // 200% panel forced the window to its 560x480-logical floor). This reposition
    // also re-runs WM_NCCALCSIZE so the borderless client takes effect.
    const scale = scale_for(hwnd);
    const w_px: i32 = @intFromFloat(opts.width * @as(f64, scale));
    const h_px: i32 = @intFromFloat(opts.height * @as(f64, scale));
    std.debug.assert(w_px > 0);
    std.debug.assert(h_px > 0);
    const repos_flags = win32.SWP_NOMOVE | win32.SWP_NOZORDER | win32.SWP_FRAMECHANGED;
    _ = win32.SetWindowPos(hwnd, null, 0, 0, w_px, h_px, repos_flags);
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

fn clear_caption_hover() void {
    if (g_hover_caption != .none) {
        g_hover_caption = .none;
        request_redraw();
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
        .close => _ = win32.DestroyWindow(hwnd),
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
            if (g_ctx) |c| {
                const x_pt = @as(f32, @floatFromInt(px)) / scale;
                const y_pt = @as(f32, @floatFromInt(py)) / scale;
                if (ht(c, x_pt, y_pt, g_titlebar_height)) return win32.HTCLIENT;
            }
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
        win32.WM_NCCALCSIZE => {
            if (w != 0) {
                // Client = whole window. Maximized, inset by the frame padding so
                // content fits the work area and does not cover the taskbar.
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
        },
        win32.WM_GETMINMAXINFO => {
            // Enforce the app's min window size so it can never shrink below what
            // the titlebar layout needs (a degenerate band asserts in the kit).
            const mmi: *win32.MINMAXINFO = @ptrFromInt(@as(usize, @bitCast(l)));
            const scale = scale_for(hwnd);
            mmi.ptMinTrackSize.x = @intFromFloat(g_min_w_pt * scale);
            mmi.ptMinTrackSize.y = @intFromFloat(g_min_h_pt * scale);
            return 0;
        },
        win32.WM_NCHITTEST => return hit_test(hwnd, l),
        win32.WM_NCMOUSEMOVE => {
            track_nc_leave(hwnd);
            const hovered = caption_from_ht(w);
            if (hovered != g_hover_caption) {
                g_hover_caption = hovered;
                request_redraw();
            }
        },
        win32.WM_NCMOUSELEAVE => {
            g_tracking_nc = false;
            clear_caption_hover();
        },
        win32.WM_NCLBUTTONDOWN => {
            const cb = caption_from_ht(w);
            if (cb != .none) {
                g_pressed_caption = cb;
                return 0; // act on release for a reliable custom-chrome button
            }
            // HTCAPTION / resize borders fall through to DefWindowProc.
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
        win32.WM_ERASEBKGND => return 1,
        win32.WM_ENTERSIZEMOVE => {
            // Silence the vsync thread for the modal loop's lifetime: it would
            // otherwise flood WM_VSYNC and starve the mouse-move input the resize
            // depends on. Paint runs synchronously from WM_SIZE below.
            loop.resizing.store(true, .seq_cst);
        },
        win32.WM_SIZE => {
            // The modal resize loop starves the vsync thread, so repaint
            // synchronously on every size step. Painting each step (no rate cap)
            // keeps the content locked to the window frame - a cap let the frame
            // outrun the content, which reads as lag. A same-size step is cheap:
            // the renderer skips ResizeBuffers and an unchanged frame. Falls
            // through to DefWindowProc; WM_EXITSIZEMOVE guarantees the final frame.
            paint_now();
        },
        win32.WM_EXITSIZEMOVE => {
            loop.resizing.store(false, .seq_cst);
            paint_now();
        },
        win32.WM_CTLCOLOREDIT => {
            // Theme the EDIT overlay to match the kit-drawn field (wParam = HDC).
            const hdc: win32.HDC = @ptrFromInt(w);
            _ = win32.SetTextColor(hdc, g_field_text);
            _ = win32.SetBkColor(hdc, g_field_bg);
            if (g_field_brush) |br| return @bitCast(@intFromPtr(br));
        },
        win32.WM_SETCURSOR => {
            // Reassert our cursor over the client area; let the frame use its own
            // resize cursors. The hit-test code is the low word of lParam.
            if (win32.get_x_lparam(l) == win32.HTCLIENT) {
                set_cursor(g_cursor);
                return 1;
            }
        },
        win32.WM_DESTROY => {
            // Stop the vsync flood first so WM_QUIT is not starved and no paint
            // runs against the dying window, then quit the loop.
            loop.quitting = true;
            loop.vsync_running.store(false, .seq_cst);
            win32.PostQuitMessage(0);
            return 0;
        },
        win32.WM_MOUSEMOVE => {
            clear_caption_hover();
            if (g_dispatch) |d| {
                track_mouse_leave(hwnd);
                const p = dispatch_point(hwnd, l);
                d.on_move(d.ctx, p[0], p[1]);
            }
            return 0;
        },
        win32.WM_MOUSELEAVE => {
            g_tracking_mouse = false;
            if (g_dispatch) |d| d.on_exit(d.ctx);
            return 0;
        },
        win32.WM_LBUTTONDOWN => {
            if (g_dispatch) |d| {
                const p = dispatch_point(hwnd, l);
                d.on_down(d.ctx, p[0], p[1]);
            }
            return 0;
        },
        win32.WM_LBUTTONUP => {
            if (g_dispatch) |d| d.on_up(d.ctx);
            return 0;
        },
        win32.WM_RBUTTONDOWN => {
            if (g_dispatch) |d| {
                const p = dispatch_point(hwnd, l);
                d.on_right_down(d.ctx, p[0], p[1]);
            }
            return 0;
        },
        win32.WM_MOUSEWHEEL => {
            if (g_dispatch) |d| {
                const raw_delta = win32.get_wheel_delta_wparam(w);
                const notches = @as(f32, @floatFromInt(raw_delta)) / win32.WHEEL_DELTA;
                d.on_scroll(d.ctx, 0, notches * 40.0);
            }
            return 0;
        },
        win32.WM_KEYDOWN, win32.WM_SYSKEYDOWN => {
            if (g_dispatch) |d| {
                if (key_code_for_vk(w)) |code| {
                    d.on_key(d.ctx, .{ .code = code, .ch = 0, .mods = key_mods() });
                    return 0;
                }
            }
        },
        win32.WM_CHAR => {
            if (g_dispatch) |d| {
                const mods = key_mods();
                const raw: u21 = @intCast(w & 0x10FFFF);
                // Ctrl+letter arrives as a control char (Ctrl+A == 0x01); the
                // kit's cmd-shortcuts switch on the letter, so fold it back.
                const ch: u21 = if (mods.cmd and raw >= 0x01 and raw <= 0x1A) raw + 0x60 else raw;
                const printable = ch >= 0x20 and ch != 0x7F;
                const cmd_letter = mods.cmd and ch >= 'a' and ch <= 'z';
                if (printable or cmd_letter) {
                    d.on_key(d.ctx, .{ .code = .char, .ch = ch, .mods = mods });
                }
            }
            return 0;
        },
        else => {},
    }
    return win32.DefWindowProcW(hwnd, msg, w, l);
}

// A persistent native EDIT child overlays the kit-drawn field while focused; the
// consumer polls text_field_value each frame into its own buffer. numeric is not
// enforced yet (the kit validates).
fn ensure_edit(parent: win32.HWND) ?win32.HWND {
    if (g_edit) |e| return e;
    g_main_hwnd = parent;
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
) void {
    std.debug.assert(id != 0);
    _ = numeric;
    const edit = ensure_edit(handle.window) orelse return;
    const scale = scale_for(handle.window);

    _ = win32.SetWindowPos(
        edit,
        null,
        @intFromFloat(x * scale),
        @intFromFloat(y * scale),
        @intFromFloat(w * scale),
        @intFromFloat(h * scale),
        win32.SWP_NOZORDER | win32.SWP_SHOWWINDOW,
    );

    const font_px: i32 = @intFromFloat(font_size * scale);
    if (font_px != g_edit_font_px) {
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

    g_field_text = win32.rgb_to_colorref(color.r, color.g, color.b);
    const bg = handle.theme.background;
    const bg_cr = win32.rgb_to_colorref(bg.r, bg.g, bg.b);
    if (bg_cr != g_field_bg or g_field_brush == null) {
        if (g_field_brush) |br| _ = win32.DeleteObject(@ptrCast(br));
        g_field_brush = win32.CreateSolidBrush(bg_cr);
        g_field_bg = bg_cr;
    }

    // Re-seed text + focus only when the active field changes, so live typing is
    // not clobbered every frame.
    if (!g_field_visible or g_active_secure != secure or g_active_id != id) {
        _ = win32.SendMessageW(edit, win32.EM_SETPASSWORDCHAR, if (secure) 0x2022 else 0, 0);
        var wbuf: [512]u16 = undefined;
        const wlen = std.unicode.utf8ToUtf16Le(&wbuf, initial) catch 0;
        wbuf[@min(wlen, wbuf.len - 1)] = 0;
        _ = win32.SetWindowTextW(edit, @ptrCast(&wbuf));
        // caret past the seeded text so the user appends, not overwrites
        const sel_end: win32.WPARAM = @bitCast(@as(isize, std.math.maxInt(i32)));
        const sel_lp: win32.LPARAM = @bitCast(@as(isize, std.math.maxInt(i32)));
        _ = win32.SendMessageW(edit, win32.EM_SETSEL, sel_end, sel_lp);
        _ = win32.SetFocus(edit);
        g_field_visible = true;
        g_active_secure = secure;
        g_active_id = id;
    }
}

pub fn hide_text_field() void {
    if (!g_field_visible) return;
    if (g_edit) |e| _ = win32.ShowWindow(e, win32.SW_HIDE);
    if (g_main_hwnd) |m| _ = win32.SetFocus(m);
    g_field_visible = false;
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
    defer _ = win32.CloseClipboard();
    _ = win32.EmptyClipboard();
    if (win32.SetClipboardData(win32.CF_UNICODETEXT, mem) != null) {
        owned_by_clipboard = true;
    }
}

// The Windows backend reports no clipboard change; macOS carries the poll.
pub fn clipboard_changed_external() bool {
    return false;
}

// Display enumeration is macOS-only here; the Windows backend reports none.
pub fn display_count() u32 {
    return 0;
}

pub fn display_bounds(index: u32) geometry.BoundsF {
    _ = index;
    return .{};
}
