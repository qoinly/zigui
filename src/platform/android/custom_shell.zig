// The Android arm of the custom-shell facade. NativeActivity hands the app one
// fullscreen surface with no client-side decorations, no pointer grab, and no
// clipboard or IME, so this is mostly an honest no-op set: it exposes the exact
// pub surface the Linux shell does - so the facade's os.tag == .linux branches
// resolve here unchanged - while the window methods PaintContext reads (size,
// scale, theme, titlebar) report the live ANativeWindow state.
//
// The handle carries a pointer to the AndroidWindow storage that app.zig owns
// (the renderer reads the same storage), set on onNativeWindowCreated. The
// no-op registrations and empty editing/clipboard reads let the shared kit and
// paint loop degrade rather than break where the surface offers no such input.

const std = @import("std");
const native = @import("native.zig");
const shell_types = @import("../linux/shell_types.zig");
const types = @import("../../window/types.zig");
const geometry = @import("../../geometry.zig");

pub const KeyMods = shell_types.KeyMods;
pub const KeyCode = shell_types.KeyCode;
pub const KeyEvent = shell_types.KeyEvent;
pub const MouseDispatch = shell_types.MouseDispatch;
pub const RawDispatch = shell_types.RawDispatch;
pub const CursorKind = shell_types.CursorKind;
pub const CaptionButton = shell_types.CaptionButton;
pub const CaptionSlots = shell_types.CaptionSlots;
pub const HitTestFn = shell_types.HitTestFn;
pub const RedrawFn = shell_types.RedrawFn;
pub const WindowCloseFn = shell_types.WindowCloseFn;
pub const CAPTION_BTN_W = shell_types.CAPTION_BTN_W;
pub const CAPTION_CLUSTER_W = shell_types.CAPTION_CLUSTER_W;
pub const Error = shell_types.Error;
pub const ContentSize = shell_types.ContentSize;

// The AndroidWindow storage lives in app.zig (the renderer holds the same
// pointer); the shell only needs to reach it to report size/scale. Set when the
// surface is created, cleared when it is destroyed.
var g_window: ?*native.AndroidWindow = null;

pub fn set_window(window: *native.AndroidWindow) void {
    g_window = window;
}

pub fn clear_window() void {
    g_window = null;
}

pub const CustomShellHandle = struct {
    window: *anyopaque,
    metal_layer: *anyopaque,
    height: f32,
    theme: types.Theme,
    titlebar: types.TitlebarOptions,

    fn win(self: CustomShellHandle) *native.AndroidWindow {
        return @ptrCast(@alignCast(self.window));
    }

    // No window manager on a single-surface activity, so the focus/state queries
    // are constants: the one surface is always the key, never min/max/fullscreen
    // in the desktop sense (it simply fills the screen).
    pub fn focus(self: CustomShellHandle) void {
        _ = self;
    }

    pub fn is_fullscreen(self: CustomShellHandle) bool {
        _ = self;
        return false;
    }

    pub fn set_fullscreen(self: CustomShellHandle, on: bool) void {
        _ = self;
        _ = on;
    }

    pub fn backing_scale_factor(self: CustomShellHandle) f32 {
        const s = self.win().scale;
        std.debug.assert(s >= 1);
        return @floatFromInt(s);
    }

    pub fn is_maximized(self: CustomShellHandle) bool {
        _ = self;
        return false;
    }

    pub fn is_minimized(self: CustomShellHandle) bool {
        _ = self;
        return false;
    }

    pub fn is_key(self: CustomShellHandle) bool {
        _ = self;
        return true;
    }

    pub fn sync_drawable_size(self: CustomShellHandle) ContentSize {
        const w = self.win();
        w.sync_extent();
        return .{
            .width = @floatFromInt(w.width_pt),
            .height = @floatFromInt(w.height_pt),
        };
    }

    pub fn deinit(self: CustomShellHandle) void {
        _ = self;
        // The framework owns the ANativeWindow; tearing the renderer down on
        // onNativeWindowDestroyed releases our side, nothing to free here.
    }
};

// The Android window arrives via the framework, not an open() call, so this
// wraps the already-created surface app.zig registered. The chrome is disabled
// (no CSD): the body fills the whole surface.
pub fn open(opts: types.NativeShellOptions) Error!CustomShellHandle {
    const window = g_window orelse return error.WindowCreateFailed;
    if (!window.in_use) return error.WindowCreateFailed;
    return .{
        .window = @ptrCast(window),
        .metal_layer = @ptrCast(window),
        .height = @floatCast(opts.height),
        .theme = opts.theme orelse types.Theme.default_dark(),
        .titlebar = .{ .enabled = false },
    };
}

// The fullscreen surface has no pointer, hit-test, or synchronous paint-now
// source; the paint loop registers these unconditionally, so accept and drop them.
pub fn register_mouse_dispatch(d: MouseDispatch) void {
    _ = d;
}

pub fn register_raw_dispatch(d: RawDispatch) void {
    _ = d;
}

pub fn bind_surface_ctx(handle: CustomShellHandle, ctx: *anyopaque) void {
    _ = handle;
    _ = ctx;
}

pub fn register_window_close(cb: WindowCloseFn, ctx: *anyopaque) void {
    _ = cb;
    _ = ctx;
}

pub fn register_hit_test(hit_test_cb: HitTestFn, redraw_cb: RedrawFn, ctx: *anyopaque) void {
    _ = hit_test_cb;
    _ = redraw_cb;
    _ = ctx;
}

pub fn register_paint_now(cb: RedrawFn) void {
    _ = cb;
}

// No relative-pointer capture on touch; grab is inert.
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
    _ = kind;
}

pub fn current_shift_down() bool {
    return false;
}

// No soft-keyboard (IME) bridge, so no field is editable: show returns false (the
// kit then skips its caret/value poll) and the value reads return empty.
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
    _ = handle;
    _ = x;
    _ = y;
    _ = w;
    _ = h;
    _ = initial;
    _ = font_size;
    _ = color;
    _ = secure;
    _ = numeric;
    _ = id;
    return false;
}

pub fn hide_text_field(handle: CustomShellHandle) void {
    _ = handle;
}

pub fn text_field_value(buf: []u8) []const u8 {
    return buf[0..0];
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
    return buf[0..0];
}

pub fn pasteboard_write_string(text: []const u8) void {
    _ = text;
}

pub fn clipboard_changed_external() bool {
    return false;
}

pub fn desktop_accent_color() ?types.Rgba {
    return null;
}

pub fn caption_slots() CaptionSlots {
    return .{ .kinds = .{ .close, .maximize, .minimize }, .count = 3 };
}

pub fn display_count() u32 {
    return 1;
}

pub fn display_bounds(index: u32) geometry.BoundsF {
    std.debug.assert(index == 0);
    const window = g_window orelse return .{};
    return .{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{
            .width = @floatFromInt(window.width_pt),
            .height = @floatFromInt(window.height_pt),
        },
    };
}

// Server-side autorepeat does not apply; there is no client repeat timer to tick.
pub fn tick_key_repeat() void {}
