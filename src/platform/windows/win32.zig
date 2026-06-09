// The one place raw Win32 lives (the objc.zig analogue). Self-contained with no
// std.os.windows dependency, so the backend is insulated from std churn.

const std = @import("std");

pub const HRESULT = i32;
pub const LRESULT = isize;
pub const LPARAM = isize;
pub const WPARAM = usize;
pub const BOOL = i32;
pub const DWORD = u32;
pub const UINT = u32;
pub const WORD = u16;
pub const ATOM = u16;
pub const LONG = i32;
pub const WCHAR = u16;
pub const LPCWSTR = [*:0]const u16;
pub const LPWSTR = [*:0]u16;

pub const HWND = *opaque {};
pub const HINSTANCE = *opaque {};
pub const HMODULE = *opaque {};
pub const HICON = *opaque {};
pub const HCURSOR = *opaque {};
pub const HBRUSH = *opaque {};
pub const HMENU = *opaque {};
pub const HDC = *opaque {};
pub const HFONT = *opaque {};
pub const HGDIOBJ = *opaque {};
pub const HGLOBAL = *anyopaque;
pub const COLORREF = u32;

pub const TRUE: BOOL = 1;
pub const FALSE: BOOL = 0;

pub const GUID = extern struct {
    Data1: u32,
    Data2: u16,
    Data3: u16,
    Data4: [8]u8,
};

pub const POINT = extern struct { x: LONG, y: LONG };
pub const RECT = extern struct { left: LONG, top: LONG, right: LONG, bottom: LONG };

pub const SIZE = extern struct { cx: LONG, cy: LONG };

pub const MSG = extern struct {
    hwnd: ?HWND,
    message: UINT,
    wParam: WPARAM,
    lParam: LPARAM,
    time: DWORD,
    pt: POINT,
};

pub const WNDPROC = *const fn (HWND, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT;

pub const WNDCLASSEXW = extern struct {
    cbSize: UINT,
    style: UINT,
    lpfnWndProc: WNDPROC,
    cbClsExtra: i32,
    cbWndExtra: i32,
    hInstance: HINSTANCE,
    hIcon: ?HICON,
    hCursor: ?HCURSOR,
    hbrBackground: ?HBRUSH,
    lpszMenuName: ?LPCWSTR,
    lpszClassName: LPCWSTR,
    hIconSm: ?HICON,
};

// WM_NCCALCSIZE rect set, plus the matching NCCALCSIZE_PARAMS.
pub const NCCALCSIZE_PARAMS = extern struct {
    rgrc: [3]RECT,
    lppos: ?*WINDOWPOS,
};

pub const WINDOWPOS = extern struct {
    hwnd: ?HWND,
    hwndInsertAfter: ?HWND,
    x: i32,
    y: i32,
    cx: i32,
    cy: i32,
    flags: UINT,
};

pub const MINMAXINFO = extern struct {
    ptReserved: POINT,
    ptMaxSize: POINT,
    ptMaxPosition: POINT,
    ptMinTrackSize: POINT,
    ptMaxTrackSize: POINT,
};

pub const TRACKMOUSEEVENT = extern struct {
    cbSize: DWORD,
    dwFlags: DWORD,
    hwndTrack: ?HWND,
    dwHoverTime: DWORD,
};

// Window class style.
pub const CS_HREDRAW: UINT = 0x0002;
pub const CS_VREDRAW: UINT = 0x0001;
pub const CS_OWNDC: UINT = 0x0020;

// Window styles.
pub const WS_OVERLAPPED: DWORD = 0x00000000;
pub const WS_CAPTION: DWORD = 0x00C00000;
pub const WS_SYSMENU: DWORD = 0x00080000;
pub const WS_THICKFRAME: DWORD = 0x00040000;
pub const WS_MINIMIZEBOX: DWORD = 0x00020000;
pub const WS_MAXIMIZEBOX: DWORD = 0x00010000;
pub const WS_POPUP: DWORD = 0x80000000;
pub const WS_VISIBLE: DWORD = 0x10000000;
pub const WS_CLIPCHILDREN: DWORD = 0x02000000;
pub const WS_OVERLAPPEDWINDOW: DWORD =
    WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_THICKFRAME | WS_MINIMIZEBOX | WS_MAXIMIZEBOX;
pub const WS_EX_APPWINDOW: DWORD = 0x00040000;
pub const WS_EX_NOREDIRECTIONBITMAP: DWORD = 0x00200000;

// Child EDIT control (the text-field overlay) styles.
pub const WS_CHILD: DWORD = 0x40000000;
pub const ES_LEFT: DWORD = 0x0000;
pub const ES_AUTOHSCROLL: DWORD = 0x0080;
pub const ES_PASSWORD: DWORD = 0x0020;
pub const ES_NUMBER: DWORD = 0x2000;

// EDIT/control messages + clipboard formats.
pub const WM_SETFONT: UINT = 0x0030;
pub const WM_CTLCOLOREDIT: UINT = 0x0133;
pub const EM_SETSEL: UINT = 0x00B1;
pub const EM_SETPASSWORDCHAR: UINT = 0x00CC;
pub const CF_UNICODETEXT: UINT = 13;
pub const GMEM_MOVEABLE: UINT = 0x0002;

// ShowWindow commands.
pub const SW_HIDE: i32 = 0;
pub const SW_SHOWNORMAL: i32 = 1;
pub const SW_MAXIMIZE: i32 = 3;
pub const SW_SHOW: i32 = 5;
pub const SW_MINIMIZE: i32 = 6;
pub const SW_RESTORE: i32 = 9;

// SetWindowPos flags.
pub const SWP_NOSIZE: UINT = 0x0001;
pub const SWP_NOMOVE: UINT = 0x0002;
pub const SWP_NOZORDER: UINT = 0x0004;
pub const SWP_FRAMECHANGED: UINT = 0x0020;
pub const SWP_SHOWWINDOW: UINT = 0x0040;

pub const CW_USEDEFAULT: i32 = @bitCast(@as(u32, 0x80000000));

// SetWindowLongPtr indices.
pub const GWLP_USERDATA: i32 = -21;
pub const GWLP_WNDPROC: i32 = -4;
pub const GWL_STYLE: i32 = -16;

// MonitorFromWindow: pick the monitor the window is mostly on.
pub const MONITOR_DEFAULTTONEAREST: DWORD = 0x00000002;
pub const MONITORINFO = extern struct {
    cbSize: DWORD,
    rcMonitor: RECT,
    rcWork: RECT,
    dwFlags: DWORD,
};

// Window messages.
pub const WM_DESTROY: UINT = 0x0002;
pub const WM_SIZE: UINT = 0x0005;
pub const WM_ENTERSIZEMOVE: UINT = 0x0231;
pub const WM_EXITSIZEMOVE: UINT = 0x0232;
pub const WM_CLOSE: UINT = 0x0010;
pub const WM_QUIT: UINT = 0x0012;
pub const WM_ERASEBKGND: UINT = 0x0014;
pub const WM_ACTIVATE: UINT = 0x0006;
pub const WM_SETCURSOR: UINT = 0x0020;
pub const WM_GETMINMAXINFO: UINT = 0x0024;
pub const WM_NCCALCSIZE: UINT = 0x0083;
pub const WM_NCHITTEST: UINT = 0x0084;
pub const WM_MOUSEMOVE: UINT = 0x0200;
pub const WM_LBUTTONDOWN: UINT = 0x0201;
pub const WM_LBUTTONUP: UINT = 0x0202;
pub const WM_RBUTTONDOWN: UINT = 0x0204;
pub const WM_RBUTTONUP: UINT = 0x0205;
pub const WM_MOUSEWHEEL: UINT = 0x020A;
pub const WM_MOUSEHWHEEL: UINT = 0x020E;
pub const WM_MOUSELEAVE: UINT = 0x02A3;
pub const WM_NCMOUSEMOVE: UINT = 0x00A0;
pub const WM_NCLBUTTONDOWN: UINT = 0x00A1;
pub const WM_NCLBUTTONUP: UINT = 0x00A2;
pub const WM_NCMOUSELEAVE: UINT = 0x02A2;
pub const WM_KEYDOWN: UINT = 0x0100;
pub const WM_KEYUP: UINT = 0x0101;
pub const WM_CHAR: UINT = 0x0102;
pub const WM_SYSKEYDOWN: UINT = 0x0104;
pub const WM_DPICHANGED: UINT = 0x02E0;
// First message id free for application use; the vsync tick rides on it.
pub const WM_APP: UINT = 0x8000;

// Input-message ranges + PeekMessage flag, for draining queued input ahead of
// the vsync paint (a posted WM_VSYNC outranks input in GetMessage).
pub const WM_KEYFIRST: UINT = 0x0100;
pub const WM_KEYLAST: UINT = 0x0108;
pub const WM_NCMOUSEFIRST: UINT = 0x00A0;
pub const WM_NCMOUSELAST: UINT = 0x00A9;
pub const WM_MOUSEFIRST: UINT = 0x0200;
pub const WM_MOUSELAST: UINT = 0x020E;
pub const PM_REMOVE: UINT = 0x0001;

// WM_ACTIVATE wParam.
pub const WA_INACTIVE: WPARAM = 0;

// WM_NCHITTEST results.
pub const HTNOWHERE: LRESULT = 0;
pub const HTCLIENT: LRESULT = 1;
pub const HTCAPTION: LRESULT = 2;
pub const HTMINBUTTON: LRESULT = 8;
pub const HTMAXBUTTON: LRESULT = 9;
pub const HTCLOSE: LRESULT = 20;
pub const HTLEFT: LRESULT = 10;
pub const HTRIGHT: LRESULT = 11;
pub const HTTOP: LRESULT = 12;
pub const HTTOPLEFT: LRESULT = 13;
pub const HTTOPRIGHT: LRESULT = 14;
pub const HTBOTTOM: LRESULT = 15;
pub const HTBOTTOMLEFT: LRESULT = 16;
pub const HTBOTTOMRIGHT: LRESULT = 17;

// TrackMouseEvent flags.
pub const TME_LEAVE: DWORD = 0x00000002;
pub const TME_NONCLIENT: DWORD = 0x00000010;

// GetSystemMetrics indices for the maximize-inset frame padding.
pub const SM_CXFRAME: i32 = 32;
pub const SM_CYFRAME: i32 = 33;
pub const SM_CXPADDEDBORDER: i32 = 92;

// System cursors (LoadCursorW lpCursorName via MAKEINTRESOURCE).
pub const IDC_ARROW: u16 = 32512;
pub const IDC_SIZEWE: u16 = 32644;
pub const IDC_SIZENS: u16 = 32645;

// Virtual key codes used by the key decoder.
pub const VK_BACK: WPARAM = 0x08;
pub const VK_TAB: WPARAM = 0x09;
pub const VK_RETURN: WPARAM = 0x0D;
pub const VK_SHIFT: WPARAM = 0x10;
pub const VK_CONTROL: WPARAM = 0x11;
pub const VK_MENU: WPARAM = 0x12;
pub const VK_ESCAPE: WPARAM = 0x1B;
pub const VK_PRIOR: WPARAM = 0x21;
pub const VK_NEXT: WPARAM = 0x22;
pub const VK_END: WPARAM = 0x23;
pub const VK_HOME: WPARAM = 0x24;
pub const VK_LEFT: WPARAM = 0x25;
pub const VK_UP: WPARAM = 0x26;
pub const VK_RIGHT: WPARAM = 0x27;
pub const VK_DOWN: WPARAM = 0x28;
pub const VK_DELETE: WPARAM = 0x2E;
pub const VK_LWIN: WPARAM = 0x5B;
pub const VK_RWIN: WPARAM = 0x5C;

// GetKeyState high bit = key down.
pub const KEY_DOWN_MASK: u16 = 0x8000;

pub const WHEEL_DELTA: f32 = 120.0;

// Per-Monitor-Aware v2: (DPI_AWARENESS_CONTEXT)-4.
pub const DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2: ?*anyopaque =
    @ptrFromInt(@as(usize, @bitCast(@as(isize, -4))));

pub const USER_DEFAULT_SCREEN_DPI: f32 = 96.0;

pub extern "kernel32" fn GetModuleHandleW(lpModuleName: ?LPCWSTR) callconv(.winapi) ?HINSTANCE;
pub extern "kernel32" fn GetCurrentThreadId() callconv(.winapi) DWORD;
pub extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;
pub extern "kernel32" fn Sleep(ms: DWORD) callconv(.winapi) void;
pub extern "kernel32" fn LoadLibraryA(name: [*:0]const u8) callconv(.winapi) ?HMODULE;
pub extern "kernel32" fn GetProcAddress(
    module: HMODULE,
    name: [*:0]const u8,
) callconv(.winapi) ?*anyopaque;

pub extern "user32" fn RegisterClassExW(cls: *const WNDCLASSEXW) callconv(.winapi) ATOM;
pub extern "user32" fn CreateWindowExW(
    ex_style: DWORD,
    class_name: LPCWSTR,
    window_name: LPCWSTR,
    style: DWORD,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    parent: ?HWND,
    menu: ?HMENU,
    instance: ?HINSTANCE,
    param: ?*anyopaque,
) callconv(.winapi) ?HWND;
pub extern "user32" fn DefWindowProcW(
    hwnd: HWND,
    msg: UINT,
    w: WPARAM,
    l: LPARAM,
) callconv(.winapi) LRESULT;
pub extern "user32" fn DestroyWindow(hwnd: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn ShowWindow(hwnd: HWND, cmd: i32) callconv(.winapi) BOOL;
pub extern "user32" fn SetWindowPos(
    hwnd: HWND,
    after: ?HWND,
    x: i32,
    y: i32,
    cx: i32,
    cy: i32,
    flags: UINT,
) callconv(.winapi) BOOL;
pub extern "user32" fn UpdateWindow(hwnd: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn GetMessageW(
    msg: *MSG,
    hwnd: ?HWND,
    min: UINT,
    max: UINT,
) callconv(.winapi) BOOL;
pub extern "user32" fn TranslateMessage(msg: *const MSG) callconv(.winapi) BOOL;
pub extern "user32" fn DispatchMessageW(msg: *const MSG) callconv(.winapi) LRESULT;
pub extern "user32" fn PostQuitMessage(code: i32) callconv(.winapi) void;
pub extern "user32" fn PostThreadMessageW(
    thread: DWORD,
    msg: UINT,
    w: WPARAM,
    l: LPARAM,
) callconv(.winapi) BOOL;
pub extern "user32" fn GetClientRect(hwnd: HWND, rect: *RECT) callconv(.winapi) BOOL;
pub extern "user32" fn GetWindowRect(hwnd: HWND, rect: *RECT) callconv(.winapi) BOOL;
pub extern "user32" fn MonitorFromWindow(hwnd: HWND, flags: DWORD) callconv(.winapi) ?*anyopaque;
pub extern "user32" fn GetMonitorInfoW(
    monitor: ?*anyopaque,
    info: *MONITORINFO,
) callconv(.winapi) BOOL;
pub extern "user32" fn SetWindowLongPtrW(
    hwnd: HWND,
    index: i32,
    value: isize,
) callconv(.winapi) isize;
pub extern "user32" fn GetWindowLongPtrW(hwnd: HWND, index: i32) callconv(.winapi) isize;
pub extern "user32" fn LoadCursorW(instance: ?HINSTANCE, name: LPCWSTR) callconv(.winapi) ?HCURSOR;
pub extern "user32" fn SetCursor(cursor: ?HCURSOR) callconv(.winapi) ?HCURSOR;
pub extern "user32" fn SetForegroundWindow(hwnd: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn SetFocus(hwnd: ?HWND) callconv(.winapi) ?HWND;
pub extern "user32" fn GetDpiForWindow(hwnd: HWND) callconv(.winapi) UINT;
pub extern "user32" fn SetProcessDpiAwarenessContext(value: ?*anyopaque) callconv(.winapi) BOOL;
pub extern "user32" fn ScreenToClient(hwnd: HWND, pt: *POINT) callconv(.winapi) BOOL;
pub extern "user32" fn GetCursorPos(pt: *POINT) callconv(.winapi) BOOL;
pub extern "user32" fn TrackMouseEvent(ev: *TRACKMOUSEEVENT) callconv(.winapi) BOOL;
pub extern "user32" fn GetKeyState(vk: i32) callconv(.winapi) i16;
pub extern "user32" fn GetSystemMetrics(index: i32) callconv(.winapi) i32;
pub extern "user32" fn IsZoomed(hwnd: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn IsIconic(hwnd: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn PeekMessageW(
    msg: *MSG,
    hwnd: ?HWND,
    min: UINT,
    max: UINT,
    remove: UINT,
) callconv(.winapi) BOOL;

pub extern "user32" fn SetWindowTextW(hwnd: HWND, text: LPCWSTR) callconv(.winapi) BOOL;
pub extern "user32" fn GetWindowTextW(hwnd: HWND, buf: LPWSTR, max: i32) callconv(.winapi) i32;
pub extern "user32" fn SendMessageW(
    hwnd: HWND,
    msg: UINT,
    w: WPARAM,
    l: LPARAM,
) callconv(.winapi) LRESULT;
pub extern "user32" fn OpenClipboard(owner: ?HWND) callconv(.winapi) BOOL;
pub extern "user32" fn CloseClipboard() callconv(.winapi) BOOL;
pub extern "user32" fn EmptyClipboard() callconv(.winapi) BOOL;
pub extern "user32" fn GetClipboardData(format: UINT) callconv(.winapi) ?HGLOBAL;
pub extern "user32" fn SetClipboardData(format: UINT, mem: HGLOBAL) callconv(.winapi) ?HGLOBAL;

pub extern "kernel32" fn GlobalAlloc(flags: UINT, bytes: usize) callconv(.winapi) ?HGLOBAL;
pub extern "kernel32" fn GlobalLock(mem: HGLOBAL) callconv(.winapi) ?*anyopaque;
pub extern "kernel32" fn GlobalUnlock(mem: HGLOBAL) callconv(.winapi) BOOL;
pub extern "kernel32" fn GlobalFree(mem: HGLOBAL) callconv(.winapi) ?HGLOBAL;

pub extern "gdi32" fn CreateSolidBrush(color: COLORREF) callconv(.winapi) ?HBRUSH;
pub extern "gdi32" fn SetTextColor(hdc: HDC, color: COLORREF) callconv(.winapi) COLORREF;
pub extern "gdi32" fn SetBkColor(hdc: HDC, color: COLORREF) callconv(.winapi) COLORREF;
pub extern "gdi32" fn DeleteObject(obj: HGDIOBJ) callconv(.winapi) BOOL;
pub extern "gdi32" fn CreateFontW(
    height: i32,
    width: i32,
    escapement: i32,
    orientation: i32,
    weight: i32,
    italic: DWORD,
    underline: DWORD,
    strikeout: DWORD,
    charset: DWORD,
    out_precision: DWORD,
    clip_precision: DWORD,
    quality: DWORD,
    pitch_and_family: DWORD,
    face: LPCWSTR,
) callconv(.winapi) ?HFONT;

pub extern "dwmapi" fn DwmFlush() callconv(.winapi) HRESULT;
pub extern "dwmapi" fn DwmSetWindowAttribute(
    hwnd: HWND,
    attr: DWORD,
    value: *const anyopaque,
    size: DWORD,
) callconv(.winapi) HRESULT;
// Win11 DWM attributes: round the corners + tint the 1px window border.
pub const DWMWA_WINDOW_CORNER_PREFERENCE: DWORD = 33;
pub const DWMWA_BORDER_COLOR: DWORD = 34;
pub const DWMWCP_ROUND: u32 = 2;

// COLORREF byte order is BGR (0x00BBGGRR), not RGB - the surprising part.
pub fn rgb_to_colorref(r: f32, g: f32, b: f32) COLORREF {
    const ri: u32 = @intFromFloat(@max(0.0, @min(1.0, r)) * 255.0);
    const gi: u32 = @intFromFloat(@max(0.0, @min(1.0, g)) * 255.0);
    const bi: u32 = @intFromFloat(@max(0.0, @min(1.0, b)) * 255.0);
    return ri | (gi << 8) | (bi << 16);
}

// MAKEINTRESOURCE for the predefined cursors (an integer atom in pointer slot).
pub fn make_int_resource(id: u16) LPCWSTR {
    return @ptrFromInt(@as(usize, id));
}

// Comptime UTF-8 -> UTF-16LE literal for class/window names passed to the W APIs.
pub fn L(comptime s: []const u8) LPCWSTR {
    return std.unicode.utf8ToUtf16LeStringLiteral(s);
}

pub inline fn get_x_lparam(l: LPARAM) i32 {
    return @as(i16, @bitCast(@as(u16, @truncate(@as(usize, @bitCast(l)) & 0xFFFF))));
}

pub inline fn get_y_lparam(l: LPARAM) i32 {
    return @as(i16, @bitCast(@as(u16, @truncate((@as(usize, @bitCast(l)) >> 16) & 0xFFFF))));
}

// WM_MOUSEWHEEL packs the signed wheel delta in the high word of wParam.
pub inline fn get_wheel_delta_wparam(w: WPARAM) i32 {
    return @as(i16, @bitCast(@as(u16, @truncate((w >> 16) & 0xFFFF))));
}
