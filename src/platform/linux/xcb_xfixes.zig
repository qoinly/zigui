// libxcb-xfixes binding for selection-owner notifications: the only way an
// X11 client hears about ANOTHER client taking the clipboard (the core
// protocol only tells the previous owner). dlopen like the other bindings.

const std = @import("std");
const xcb = @import("xcb.zig");

pub const Error = error{LibraryLoadFailed};

// XFixesSelectionNotify arrives at first_event + 0 with this layout.
pub const SelectionEvent = extern struct {
    response_type: u8,
    subtype: u8,
    sequence: u16,
    window: u32,
    owner: u32,
    selection: u32,
    timestamp: u32,
    selection_timestamp: u32,
};

const MASK_SET_SELECTION_OWNER: u32 = 1;
const MASK_SELECTION_WINDOW_DESTROY: u32 = 2;
const MASK_SELECTION_CLIENT_CLOSE: u32 = 4;

const QueryVersionCookie = extern struct { sequence: c_uint };
const QueryVersionReply = extern struct {
    response_type: u8,
    pad0: u8,
    sequence: u16,
    length: u32,
    major_version: u32,
    minor_version: u32,
};

extern "c" fn dlopen(file: [*:0]const u8, mode: c_int) ?*anyopaque;
extern "c" fn dlsym(handle: ?*anyopaque, name: [*:0]const u8) ?*anyopaque;
extern "c" fn free(ptr: ?*anyopaque) void;
const RTLD_NOW: c_int = 2;

const Fns = struct {
    xcb_xfixes_query_version: *const fn (
        *xcb.Connection,
        u32,
        u32,
    ) callconv(.c) QueryVersionCookie,
    xcb_xfixes_query_version_reply: *const fn (
        *xcb.Connection,
        QueryVersionCookie,
        ?*?*anyopaque,
    ) callconv(.c) ?*QueryVersionReply,
    xcb_xfixes_select_selection_input: *const fn (
        *xcb.Connection,
        u32,
        u32,
        u32,
    ) callconv(.c) extern struct { sequence: c_uint },
};

var fns: Fns = undefined;
var g_loaded = false;

// 0 means the extension is absent and selection events never fire.
pub var first_event: u8 = 0;

pub fn load() Error!void {
    if (g_loaded) return;
    const handle = dlopen("libxcb-xfixes.so.0", RTLD_NOW) orelse return error.LibraryLoadFailed;
    inline for (@typeInfo(Fns).@"struct".fields) |fn_field| {
        const sym = dlsym(handle, fn_field.name) orelse return error.LibraryLoadFailed;
        @field(fns, fn_field.name) = @ptrCast(@alignCast(sym));
    }
    const id = dlsym(handle, "xcb_xfixes_id") orelse return error.LibraryLoadFailed;
    const data = xcb.extension_data(id) orelse return error.LibraryLoadFailed;
    // The version handshake is mandatory before any other XFixes request.
    const cookie = fns.xcb_xfixes_query_version(xcb.conn.?, 5, 0);
    const reply = fns.xcb_xfixes_query_version_reply(xcb.conn.?, cookie, null) orelse
        return error.LibraryLoadFailed;
    free(reply);
    first_event = data.first_event;
    g_loaded = true;
    std.debug.assert(first_event != 0);
}

pub fn watch_selection(window: u32, selection: u32) void {
    std.debug.assert(g_loaded);
    std.debug.assert(window != 0);
    const mask = MASK_SET_SELECTION_OWNER |
        MASK_SELECTION_WINDOW_DESTROY | MASK_SELECTION_CLIENT_CLOSE;
    _ = fns.xcb_xfixes_select_selection_input(xcb.conn.?, window, selection, mask);
}
