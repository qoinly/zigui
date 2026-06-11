// libwayland-cursor binding: the compositor draws no pointer over a client
// surface unless the client attaches a cursor image, so the shell loads the
// system theme and sets one on pointer enter. dlopen like the other bindings.

const std = @import("std");
const wl = @import("wayland.zig");

pub const Error = error{LibraryLoadFailed};

pub const CursorTheme = opaque {};

pub const CursorImage = extern struct {
    width: u32,
    height: u32,
    hotspot_x: u32,
    hotspot_y: u32,
    delay: u32,
};

pub const Cursor = extern struct {
    image_count: c_uint,
    images: [*]*CursorImage,
    name: [*:0]u8,
};

extern "c" fn dlopen(file: [*:0]const u8, mode: c_int) ?*anyopaque;
extern "c" fn dlsym(handle: ?*anyopaque, name: [*:0]const u8) ?*anyopaque;
const RTLD_NOW: c_int = 2;

const Fns = struct {
    wl_cursor_theme_load: *const fn (
        ?[*:0]const u8,
        c_int,
        *wl.wl_proxy,
    ) callconv(.c) ?*CursorTheme,
    wl_cursor_theme_destroy: *const fn (*CursorTheme) callconv(.c) void,
    wl_cursor_theme_get_cursor: *const fn (
        *CursorTheme,
        [*:0]const u8,
    ) callconv(.c) ?*Cursor,
    wl_cursor_image_get_buffer: *const fn (*CursorImage) callconv(.c) ?*wl.wl_proxy,
};

var fns: Fns = undefined;
var g_loaded: bool = false;

pub fn load() Error!void {
    if (g_loaded) return;
    const handle = dlopen("libwayland-cursor.so.0", RTLD_NOW) orelse
        return error.LibraryLoadFailed;
    inline for (@typeInfo(Fns).@"struct".fields) |field| {
        const sym = dlsym(handle, field.name) orelse return error.LibraryLoadFailed;
        @field(fns, field.name) = @ptrCast(@alignCast(sym));
    }
    g_loaded = true;
    std.debug.assert(g_loaded);
}

pub fn theme_load(size: i32, shm: *wl.wl_proxy) ?*CursorTheme {
    std.debug.assert(g_loaded);
    std.debug.assert(size > 0);
    return fns.wl_cursor_theme_load(null, size, shm);
}

pub fn theme_destroy(theme: *CursorTheme) void {
    std.debug.assert(g_loaded);
    fns.wl_cursor_theme_destroy(theme);
}

// Tries each name in order; themes disagree on legacy vs cursor-spec names.
pub fn get_cursor(theme: *CursorTheme, names: []const [*:0]const u8) ?*Cursor {
    std.debug.assert(g_loaded);
    std.debug.assert(names.len >= 1);
    std.debug.assert(names.len <= 4);
    for (names) |name| {
        if (fns.wl_cursor_theme_get_cursor(theme, name)) |cursor| {
            if (cursor.image_count >= 1) return cursor;
        }
    }
    return null;
}

pub fn image_buffer(image: *CursorImage) ?*wl.wl_proxy {
    std.debug.assert(g_loaded);
    return fns.wl_cursor_image_get_buffer(image);
}
