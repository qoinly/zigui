// The iOS arm of the custom-shell facade. UIKit gives the app one fullscreen
// surface with no client-side decorations, pointer grab, or clipboard, so this is
// mostly an honest no-op set: it exposes the exact pub surface the desktop shells
// do - so the facade's non-macOS branches resolve here - while the window methods
// PaintContext reads (size, scale, theme) report the live view state.
//
// The handle carries the CAMetalLayer the renderer draws into. app.zig builds the
// view at launch and registers the IOSWindow storage here (the renderer holds the
// same pointer), set on surface ready.

const std = @import("std");
const objc = @import("../macos/objc.zig");
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
pub const HitTestFn = shell_types.HitTestFn;
pub const RedrawFn = shell_types.RedrawFn;
pub const WindowCloseFn = shell_types.WindowCloseFn;
pub const CAPTION_BTN_W = shell_types.CAPTION_BTN_W;
pub const CAPTION_CLUSTER_W = shell_types.CAPTION_CLUSTER_W;
pub const Error = shell_types.Error;
pub const ContentSize = shell_types.ContentSize;

// The IOSWindow storage lives in app.zig; the shell reaches it to report
// size/scale and the layer.
var g_window: ?*native.IOSWindow = null;

// The paint loop registers a MouseDispatch (ctx = the PaintContext) once at surface
// start; the view's touch methods read it back to route a tap. Never cleared - one
// surface per app, so it stays valid for the app's life.
var g_dispatch: ?MouseDispatch = null;

pub fn set_window(window: *native.IOSWindow) void {
    g_window = window;
}

pub fn mouse_dispatch() ?MouseDispatch {
    return g_dispatch;
}

// A finger drag the input layer routes through this handler: it scrolls the region
// under the touch (or drags a captured control). The paint loop registers it; the
// view's touch methods read it back.
const TouchMoveFn = *const fn (ctx: *anyopaque, x: f32, y: f32) void;
const TouchMove = struct { cb: TouchMoveFn, ctx: *anyopaque };
var g_touch: ?TouchMove = null;

pub fn register_touch_move(cb: TouchMoveFn, ctx: *anyopaque) void {
    g_touch = .{ .cb = cb, .ctx = ctx };
}

pub fn touch_move() ?TouchMove {
    return g_touch;
}

const UIEdgeInsets = extern struct {
    top: objc.CGFloat,
    left: objc.CGFloat,
    bottom: objc.CGFloat,
    right: objc.CGFloat,
};

// Insets the paint loop carves off the body for the status bar, dynamic island,
// and home indicator. UIKit computes UIView.safeAreaInsets per device in points,
// so they are read live (they change with rotation and device), never hardcoded.
pub fn safe_area_insets() geometry.Insets {
    const w = g_window orelse return .{};
    const view = w.view orelse return .{};
    const e = objc.msg_send(UIEdgeInsets, view, "safeAreaInsets", .{});
    return .{
        .left = @floatCast(e.left),
        .top = @floatCast(e.top),
        .right = @floatCast(e.right),
        .bottom = @floatCast(e.bottom),
    };
}

pub const CustomShellHandle = struct {
    window: *anyopaque,
    metal_layer: objc.Id,
    height: f32,
    theme: types.Theme,
    titlebar: types.TitlebarOptions,

    fn win(self: CustomShellHandle) *native.IOSWindow {
        return @ptrCast(@alignCast(self.window));
    }

    // One fullscreen surface: the focus/state queries are constants - it is always
    // the key surface, never min/max/fullscreen in the desktop sense.
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

    pub fn backing_scale_factor(self: CustomShellHandle) f32 {
        const s = self.win().scale;
        std.debug.assert(s >= 1);
        return @floatFromInt(s);
    }

    pub fn sync_drawable_size(self: CustomShellHandle) ContentSize {
        const w = self.win();
        w.sync_extent();
        std.debug.assert(w.width_pt >= 1);
        return .{
            .width = @floatFromInt(w.width_pt),
            .height = @floatFromInt(w.height_pt),
        };
    }

    pub fn deinit(self: CustomShellHandle) void {
        _ = self;
        // UIKit owns the window and view; teardown drops the renderer side, so
        // there is nothing to free here.
    }
};

// The iOS surface arrives through the delegate, not an open() call, so this wraps
// the already-built view app.zig registered. Chrome is disabled: the body fills
// the whole surface.
pub fn open(opts: types.NativeShellOptions) Error!CustomShellHandle {
    const window = g_window orelse return error.WindowCreateFailed;
    if (!window.in_use) return error.WindowCreateFailed;
    const layer = window.layer orelse return error.WindowCreateFailed;
    return .{
        .window = @ptrCast(window),
        .metal_layer = layer,
        .height = @floatCast(opts.height),
        .theme = opts.theme orelse types.Theme.default_dark(),
        .titlebar = .{ .enabled = false },
    };
}

// The paint loop registers a MouseDispatch here; the view's touch methods read it
// back to route a tap. The raw/grab/cursor hooks below have no iOS source and are
// accepted and dropped.
pub fn register_mouse_dispatch(d: MouseDispatch) void {
    g_dispatch = d;
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

pub fn apply_cursor(kind: CursorKind) void {
    _ = kind;
}

pub fn current_shift_down() bool {
    return false;
}

pub fn hovered_caption_button() CaptionButton {
    return .none;
}

// No native text field is shown, so a focused input degrades to a non-editing
// draw with an empty editor value.
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
    std.debug.assert(id != 0);
    return false;
}

pub fn hide_text_field(handle: CustomShellHandle) void {
    _ = handle;
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
