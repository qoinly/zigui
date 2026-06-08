// Native (non-custom-chrome) window types; the Windows backend leads with the
// custom shell (custom_shell.zig). The full public surface exists so the window
// facade + root compile and the API matches macOS, even where a shell has no
// Windows implementation: those open_* return error.Unsupported, and unimplemented
// setters are no-ops (show/hide/focus/deinit, which only touch the HWND, do work).

const std = @import("std");
const win32 = @import("win32.zig");
const types = @import("../../window/types.zig");

pub const Error = error{
    NoWindowClass,
    WindowCreateFailed,
    Unsupported,
};

const Size2 = extern struct { width: f64 = 0, height: f64 = 0 };
const Rect2 = extern struct { x: f64 = 0, y: f64 = 0, width: f64 = 0, height: f64 = 0 };

pub const Event = struct { kind: u8 = 0, x: f32 = 0, y: f32 = 0 };

pub const BodyMouseEvent = types.BodyMouseEvent;
pub const BodyMouseFn = types.BodyMouseFn;
pub const BodyExitFn = types.BodyExitFn;

pub const SimpleOptions = struct {
    title: []const u8,
    width: f64 = 360,
    height: f64 = 200,
    label: ?[]const u8 = null,
};

pub const Handle = struct {
    raw: ?win32.HWND = null,

    pub fn focus(self: Handle) void {
        if (self.raw) |h| {
            _ = win32.SetForegroundWindow(h);
            _ = win32.SetFocus(h);
        }
    }
};

pub const MetalOptions = struct {
    title: []const u8,
    width: f64 = 800,
    height: f64 = 600,
    resizable: bool = true,
};

pub const MetalHandle = struct {
    window: ?win32.HWND = null,
    // cross-platform "render surface" handle (CAMetalLayer on macOS); the HWND
    // here, which the D3D11 renderer turns into a swapchain.
    metal_layer: ?*anyopaque = null,
    height: f32 = 0,

    pub fn focus(self: MetalHandle) void {
        if (self.window) |h| _ = win32.SetForegroundWindow(h);
    }
    pub fn get_size(self: MetalHandle) Size2 {
        _ = self;
        return .{};
    }
    pub fn deinit(self: MetalHandle) void {
        if (self.window) |h| _ = win32.DestroyWindow(h);
    }
};

pub const PanelMaterial = enum(u32) {
    menu = 5,
    popover = 6,
    sidebar = 7,
    hud = 8,
    fullscreen_ui = 15,
    under_window = 21,
};

pub const PanelOptions = struct {
    width: f64 = 360,
    height: f64 = 480,
    corner_radius: f64 = 12,
    material: PanelMaterial = .menu,
};

pub const PanelHandle = struct {
    window: ?win32.HWND = null,
    // cross-platform "render surface" handle (CAMetalLayer on macOS); the HWND
    // here, which the D3D11 renderer turns into a swapchain.
    metal_layer: ?*anyopaque = null,

    pub fn show(self: PanelHandle) void {
        if (self.window) |h| _ = win32.ShowWindow(h, win32.SW_SHOW);
    }
    pub fn hide(self: PanelHandle) void {
        if (self.window) |h| _ = win32.ShowWindow(h, win32.SW_HIDE);
    }
    pub fn is_visible(self: PanelHandle) bool {
        _ = self;
        return false;
    }
    pub fn set_origin(self: PanelHandle, x: f64, y: f64) void {
        _ = self;
        _ = x;
        _ = y;
    }
    pub fn set_size(self: PanelHandle, w: f64, h: f64) void {
        _ = self;
        _ = w;
        _ = h;
    }
    pub fn set_size_top_anchored(self: PanelHandle, w: f64, h: f64) void {
        _ = self;
        _ = w;
        _ = h;
    }
    pub fn on_resign_key(
        self: PanelHandle,
        ctx: *anyopaque,
        callback: *const fn (*anyopaque) void,
    ) void {
        _ = self;
        _ = ctx;
        _ = callback;
    }
    pub fn set_mouse_handler(
        self: PanelHandle,
        ctx: *anyopaque,
        callback: *const fn (*anyopaque, Event) void,
    ) void {
        _ = self;
        _ = ctx;
        _ = callback;
    }
    pub fn deinit(self: PanelHandle) void {
        if (self.window) |h| _ = win32.DestroyWindow(h);
    }
};

pub const NativeShellHandle = struct {
    window: ?win32.HWND = null,
    // cross-platform "render surface" handle (CAMetalLayer on macOS); the HWND
    // here, which the D3D11 renderer turns into a swapchain.
    metal_layer: ?*anyopaque = null,
    height: f32 = 0,

    pub fn focus(self: NativeShellHandle) void {
        if (self.window) |h| _ = win32.SetForegroundWindow(h);
    }
    pub fn get_content_size(self: NativeShellHandle) Size2 {
        _ = self;
        return .{};
    }
    pub fn get_safe_content_bounds(self: NativeShellHandle) Rect2 {
        _ = self;
        return .{};
    }
    pub fn sync_drawable_size(self: NativeShellHandle) Size2 {
        _ = self;
        return .{};
    }
    pub fn deinit(self: NativeShellHandle) void {
        if (self.window) |h| _ = win32.DestroyWindow(h);
    }
};

pub fn open_simple(opts: SimpleOptions) Error!Handle {
    _ = opts;
    return error.Unsupported;
}

pub fn open_metal(opts: MetalOptions) Error!MetalHandle {
    _ = opts;
    return error.Unsupported;
}

pub fn open_panel(opts: PanelOptions) Error!PanelHandle {
    _ = opts;
    return error.Unsupported;
}

pub fn open_native_shell(opts: types.NativeShellOptions) Error!NativeShellHandle {
    _ = opts;
    return error.Unsupported;
}

pub fn set_sidebar_items(handle: NativeShellHandle, items: []const types.SidebarEntry) void {
    _ = handle;
    _ = items;
}
pub fn set_sidebar_on_select(ctx: *anyopaque, callback: types.SidebarSelectFn) void {
    _ = ctx;
    _ = callback;
}
pub fn set_sidebar_on_reorder(ctx: *anyopaque, callback: types.SidebarReorderFn) void {
    _ = ctx;
    _ = callback;
}
pub fn set_sidebar_selection(id: []const u8) void {
    _ = id;
}
pub fn set_native_shell_title(handle: NativeShellHandle, title: []const u8) void {
    _ = handle;
    _ = title;
}
pub fn set_native_shell_on_scroll(ctx: *anyopaque, callback: types.ScrollFn) void {
    _ = ctx;
    _ = callback;
}
pub fn set_native_shell_on_body_move(ctx: *anyopaque, callback: BodyMouseFn) void {
    _ = ctx;
    _ = callback;
}
pub fn set_native_shell_on_body_click(ctx: *anyopaque, callback: BodyMouseFn) void {
    _ = ctx;
    _ = callback;
}
pub fn set_native_shell_on_body_exit(ctx: *anyopaque, callback: BodyExitFn) void {
    _ = ctx;
    _ = callback;
}
pub fn set_toolbar_items(handle: NativeShellHandle, items: []const types.ToolbarEntry) void {
    _ = handle;
    _ = items;
}
pub fn set_toolbar_on_select(ctx: *anyopaque, callback: types.ToolbarSelectFn) void {
    _ = ctx;
    _ = callback;
}
pub fn set_toolbar_on_search(ctx: *anyopaque, callback: types.ToolbarSearchFn) void {
    _ = ctx;
    _ = callback;
}

pub fn run_alert(opts: types.AlertOptions) usize {
    _ = opts;
    return 0;
}

pub fn native_image_named(name: []const u8) ?*anyopaque {
    _ = name;
    return null;
}

pub fn open_file(opts: types.FilePickerOptions, out_buf: []u8) []const u8 {
    _ = opts;
    _ = out_buf;
    return "";
}

pub fn save_file(opts: types.FilePickerOptions, out_buf: []u8) []const u8 {
    _ = opts;
    _ = out_buf;
    return "";
}
