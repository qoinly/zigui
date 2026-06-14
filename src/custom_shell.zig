// os.tag facade for the custom-chrome shell. Separate from window.zig (which
// would be a circular import via window/paint.zig) so the cross-platform paint
// loop can reach the platform custom shell through one switch.

const builtin = @import("builtin");

// Android is os.tag == .linux but has no desktop shell (NativeActivity owns one
// fullscreen surface, no CSD, no clipboard/grab); it gets its own arm ahead of
// the os.tag switch, mirroring app.zig. Its pub surface matches the Linux one
// exactly so the os.tag == .linux branches below resolve to it unchanged.
const impl = if (builtin.abi.isAndroid())
    @import("platform/android/custom_shell.zig")
else switch (builtin.os.tag) {
    .macos => @import("platform/macos/custom_shell.zig"),
    .windows => @import("platform/windows/custom_shell.zig"),
    .linux => @import("platform/linux/custom_shell.zig"),
    else => @compileError("zigui: unsupported OS for custom shell"),
};

pub const CustomShellHandle = impl.CustomShellHandle;
pub const open = impl.open;
pub const Error = impl.Error;
pub const KeyEvent = impl.KeyEvent;
pub const KeyCode = impl.KeyCode;
pub const KeyMods = impl.KeyMods;
pub const MouseDispatch = impl.MouseDispatch;
pub const CursorKind = impl.CursorKind;
pub const register_mouse_dispatch = impl.register_mouse_dispatch;
pub const RawDispatch = impl.RawDispatch;
pub const register_raw_dispatch = impl.register_raw_dispatch;
pub const bind_surface_ctx = impl.bind_surface_ctx;
pub const WindowCloseFn = impl.WindowCloseFn;
pub const register_window_close = impl.register_window_close;
pub const set_grab = impl.set_grab;
pub const is_grabbed = impl.is_grabbed;
pub const release_grab_if_blurred = impl.release_grab_if_blurred;
pub const apply_cursor = impl.apply_cursor;
pub const current_shift_down = impl.current_shift_down;
pub const show_text_field = impl.show_text_field;
pub const hide_text_field = impl.hide_text_field;
pub const text_field_value = impl.text_field_value;

// Whether the platform's text-field overlay paints itself (a real native
// control floats above the surface). When false the platform owns only the
// editing state and the kit draws the value, caret, and selection.
pub const text_field_native_paint = builtin.os.tag != .linux;

pub fn text_field_caret() usize {
    return if (builtin.os.tag == .linux) impl.text_field_caret() else 0;
}

pub fn text_field_selection() [2]usize {
    return if (builtin.os.tag == .linux) impl.text_field_selection() else .{ 0, 0 };
}

pub fn text_field_secure() bool {
    return if (builtin.os.tag == .linux) impl.text_field_secure() else false;
}

pub const pasteboard_read_into = impl.pasteboard_read_into;
pub const pasteboard_write_string = impl.pasteboard_write_string;
pub const clipboard_changed_external = impl.clipboard_changed_external;
pub const display_count = impl.display_count;
pub const display_bounds = impl.display_bounds;

// Windows and Linux draw their window controls into the title-bar band itself
// (the macOS backend uses native traffic lights). These hooks are no-ops on
// macOS; the caption metrics live here so the paint layer can reserve/draw them.
pub const CaptionButton = if (builtin.os.tag == .macos) enum {
    none,
    minimize,
    maximize,
    close,
} else impl.CaptionButton;
pub const CAPTION_BTN_W: f32 = if (builtin.os.tag == .macos) 46 else impl.CAPTION_BTN_W;
pub const CAPTION_CLUSTER_W: f32 = if (builtin.os.tag == .macos) 0 else impl.CAPTION_CLUSTER_W;
pub const HitTestFn = *const fn (ctx: *anyopaque, x: f32, y: f32, band_h: f32) bool;
pub const RedrawFn = *const fn (ctx: *anyopaque) void;

pub fn register_hit_test(hit_test_cb: HitTestFn, redraw_cb: RedrawFn, ctx: *anyopaque) void {
    impl.register_hit_test(hit_test_cb, redraw_cb, ctx);
}

pub fn register_paint_now(cb: RedrawFn) void {
    if (builtin.os.tag != .macos) impl.register_paint_now(cb);
}

// Touch routes a finger drag through a single handler that scrolls the region
// under it (or drags a captured control). Only the Android backend has a touch
// source; the desktop backends use the wheel + drag separately and ignore this.
pub const TouchMoveFn = *const fn (ctx: *anyopaque, x: f32, y: f32) void;
pub fn register_touch_move(cb: TouchMoveFn, ctx: *anyopaque) void {
    if (builtin.abi.isAndroid()) impl.register_touch_move(cb, ctx);
}

// The platform Back button: only Android has one. The handler returns whether it
// consumed the press (a route was popped); the backend backgrounds the app when
// it returns false. Desktop Esc flows through the key queue instead, so this is a
// no-op there.
pub const BackFn = *const fn (ctx: *anyopaque) bool;
pub fn register_back(cb: BackFn, ctx: *anyopaque) void {
    if (builtin.abi.isAndroid()) impl.register_back(cb, ctx);
}

// Runtime window properties. Only Android exposes these (keep-screen-on via a
// window flag, the status-bar icon tint and immersive via the insets controller);
// desktop windows have no system bars and manage idle sleep elsewhere, so these
// are no-ops there.
pub fn set_keep_awake(on: bool) void {
    if (builtin.abi.isAndroid()) impl.set_keep_awake(on);
}
pub fn set_status_bar_dark_icons(dark: bool) void {
    if (builtin.abi.isAndroid()) impl.set_status_bar_dark_icons(dark);
}
pub fn set_immersive(on: bool) void {
    if (builtin.abi.isAndroid()) impl.set_immersive(on);
}

// Platform services: only Android exposes these as a system call here, so
// off Android they are no-ops rather than a wrong-platform action.
pub fn vibrate(ms: i64) void {
    if (builtin.abi.isAndroid()) impl.vibrate(ms);
}
pub fn open_url(url: []const u8) void {
    if (builtin.abi.isAndroid()) impl.open_url(url);
}
pub fn share_text(text: []const u8) void {
    if (builtin.abi.isAndroid()) impl.share_text(text);
}
pub fn notify(title: []const u8, text: []const u8) void {
    if (builtin.abi.isAndroid()) impl.notify(title, text);
}

// Only Linux desktops keep the user's accent outside the app theme; the close
// control there follows it.
pub fn desktop_accent_color() ?@import("window/types.zig").Rgba {
    if (builtin.os.tag == .linux) return impl.desktop_accent_color();
    return null;
}

// Safe-area insets (points) the paint loop carves off the body. Only the Android
// surface is edge-to-edge under the system bars; desktop windows exclude their
// chrome already, so the insets are zero and the body math is unchanged.
pub fn safe_area_insets() @import("geometry.zig").Insets {
    if (builtin.abi.isAndroid()) return impl.safe_area_insets();
    return .{};
}

// Caption slots indexed from the right edge (slot 0 = rightmost). Linux
// follows the desktop's button-layout; Windows keeps its fixed trio.
pub const CaptionSlots = struct { kinds: [3]CaptionButton, count: u8 };

pub fn caption_slots() CaptionSlots {
    if (builtin.os.tag == .linux) {
        const slots = impl.caption_slots();
        return .{ .kinds = slots.kinds, .count = slots.count };
    }
    return .{ .kinds = .{ .close, .maximize, .minimize }, .count = 3 };
}

pub fn hovered_caption_button() CaptionButton {
    if (builtin.os.tag == .macos) return .none;
    return impl.hovered_caption_button();
}
