// The linux custom-shell dispatcher: one pub surface (what the cross-platform
// facade re-exports) forwarded to the Wayland or X11 arm picked at App.init
// (see backend.zig). The handle erases the backend window; each method
// reconstructs the arm's own handle by value - five small fields, no heap.

const std = @import("std");
const backend = @import("backend.zig");
const field = @import("field.zig");
const wayland_shell = @import("wayland_shell.zig");
const x11_shell = @import("x11_shell.zig");
const shell_types = @import("shell_types.zig");
const csd = @import("csd.zig");
const idle_inhibit = @import("idle_inhibit.zig");
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

pub const CustomShellHandle = struct {
    window: *anyopaque,
    metal_layer: *anyopaque,
    height: f32,
    theme: types.Theme,
    titlebar: types.TitlebarOptions,

    fn wl(self: CustomShellHandle) wayland_shell.CustomShellHandle {
        return .{
            .window = @ptrCast(@alignCast(self.window)),
            .metal_layer = self.metal_layer,
            .height = self.height,
            .theme = self.theme,
            .titlebar = self.titlebar,
        };
    }

    fn x11(self: CustomShellHandle) x11_shell.CustomShellHandle {
        return .{
            .window = @ptrCast(@alignCast(self.window)),
            .metal_layer = self.metal_layer,
            .height = self.height,
            .theme = self.theme,
            .titlebar = self.titlebar,
        };
    }

    pub fn focus(self: CustomShellHandle) void {
        switch (backend.active) {
            .wayland => self.wl().focus(),
            .x11 => self.x11().focus(),
        }
    }

    pub fn is_fullscreen(self: CustomShellHandle) bool {
        return switch (backend.active) {
            .wayland => self.wl().is_fullscreen(),
            .x11 => self.x11().is_fullscreen(),
        };
    }

    pub fn set_fullscreen(self: CustomShellHandle, on: bool) void {
        switch (backend.active) {
            .wayland => self.wl().set_fullscreen(on),
            .x11 => self.x11().set_fullscreen(on),
        }
    }

    pub fn backing_scale_factor(self: CustomShellHandle) f32 {
        return switch (backend.active) {
            .wayland => self.wl().backing_scale_factor(),
            .x11 => self.x11().backing_scale_factor(),
        };
    }

    pub fn is_maximized(self: CustomShellHandle) bool {
        return switch (backend.active) {
            .wayland => self.wl().is_maximized(),
            .x11 => self.x11().is_maximized(),
        };
    }

    pub fn is_minimized(self: CustomShellHandle) bool {
        return switch (backend.active) {
            .wayland => self.wl().is_minimized(),
            .x11 => self.x11().is_minimized(),
        };
    }

    pub fn minimize(self: CustomShellHandle) void {
        switch (backend.active) {
            .wayland => self.wl().minimize(),
            .x11 => self.x11().minimize(),
        }
    }
    pub fn hide(self: CustomShellHandle) void {
        self.minimize(); // no app-hide on Linux; iconify instead
    }

    pub fn is_key(self: CustomShellHandle) bool {
        return switch (backend.active) {
            .wayland => self.wl().is_key(),
            .x11 => self.x11().is_key(),
        };
    }

    pub fn sync_drawable_size(self: CustomShellHandle) ContentSize {
        return switch (backend.active) {
            .wayland => self.wl().sync_drawable_size(),
            .x11 => self.x11().sync_drawable_size(),
        };
    }

    pub fn deinit(self: CustomShellHandle) void {
        switch (backend.active) {
            .wayland => self.wl().deinit(),
            .x11 => self.x11().deinit(),
        }
    }
};

fn wrap_wl(handle: wayland_shell.CustomShellHandle) CustomShellHandle {
    return .{
        .window = @ptrCast(handle.window),
        .metal_layer = handle.metal_layer,
        .height = handle.height,
        .theme = handle.theme,
        .titlebar = handle.titlebar,
    };
}

fn wrap_x11(handle: x11_shell.CustomShellHandle) CustomShellHandle {
    return .{
        .window = @ptrCast(handle.window),
        .metal_layer = handle.metal_layer,
        .height = handle.height,
        .theme = handle.theme,
        .titlebar = handle.titlebar,
    };
}

pub fn open(opts: types.NativeShellOptions) Error!CustomShellHandle {
    return switch (backend.active) {
        .wayland => wrap_wl(try wayland_shell.open(opts)),
        .x11 => wrap_x11(try x11_shell.open(opts)),
    };
}

pub fn register_mouse_dispatch(d: MouseDispatch) void {
    switch (backend.active) {
        .wayland => wayland_shell.register_mouse_dispatch(d),
        .x11 => x11_shell.register_mouse_dispatch(d),
    }
}

pub fn register_raw_dispatch(d: RawDispatch) void {
    switch (backend.active) {
        .wayland => wayland_shell.register_raw_dispatch(d),
        .x11 => x11_shell.register_raw_dispatch(d),
    }
}

pub fn bind_surface_ctx(handle: CustomShellHandle, ctx: *anyopaque) void {
    switch (backend.active) {
        .wayland => wayland_shell.bind_surface_ctx(handle.wl(), ctx),
        .x11 => x11_shell.bind_surface_ctx(handle.x11(), ctx),
    }
}

pub fn register_window_close(cb: WindowCloseFn, ctx: *anyopaque) void {
    switch (backend.active) {
        .wayland => wayland_shell.register_window_close(cb, ctx),
        .x11 => x11_shell.register_window_close(cb, ctx),
    }
}

pub fn register_hit_test(hit_test_cb: HitTestFn, redraw_cb: RedrawFn, ctx: *anyopaque) void {
    switch (backend.active) {
        .wayland => wayland_shell.register_hit_test(hit_test_cb, redraw_cb, ctx),
        .x11 => x11_shell.register_hit_test(hit_test_cb, redraw_cb, ctx),
    }
}

pub fn register_paint_now(cb: RedrawFn) void {
    switch (backend.active) {
        .wayland => wayland_shell.register_paint_now(cb),
        .x11 => x11_shell.register_paint_now(cb),
    }
}

pub fn set_grab(on: bool) void {
    switch (backend.active) {
        .wayland => wayland_shell.set_grab(on),
        .x11 => x11_shell.set_grab(on),
    }
}

pub fn is_grabbed() bool {
    return switch (backend.active) {
        .wayland => wayland_shell.is_grabbed(),
        .x11 => x11_shell.is_grabbed(),
    };
}

pub fn release_grab_if_blurred() void {
    switch (backend.active) {
        .wayland => wayland_shell.release_grab_if_blurred(),
        .x11 => x11_shell.release_grab_if_blurred(),
    }
}

pub fn hovered_caption_button() CaptionButton {
    return switch (backend.active) {
        .wayland => wayland_shell.hovered_caption_button(),
        .x11 => x11_shell.hovered_caption_button(),
    };
}

pub fn apply_cursor(kind: CursorKind) void {
    switch (backend.active) {
        .wayland => wayland_shell.apply_cursor(kind),
        .x11 => x11_shell.apply_cursor(kind),
    }
}

// Idle-sleep inhibitor via dbus (the ScreenSaver service), the same on both arms.
pub fn set_keep_awake(on: bool) void {
    idle_inhibit.set(on);
}

pub fn current_shift_down() bool {
    return switch (backend.active) {
        .wayland => wayland_shell.current_shift_down(),
        .x11 => x11_shell.current_shift_down(),
    };
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
    return switch (backend.active) {
        .wayland => wayland_shell.show_text_field(
            handle.wl(),
            x,
            y,
            w,
            h,
            initial,
            font_size,
            color,
            secure,
            numeric,
            id,
        ),
        .x11 => x11_shell.show_text_field(
            handle.x11(),
            x,
            y,
            w,
            h,
            initial,
            font_size,
            color,
            secure,
            numeric,
            id,
        ),
    };
}

pub fn hide_text_field(handle: CustomShellHandle) void {
    switch (backend.active) {
        .wayland => wayland_shell.hide_text_field(handle.wl()),
        .x11 => x11_shell.hide_text_field(handle.x11()),
    }
}

pub fn text_field_value(buf: []u8) []const u8 {
    return switch (backend.active) {
        .wayland => wayland_shell.text_field_value(buf),
        .x11 => x11_shell.text_field_value(buf),
    };
}

// The field module is shared by both backends (each feeds it keys), so the pending special
// key is read straight from it, no per-backend split.
pub fn text_field_special() ?shell_types.FieldKey {
    return field.take_special();
}

pub fn text_field_caret() usize {
    return switch (backend.active) {
        .wayland => wayland_shell.text_field_caret(),
        .x11 => x11_shell.text_field_caret(),
    };
}

pub fn text_field_selection() [2]usize {
    return switch (backend.active) {
        .wayland => wayland_shell.text_field_selection(),
        .x11 => x11_shell.text_field_selection(),
    };
}

pub fn text_field_secure() bool {
    return switch (backend.active) {
        .wayland => wayland_shell.text_field_secure(),
        .x11 => x11_shell.text_field_secure(),
    };
}

pub fn pasteboard_read_into(buf: []u8) []const u8 {
    return switch (backend.active) {
        .wayland => wayland_shell.pasteboard_read_into(buf),
        .x11 => x11_shell.pasteboard_read_into(buf),
    };
}

pub fn pasteboard_write_string(text: []const u8) void {
    switch (backend.active) {
        .wayland => wayland_shell.pasteboard_write_string(text),
        .x11 => x11_shell.pasteboard_write_string(text),
    }
}

pub fn clipboard_changed_external() bool {
    return switch (backend.active) {
        .wayland => wayland_shell.clipboard_changed_external(),
        .x11 => x11_shell.clipboard_changed_external(),
    };
}

pub fn desktop_accent_color() ?types.Rgba {
    return switch (backend.active) {
        .wayland => wayland_shell.desktop_accent_color(),
        .x11 => x11_shell.desktop_accent_color(),
    };
}

// Both arms read the same desktop layout; no backend fork to make.
pub fn caption_slots() CaptionSlots {
    return csd.caption_slots();
}

pub fn display_count() u32 {
    return switch (backend.active) {
        .wayland => wayland_shell.display_count(),
        .x11 => x11_shell.display_count(),
    };
}

pub fn display_bounds(index: u32) geometry.BoundsF {
    return switch (backend.active) {
        .wayland => wayland_shell.display_bounds(index),
        .x11 => x11_shell.display_bounds(index),
    };
}

pub fn tick_key_repeat() void {
    switch (backend.active) {
        .wayland => wayland_shell.tick_key_repeat(),
        .x11 => x11_shell.tick_key_repeat(),
    }
}
