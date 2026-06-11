// os.tag facade for the custom-chrome shell. Separate from window.zig (which
// would be a circular import via window/paint.zig) so the cross-platform paint
// loop can reach the platform custom shell through one switch.

const builtin = @import("builtin");

const impl = switch (builtin.os.tag) {
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
pub const pasteboard_read_into = impl.pasteboard_read_into;
pub const pasteboard_write_string = impl.pasteboard_write_string;
pub const clipboard_changed_external = impl.clipboard_changed_external;
pub const display_count = impl.display_count;
pub const display_bounds = impl.display_bounds;

// Windows draws its window controls into the title-bar band itself (the macOS
// backend uses native traffic lights). These hooks are no-ops elsewhere; the
// caption metrics are defined here so the paint layer can reserve/draw them.
pub const CaptionButton = if (builtin.os.tag == .windows) impl.CaptionButton else enum {
    none,
    minimize,
    maximize,
    close,
};
pub const CAPTION_BTN_W: f32 = if (builtin.os.tag == .windows) impl.CAPTION_BTN_W else 46;
pub const CAPTION_CLUSTER_W: f32 = if (builtin.os.tag == .windows) impl.CAPTION_CLUSTER_W else 0;
pub const HitTestFn = *const fn (ctx: *anyopaque, x: f32, y: f32, band_h: f32) bool;
pub const RedrawFn = *const fn (ctx: *anyopaque) void;

pub fn register_hit_test(hit_test_cb: HitTestFn, redraw_cb: RedrawFn, ctx: *anyopaque) void {
    impl.register_hit_test(hit_test_cb, redraw_cb, ctx);
}

pub fn register_paint_now(cb: RedrawFn) void {
    if (builtin.os.tag == .windows) impl.register_paint_now(cb);
}

pub fn hovered_caption_button() CaptionButton {
    if (builtin.os.tag == .windows) return impl.hovered_caption_button();
    return .none;
}
