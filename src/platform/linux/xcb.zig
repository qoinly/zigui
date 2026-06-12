// libxcb binding for the X11 backend: connection, window lifecycle, atoms,
// and the event tap the run loop drains. dlopen like every other Linux
// binding - consumers need no -dev packages, only the runtime .so.1.

const std = @import("std");

pub const Error = error{ LibraryLoadFailed, ConnectFailed };

pub const Connection = opaque {};
pub const Setup = opaque {};

pub const Screen = extern struct {
    root: u32,
    default_colormap: u32,
    white_pixel: u32,
    black_pixel: u32,
    current_input_masks: u32,
    width_in_pixels: u16,
    height_in_pixels: u16,
    width_in_millimeters: u16,
    height_in_millimeters: u16,
    min_installed_maps: u16,
    max_installed_maps: u16,
    root_visual: u32,
    backing_stores: u8,
    save_unders: u8,
    root_depth: u8,
    allowed_depths_len: u8,
};

const ScreenIterator = extern struct {
    data: ?*Screen,
    rem: c_int,
    index: c_int,
};

pub const GenericEvent = extern struct {
    response_type: u8,
    pad0: u8,
    sequence: u16,
    pad: [7]u32,
    full_sequence: u32,
};

pub const ConfigureNotifyEvent = extern struct {
    response_type: u8,
    pad0: u8,
    sequence: u16,
    event: u32,
    window: u32,
    above_sibling: u32,
    x: i16,
    y: i16,
    width: u16,
    height: u16,
    border_width: u16,
    override_redirect: u8,
    pad1: u8,
};

pub const ClientMessageEvent = extern struct {
    response_type: u8,
    format: u8,
    sequence: u16,
    window: u32,
    type: u32,
    data32: [5]u32,
};

pub const ExposeEvent = extern struct {
    response_type: u8,
    pad0: u8,
    sequence: u16,
    window: u32,
    x: u16,
    y: u16,
    width: u16,
    height: u16,
    count: u16,
    pad1: [2]u8,
};

const InternAtomReply = extern struct {
    response_type: u8,
    pad0: u8,
    sequence: u16,
    length: u32,
    atom: u32,
};

const InternAtomCookie = extern struct { sequence: c_uint };
const VoidCookie = extern struct { sequence: c_uint };

// Event response_type values (top bit flags a sent event; mask it off).
pub const EXPOSE: u8 = 12;
pub const DESTROY_NOTIFY: u8 = 17;
pub const CONFIGURE_NOTIFY: u8 = 22;
pub const CLIENT_MESSAGE: u8 = 33;

pub const ATOM_ATOM: u32 = 4;
pub const ATOM_STRING: u32 = 31;
pub const ATOM_WM_NAME: u32 = 39;

const COPY_FROM_PARENT: u8 = 0;
const WINDOW_CLASS_INPUT_OUTPUT: u16 = 1;
const CW_BACK_PIXEL: u32 = 0x2;
const CW_EVENT_MASK: u32 = 0x800;
pub const EVENT_MASK_EXPOSURE: u32 = 0x8000;
pub const EVENT_MASK_STRUCTURE_NOTIFY: u32 = 0x20000;
const PROP_MODE_REPLACE: u8 = 0;

extern "c" fn dlopen(file: [*:0]const u8, mode: c_int) ?*anyopaque;
extern "c" fn dlsym(handle: ?*anyopaque, name: [*:0]const u8) ?*anyopaque;
extern "c" fn free(ptr: ?*anyopaque) void;
const RTLD_NOW: c_int = 2;

const Fns = struct {
    xcb_connect: *const fn (?[*:0]const u8, ?*c_int) callconv(.c) ?*Connection,
    xcb_connection_has_error: *const fn (*Connection) callconv(.c) c_int,
    xcb_disconnect: *const fn (*Connection) callconv(.c) void,
    xcb_get_setup: *const fn (*Connection) callconv(.c) *Setup,
    xcb_setup_roots_iterator: *const fn (*Setup) callconv(.c) ScreenIterator,
    xcb_generate_id: *const fn (*Connection) callconv(.c) u32,
    xcb_create_window: *const fn (
        *Connection,
        u8,
        u32,
        u32,
        i16,
        i16,
        u16,
        u16,
        u16,
        u16,
        u32,
        u32,
        ?[*]const u32,
    ) callconv(.c) VoidCookie,
    xcb_destroy_window: *const fn (*Connection, u32) callconv(.c) VoidCookie,
    xcb_map_window: *const fn (*Connection, u32) callconv(.c) VoidCookie,
    xcb_flush: *const fn (*Connection) callconv(.c) c_int,
    xcb_get_file_descriptor: *const fn (*Connection) callconv(.c) c_int,
    xcb_poll_for_event: *const fn (*Connection) callconv(.c) ?*GenericEvent,
    xcb_intern_atom: *const fn (*Connection, u8, u16, [*]const u8) callconv(.c) InternAtomCookie,
    xcb_intern_atom_reply: *const fn (
        *Connection,
        InternAtomCookie,
        ?*?*anyopaque,
    ) callconv(.c) ?*InternAtomReply,
    xcb_change_property: *const fn (
        *Connection,
        u8,
        u32,
        u32,
        u32,
        u8,
        u32,
        ?*const anyopaque,
    ) callconv(.c) VoidCookie,
};

var fns: Fns = undefined;
var g_loaded = false;

pub var conn: ?*Connection = null;
pub var screen: ?*Screen = null;

pub fn load() Error!void {
    if (g_loaded) return;
    const handle = dlopen("libxcb.so.1", RTLD_NOW) orelse return error.LibraryLoadFailed;
    inline for (@typeInfo(Fns).@"struct".fields) |field| {
        const sym = dlsym(handle, field.name) orelse return error.LibraryLoadFailed;
        @field(fns, field.name) = @ptrCast(@alignCast(sym));
    }
    g_loaded = true;
    std.debug.assert(g_loaded);
}

pub fn connect() Error!void {
    if (conn != null) return;
    try load();
    const c = fns.xcb_connect(null, null) orelse return error.ConnectFailed;
    // xcb_connect never returns null in practice; errors ride the connection.
    if (fns.xcb_connection_has_error(c) != 0) {
        fns.xcb_disconnect(c);
        return error.ConnectFailed;
    }
    const iter = fns.xcb_setup_roots_iterator(fns.xcb_get_setup(c));
    screen = iter.data orelse {
        fns.xcb_disconnect(c);
        return error.ConnectFailed;
    };
    conn = c;
}

pub fn disconnect() void {
    const c = conn orelse return;
    fns.xcb_disconnect(c);
    conn = null;
    screen = null;
}

pub fn generate_id() u32 {
    std.debug.assert(conn != null);
    return fns.xcb_generate_id(conn.?);
}

pub fn create_window(id: u32, width: u16, height: u16, back_pixel: u32) void {
    std.debug.assert(conn != null);
    std.debug.assert(width > 0);
    std.debug.assert(height > 0);
    // Value order follows the mask's bit order: BACK_PIXEL then EVENT_MASK.
    const values = [_]u32{
        back_pixel,
        EVENT_MASK_EXPOSURE | EVENT_MASK_STRUCTURE_NOTIFY,
    };
    _ = fns.xcb_create_window(
        conn.?,
        COPY_FROM_PARENT,
        id,
        screen.?.root,
        0,
        0,
        width,
        height,
        0,
        WINDOW_CLASS_INPUT_OUTPUT,
        screen.?.root_visual,
        CW_BACK_PIXEL | CW_EVENT_MASK,
        &values,
    );
}

pub fn destroy_window(id: u32) void {
    std.debug.assert(conn != null);
    std.debug.assert(id != 0);
    _ = fns.xcb_destroy_window(conn.?, id);
}

pub fn map_window(id: u32) void {
    std.debug.assert(conn != null);
    std.debug.assert(id != 0);
    _ = fns.xcb_map_window(conn.?, id);
}

pub fn flush() void {
    std.debug.assert(conn != null);
    _ = fns.xcb_flush(conn.?);
}

pub fn connection_fd() i32 {
    std.debug.assert(conn != null);
    return @intCast(fns.xcb_get_file_descriptor(conn.?));
}

// Caller owns the event and must release it with free_event.
pub fn poll_event() ?*GenericEvent {
    std.debug.assert(conn != null);
    return fns.xcb_poll_for_event(conn.?);
}

pub fn free_event(event: *GenericEvent) void {
    free(event);
}

// Synchronous: atoms are interned a handful of times at open, never per
// frame, so the roundtrip is the simple and sufficient shape.
pub fn intern_atom(name: []const u8) u32 {
    std.debug.assert(conn != null);
    std.debug.assert(name.len > 0);
    const cookie = fns.xcb_intern_atom(conn.?, 0, @intCast(name.len), name.ptr);
    const reply = fns.xcb_intern_atom_reply(conn.?, cookie, null) orelse return 0;
    const atom = reply.atom;
    free(reply);
    return atom;
}

pub fn change_property(
    window: u32,
    property: u32,
    property_type: u32,
    format: u8,
    data_len: u32,
    data: *const anyopaque,
) void {
    std.debug.assert(conn != null);
    std.debug.assert(format == 8 or format == 16 or format == 32);
    _ = fns.xcb_change_property(
        conn.?,
        PROP_MODE_REPLACE,
        window,
        property,
        property_type,
        format,
        data_len,
        data,
    );
}
