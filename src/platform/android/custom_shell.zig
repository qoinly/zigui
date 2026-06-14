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
const jni = @import("jni.zig");
const ime = @import("ime.zig");
const window_props = @import("window_props.zig");
const native_apis = @import("native_apis.zig");

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

// The paint loop registers a MouseDispatch (ctx = the PaintContext); the input
// layer reads it back to route touch as pointer events. Cleared on surface loss
// so a stale PaintContext is never dispatched into.
var g_dispatch: ?MouseDispatch = null;

// System-bar insets in pixels, refreshed from JNI on layout changes; the paint
// loop reads them back in points via safe_area_insets().
var g_insets_px: jni.Insets = .{};

// The touch-move handler the paint loop registers (cb + the PaintContext ctx);
// the input layer routes a finger drag through it. Cleared on surface loss.
const TouchMoveFn = *const fn (ctx: *anyopaque, x: f32, y: f32) void;
const TouchMove = struct { cb: TouchMoveFn, ctx: *anyopaque };
var g_touch: ?TouchMove = null;

// The back handler the paint loop registers; the input layer calls it on a Back
// key. Returns whether the press was consumed (a route popped). Cleared on loss.
const BackFn = *const fn (ctx: *anyopaque) bool;
const Back = struct { cb: BackFn, ctx: *anyopaque };
var g_back: ?Back = null;

pub fn set_window(window: *native.AndroidWindow) void {
    g_window = window;
}

pub fn clear_window() void {
    g_window = null;
    g_dispatch = null;
    g_touch = null;
    g_back = null;
}

pub fn register_back(cb: BackFn, ctx: *anyopaque) void {
    g_back = .{ .cb = cb, .ctx = ctx };
}

// Routes a Back press to the handler; returns whether it was consumed (else the
// caller lets the OS background the app).
pub fn dispatch_back() bool {
    const b = g_back orelse return false;
    return b.cb(b.ctx);
}

pub fn mouse_dispatch() ?MouseDispatch {
    return g_dispatch;
}

pub fn register_touch_move(cb: TouchMoveFn, ctx: *anyopaque) void {
    g_touch = .{ .cb = cb, .ctx = ctx };
}

pub fn touch_move() ?TouchMove {
    return g_touch;
}

pub fn surface_scale() i32 {
    const w = g_window orelse return 1;
    std.debug.assert(w.scale >= 1);
    return w.scale;
}

pub fn set_insets(insets: jni.Insets) void {
    g_insets_px = insets;
}

pub fn safe_area_insets() geometry.Insets {
    const scale: f32 = @floatFromInt(surface_scale());
    std.debug.assert(scale >= 1);
    return .{
        .left = @as(f32, @floatFromInt(g_insets_px.left)) / scale,
        .top = @as(f32, @floatFromInt(g_insets_px.top)) / scale,
        .right = @as(f32, @floatFromInt(g_insets_px.right)) / scale,
        .bottom = @as(f32, @floatFromInt(g_insets_px.bottom)) / scale,
    };
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

// Touch is routed through this dispatch (the input layer reads it back via
// mouse_dispatch); the other registrations have no Android source, so the paint
// loop registers them unconditionally and they are accepted and dropped.
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

pub fn hovered_caption_button() CaptionButton {
    return .none;
}

pub fn apply_cursor(kind: CursorKind) void {
    _ = kind;
}

pub fn current_shift_down() bool {
    return false;
}

// The id of the field currently driving the IME, so a newly focused field
// reseeds the editor and raises the keyboard exactly once (show_text_field is
// called every frame while a field is focused).
var g_field_id: u32 = 0;

// The Java EditText owns the editing; the kit draws the value/caret it pushes back
// (text_field_native_paint is false here). On a newly focused field, seed the
// editor with the widget's value and raise the keyboard.
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
    _ = font_size;
    _ = color;
    _ = secure;
    _ = numeric;
    std.debug.assert(id != 0);
    if (id != g_field_id) {
        g_field_id = id;
        ime.show_keyboard(initial);
    }
    return true;
}

pub fn hide_text_field(handle: CustomShellHandle) void {
    _ = handle;
    if (g_field_id != 0) {
        g_field_id = 0;
        ime.hide_keyboard();
    }
}

pub fn text_field_value(buf: []u8) []const u8 {
    return ime.value(buf);
}

pub fn text_field_caret() usize {
    return ime.caret();
}

pub fn text_field_selection() [2]usize {
    const c = ime.caret();
    return .{ c, c };
}

pub fn text_field_secure() bool {
    return false;
}

pub fn pasteboard_read_into(buf: []u8) []const u8 {
    return native_apis.clipboard_read(buf);
}

pub fn pasteboard_write_string(text: []const u8) void {
    native_apis.clipboard_write(text);
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

// Runtime window properties (keep-screen-on, status-bar icon tint, immersive);
// the JNI lives in window_props, the facade reaches it through these.
pub fn set_keep_awake(on: bool) void {
    window_props.set_keep_awake(on);
}

pub fn set_status_bar_dark_icons(dark: bool) void {
    window_props.set_status_bar_dark_icons(dark);
}

pub fn set_immersive(on: bool) void {
    window_props.set_immersive(on);
}

// Platform services; the JNI lives in native_apis, the facade reaches it
// through these.
pub fn vibrate(ms: i64) void {
    native_apis.vibrate(ms);
}

pub fn open_url(url: []const u8) void {
    native_apis.open_url(url);
}

pub fn share_text(text: []const u8) void {
    native_apis.share_text(text);
}

pub fn notify(title: []const u8, text: []const u8) void {
    native_apis.notify(title, text);
}
