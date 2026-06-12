// libwayland-client binding (the objc.zig / win32.zig analogue). The library is
// loaded with dlopen at runtime - the d3dcompiler_47 precedent - so consumers
// need the distro runtime .so.0 only, never the -dev package. Interface tables
// are hand-built static data instead of wayland-scanner output: libwayland only
// reads them to marshal requests and demarshal events, so exact copies of the
// XML message lists work and keep the build free of codegen.

const std = @import("std");

pub const wl_proxy = opaque {};
pub const wl_display = opaque {};

pub const wl_message = extern struct {
    name: [*:0]const u8,
    signature: [*:0]const u8,
    types: ?[*]const ?*const wl_interface,
};

pub const wl_interface = extern struct {
    name: [*:0]const u8,
    version: c_int,
    method_count: c_int,
    methods: ?[*]const wl_message,
    event_count: c_int,
    events: ?[*]const wl_message,
};

pub const wl_argument = extern union {
    i: i32,
    u: u32,
    f: i32,
    s: ?[*:0]const u8,
    o: ?*wl_proxy,
    n: u32,
    a: ?*anyopaque,
    h: i32,
};

pub const wl_array = extern struct {
    size: usize,
    alloc: usize,
    data: ?*anyopaque,
};

pub const Error = error{ LibraryLoadFailed, ConnectFailed, MissingGlobal };

const MARSHAL_FLAG_DESTROY: u32 = 1;

extern "c" fn dlopen(file: [*:0]const u8, mode: c_int) ?*anyopaque;
extern "c" fn dlsym(handle: ?*anyopaque, name: [*:0]const u8) ?*anyopaque;
const RTLD_NOW: c_int = 2;

const Fns = struct {
    wl_display_connect: *const fn (?[*:0]const u8) callconv(.c) ?*wl_display,
    wl_display_disconnect: *const fn (*wl_display) callconv(.c) void,
    wl_display_roundtrip: *const fn (*wl_display) callconv(.c) c_int,
    wl_display_dispatch: *const fn (*wl_display) callconv(.c) c_int,
    wl_display_flush: *const fn (*wl_display) callconv(.c) c_int,
    wl_display_get_fd: *const fn (*wl_display) callconv(.c) c_int,
    wl_display_prepare_read: *const fn (*wl_display) callconv(.c) c_int,
    wl_display_read_events: *const fn (*wl_display) callconv(.c) c_int,
    wl_display_cancel_read: *const fn (*wl_display) callconv(.c) void,
    wl_display_dispatch_pending: *const fn (*wl_display) callconv(.c) c_int,
    wl_proxy_marshal_array_flags: *const fn (
        *wl_proxy,
        u32,
        ?*const wl_interface,
        u32,
        u32,
        ?[*]wl_argument,
    ) callconv(.c) ?*wl_proxy,
    wl_proxy_add_listener: *const fn (
        *wl_proxy,
        [*]const ?*const anyopaque,
        ?*anyopaque,
    ) callconv(.c) c_int,
    wl_proxy_destroy: *const fn (*wl_proxy) callconv(.c) void,
    wl_proxy_get_version: *const fn (*wl_proxy) callconv(.c) u32,
};

var fns: Fns = undefined;
var g_loaded: bool = false;

fn load() Error!void {
    if (g_loaded) return;
    std.debug.assert(@typeInfo(Fns).@"struct".fields.len >= 2);
    const handle = dlopen("libwayland-client.so.0", RTLD_NOW) orelse
        return error.LibraryLoadFailed;
    inline for (@typeInfo(Fns).@"struct".fields) |field| {
        const sym = dlsym(handle, field.name) orelse return error.LibraryLoadFailed;
        @field(fns, field.name) = @ptrCast(@alignCast(sym));
    }
    g_loaded = true;
    std.debug.assert(g_loaded);
}

// ---- interface tables (request/event lists copied from the protocol XML) ----

// Eight null slots cover the widest all-scalar message below; libwayland reads
// one entry per argument, so a shared oversized row is safe.
const null_types = [1]?*const wl_interface{null} ** 8;

pub const wl_callback_interface: wl_interface = .{
    .name = "wl_callback",
    .version = 1,
    .method_count = 0,
    .methods = null,
    .event_count = 1,
    .events = &[_]wl_message{
        .{ .name = "done", .signature = "u", .types = &null_types },
    },
};

pub const wl_registry_interface: wl_interface = .{
    .name = "wl_registry",
    .version = 1,
    .method_count = 1,
    .methods = &[_]wl_message{
        .{ .name = "bind", .signature = "usun", .types = &null_types },
    },
    .event_count = 2,
    .events = &[_]wl_message{
        .{ .name = "global", .signature = "usu", .types = &null_types },
        .{ .name = "global_remove", .signature = "u", .types = &null_types },
    },
};

// Referenced only as argument types by messages below; nothing is marshalled
// through these, so their method/event tables stay empty.
pub const wl_region_interface: wl_interface = .{
    .name = "wl_region",
    .version = 1,
    .method_count = 0,
    .methods = null,
    .event_count = 0,
    .events = null,
};
pub const wl_output_interface: wl_interface = .{
    .name = "wl_output",
    .version = 4,
    .method_count = 1,
    .methods = &[_]wl_message{
        .{ .name = "release", .signature = "3", .types = &null_types },
    },
    .event_count = 6,
    .events = &[_]wl_message{
        .{ .name = "geometry", .signature = "iiiiissi", .types = &null_types },
        .{ .name = "mode", .signature = "uiii", .types = &null_types },
        .{ .name = "done", .signature = "2", .types = &null_types },
        .{ .name = "scale", .signature = "2i", .types = &null_types },
        .{ .name = "name", .signature = "4s", .types = &null_types },
        .{ .name = "description", .signature = "4s", .types = &null_types },
    },
};
pub const wl_seat_interface: wl_interface = .{
    .name = "wl_seat",
    .version = 9,
    .method_count = 0,
    .methods = null,
    .event_count = 0,
    .events = null,
};
pub const wl_touch_interface: wl_interface = .{
    .name = "wl_touch",
    .version = 5,
    .method_count = 0,
    .methods = null,
    .event_count = 0,
    .events = null,
};
pub const xdg_positioner_interface: wl_interface = .{
    .name = "xdg_positioner",
    .version = 6,
    .method_count = 0,
    .methods = null,
    .event_count = 0,
    .events = null,
};
pub const xdg_popup_interface: wl_interface = .{
    .name = "xdg_popup",
    .version = 6,
    .method_count = 0,
    .methods = null,
    .event_count = 0,
    .events = null,
};

pub const wl_compositor_interface: wl_interface = .{
    .name = "wl_compositor",
    .version = 4,
    .method_count = 2,
    .methods = &[_]wl_message{
        .{
            .name = "create_surface",
            .signature = "n",
            .types = &[_]?*const wl_interface{&wl_surface_interface},
        },
        .{
            .name = "create_region",
            .signature = "n",
            .types = &[_]?*const wl_interface{&wl_region_interface},
        },
    },
    .event_count = 0,
    .events = null,
};

pub const wl_surface_interface: wl_interface = .{
    .name = "wl_surface",
    .version = 6,
    .method_count = 11,
    .methods = &[_]wl_message{
        .{ .name = "destroy", .signature = "", .types = &null_types },
        .{
            .name = "attach",
            .signature = "?oii",
            .types = &[_]?*const wl_interface{ &wl_buffer_interface, null, null },
        },
        .{ .name = "damage", .signature = "iiii", .types = &null_types },
        .{
            .name = "frame",
            .signature = "n",
            .types = &[_]?*const wl_interface{&wl_callback_interface},
        },
        .{
            .name = "set_opaque_region",
            .signature = "?o",
            .types = &[_]?*const wl_interface{&wl_region_interface},
        },
        .{
            .name = "set_input_region",
            .signature = "?o",
            .types = &[_]?*const wl_interface{&wl_region_interface},
        },
        .{ .name = "commit", .signature = "", .types = &null_types },
        .{ .name = "set_buffer_transform", .signature = "2i", .types = &null_types },
        .{ .name = "set_buffer_scale", .signature = "3i", .types = &null_types },
        .{ .name = "damage_buffer", .signature = "4iiii", .types = &null_types },
        .{ .name = "offset", .signature = "5ii", .types = &null_types },
    },
    .event_count = 4,
    .events = &[_]wl_message{
        .{
            .name = "enter",
            .signature = "o",
            .types = &[_]?*const wl_interface{&wl_output_interface},
        },
        .{
            .name = "leave",
            .signature = "o",
            .types = &[_]?*const wl_interface{&wl_output_interface},
        },
        .{ .name = "preferred_buffer_scale", .signature = "6i", .types = &null_types },
        .{ .name = "preferred_buffer_transform", .signature = "6u", .types = &null_types },
    },
};

pub const wl_shm_interface: wl_interface = .{
    .name = "wl_shm",
    .version = 1,
    .method_count = 1,
    .methods = &[_]wl_message{
        .{
            .name = "create_pool",
            .signature = "nhi",
            .types = &[_]?*const wl_interface{ &wl_shm_pool_interface, null, null },
        },
    },
    .event_count = 1,
    .events = &[_]wl_message{
        .{ .name = "format", .signature = "u", .types = &null_types },
    },
};

pub const wl_shm_pool_interface: wl_interface = .{
    .name = "wl_shm_pool",
    .version = 1,
    .method_count = 3,
    .methods = &[_]wl_message{
        .{
            .name = "create_buffer",
            .signature = "niiiiu",
            .types = &[_]?*const wl_interface{ &wl_buffer_interface, null, null, null, null, null },
        },
        .{ .name = "destroy", .signature = "", .types = &null_types },
        .{ .name = "resize", .signature = "i", .types = &null_types },
    },
    .event_count = 0,
    .events = null,
};

pub const wl_buffer_interface: wl_interface = .{
    .name = "wl_buffer",
    .version = 1,
    .method_count = 1,
    .methods = &[_]wl_message{
        .{ .name = "destroy", .signature = "", .types = &null_types },
    },
    .event_count = 1,
    .events = &[_]wl_message{
        .{ .name = "release", .signature = "", .types = &null_types },
    },
};

pub const wl_seat_input_interface: wl_interface = .{
    .name = "wl_seat",
    .version = 5,
    .method_count = 4,
    .methods = &[_]wl_message{
        .{
            .name = "get_pointer",
            .signature = "n",
            .types = &[_]?*const wl_interface{&wl_pointer_interface},
        },
        .{
            .name = "get_keyboard",
            .signature = "n",
            .types = &[_]?*const wl_interface{&wl_keyboard_interface},
        },
        .{
            .name = "get_touch",
            .signature = "n",
            .types = &[_]?*const wl_interface{&wl_touch_interface},
        },
        .{ .name = "release", .signature = "5", .types = &null_types },
    },
    .event_count = 2,
    .events = &[_]wl_message{
        .{ .name = "capabilities", .signature = "u", .types = &null_types },
        .{ .name = "name", .signature = "2s", .types = &null_types },
    },
};

pub const wl_pointer_interface: wl_interface = .{
    .name = "wl_pointer",
    .version = 5,
    .method_count = 2,
    .methods = &[_]wl_message{
        .{
            .name = "set_cursor",
            .signature = "u?oii",
            .types = &[_]?*const wl_interface{ null, &wl_surface_interface, null, null },
        },
        .{ .name = "release", .signature = "3", .types = &null_types },
    },
    .event_count = 9,
    .events = &[_]wl_message{
        .{
            .name = "enter",
            .signature = "uoff",
            .types = &[_]?*const wl_interface{ null, &wl_surface_interface, null, null },
        },
        .{
            .name = "leave",
            .signature = "uo",
            .types = &[_]?*const wl_interface{ null, &wl_surface_interface },
        },
        .{ .name = "motion", .signature = "uff", .types = &null_types },
        .{ .name = "button", .signature = "uuuu", .types = &null_types },
        .{ .name = "axis", .signature = "uuf", .types = &null_types },
        .{ .name = "frame", .signature = "5", .types = &null_types },
        .{ .name = "axis_source", .signature = "5u", .types = &null_types },
        .{ .name = "axis_stop", .signature = "5uu", .types = &null_types },
        .{ .name = "axis_discrete", .signature = "5ui", .types = &null_types },
    },
};

pub const wl_keyboard_interface: wl_interface = .{
    .name = "wl_keyboard",
    .version = 5,
    .method_count = 1,
    .methods = &[_]wl_message{
        .{ .name = "release", .signature = "3", .types = &null_types },
    },
    .event_count = 6,
    .events = &[_]wl_message{
        .{ .name = "keymap", .signature = "uhu", .types = &null_types },
        .{
            .name = "enter",
            .signature = "uoa",
            .types = &[_]?*const wl_interface{ null, &wl_surface_interface, null },
        },
        .{
            .name = "leave",
            .signature = "uo",
            .types = &[_]?*const wl_interface{ null, &wl_surface_interface },
        },
        .{ .name = "key", .signature = "uuuu", .types = &null_types },
        .{ .name = "modifiers", .signature = "uuuuu", .types = &null_types },
        .{ .name = "repeat_info", .signature = "4ii", .types = &null_types },
    },
};

pub const xdg_wm_base_interface: wl_interface = .{
    .name = "xdg_wm_base",
    .version = 6,
    .method_count = 4,
    .methods = &[_]wl_message{
        .{ .name = "destroy", .signature = "", .types = &null_types },
        .{
            .name = "create_positioner",
            .signature = "n",
            .types = &[_]?*const wl_interface{&xdg_positioner_interface},
        },
        .{
            .name = "get_xdg_surface",
            .signature = "no",
            .types = &[_]?*const wl_interface{ &xdg_surface_interface, &wl_surface_interface },
        },
        .{ .name = "pong", .signature = "u", .types = &null_types },
    },
    .event_count = 1,
    .events = &[_]wl_message{
        .{ .name = "ping", .signature = "u", .types = &null_types },
    },
};

pub const xdg_surface_interface: wl_interface = .{
    .name = "xdg_surface",
    .version = 6,
    .method_count = 5,
    .methods = &[_]wl_message{
        .{ .name = "destroy", .signature = "", .types = &null_types },
        .{
            .name = "get_toplevel",
            .signature = "n",
            .types = &[_]?*const wl_interface{&xdg_toplevel_interface},
        },
        .{
            .name = "get_popup",
            .signature = "n?oo",
            .types = &[_]?*const wl_interface{
                &xdg_popup_interface,
                &xdg_surface_interface,
                &xdg_positioner_interface,
            },
        },
        .{ .name = "set_window_geometry", .signature = "iiii", .types = &null_types },
        .{ .name = "ack_configure", .signature = "u", .types = &null_types },
    },
    .event_count = 1,
    .events = &[_]wl_message{
        .{ .name = "configure", .signature = "u", .types = &null_types },
    },
};

pub const xdg_toplevel_interface: wl_interface = .{
    .name = "xdg_toplevel",
    .version = 6,
    .method_count = 14,
    .methods = &[_]wl_message{
        .{ .name = "destroy", .signature = "", .types = &null_types },
        .{
            .name = "set_parent",
            .signature = "?o",
            .types = &[_]?*const wl_interface{&xdg_toplevel_interface},
        },
        .{ .name = "set_title", .signature = "s", .types = &null_types },
        .{ .name = "set_app_id", .signature = "s", .types = &null_types },
        .{
            .name = "show_window_menu",
            .signature = "ouii",
            .types = &[_]?*const wl_interface{ &wl_seat_interface, null, null, null },
        },
        .{
            .name = "move",
            .signature = "ou",
            .types = &[_]?*const wl_interface{ &wl_seat_interface, null },
        },
        .{
            .name = "resize",
            .signature = "ouu",
            .types = &[_]?*const wl_interface{ &wl_seat_interface, null, null },
        },
        .{ .name = "set_max_size", .signature = "ii", .types = &null_types },
        .{ .name = "set_min_size", .signature = "ii", .types = &null_types },
        .{ .name = "set_maximized", .signature = "", .types = &null_types },
        .{ .name = "unset_maximized", .signature = "", .types = &null_types },
        .{
            .name = "set_fullscreen",
            .signature = "?o",
            .types = &[_]?*const wl_interface{&wl_output_interface},
        },
        .{ .name = "unset_fullscreen", .signature = "", .types = &null_types },
        .{ .name = "set_minimized", .signature = "", .types = &null_types },
    },
    .event_count = 4,
    .events = &[_]wl_message{
        .{ .name = "configure", .signature = "iia", .types = &null_types },
        .{ .name = "close", .signature = "", .types = &null_types },
        .{ .name = "configure_bounds", .signature = "4ii", .types = &null_types },
        .{ .name = "wm_capabilities", .signature = "5a", .types = &null_types },
    },
};

// ---- connection (process singleton: one Wayland display per process, the
// windows loop.zig pattern; callbacks have no instance to thread state through) ----

pub const Connection = struct {
    display: ?*wl_display = null,
    compositor: ?*wl_proxy = null,
    shm: ?*wl_proxy = null,
    wm_base: ?*wl_proxy = null,
    seat: ?*wl_proxy = null,
    // Optional globals: absent on compositors without the protocol (or, for
    // the seat-bound ones, on seatless headless sessions). Consumers degrade.
    pointer_constraints: ?*wl_proxy = null,
    relative_pointer_manager: ?*wl_proxy = null,
    data_device_manager: ?*wl_proxy = null,
};

pub var conn: Connection = .{};
var g_registry: ?*wl_proxy = null;
// Mirrors windows loop.zig quitting: set by the close path, read by run_forever.
pub var quit_requested: bool = false;

pub const WL_SHM_FORMAT_XRGB8888: u32 = 1;

const WL_DISPLAY_GET_REGISTRY: u32 = 1;
const WL_REGISTRY_BIND: u32 = 0;
const WL_COMPOSITOR_CREATE_SURFACE: u32 = 0;
const WL_SURFACE_DESTROY: u32 = 0;
const WL_SURFACE_ATTACH: u32 = 1;
const WL_SURFACE_DAMAGE: u32 = 2;
const WL_SURFACE_COMMIT: u32 = 6;
const WL_SHM_CREATE_POOL: u32 = 0;
const WL_SHM_POOL_CREATE_BUFFER: u32 = 0;
const WL_SHM_POOL_DESTROY: u32 = 1;
const WL_BUFFER_DESTROY: u32 = 0;
const XDG_WM_BASE_GET_XDG_SURFACE: u32 = 2;
const XDG_WM_BASE_PONG: u32 = 3;
const XDG_SURFACE_DESTROY: u32 = 0;
const XDG_SURFACE_GET_TOPLEVEL: u32 = 1;
const XDG_SURFACE_ACK_CONFIGURE: u32 = 4;
const XDG_TOPLEVEL_DESTROY: u32 = 0;
const XDG_TOPLEVEL_SET_TITLE: u32 = 2;
const XDG_TOPLEVEL_SET_APP_ID: u32 = 3;
const WL_SEAT_GET_POINTER: u32 = 0;
const WL_SEAT_GET_KEYBOARD: u32 = 1;
const WL_POINTER_SET_CURSOR: u32 = 0;
const XDG_TOPLEVEL_MOVE: u32 = 5;
const XDG_TOPLEVEL_RESIZE: u32 = 6;
const XDG_TOPLEVEL_SET_MIN_SIZE: u32 = 8;
const XDG_TOPLEVEL_SET_MAXIMIZED: u32 = 9;
const XDG_TOPLEVEL_UNSET_MAXIMIZED: u32 = 10;
const XDG_TOPLEVEL_SET_MINIMIZED: u32 = 13;
const XDG_TOPLEVEL_SET_FULLSCREEN: u32 = 11;
const XDG_TOPLEVEL_UNSET_FULLSCREEN: u32 = 12;

const COMPOSITOR_BIND_VERSION: u32 = 4;
const SHM_BIND_VERSION: u32 = 1;
const WM_BASE_BIND_VERSION: u32 = 1;
const SEAT_BIND_VERSION: u32 = 5;
const OUTPUT_BIND_VERSION: u32 = 4;

// ---- outputs (display enumeration) ----

pub const MAX_OUTPUTS: u32 = 16;
const WL_OUTPUT_MODE_CURRENT: u32 = 1;

// Geometry/mode/scale accumulate across events; an entry is usable once the
// current mode has arrived (mode_w > 0). x/y are the output's position in the
// compositor's global logical space, the cross-platform "points" origin.
pub const OutputInfo = struct {
    proxy: ?*wl_proxy = null,
    registry_name: u32 = 0,
    x: i32 = 0,
    y: i32 = 0,
    mode_w: i32 = 0,
    mode_h: i32 = 0,
    transform: i32 = 0,
    scale: i32 = 1,
};

pub var outputs: [MAX_OUTPUTS]OutputInfo = [_]OutputInfo{.{}} ** MAX_OUTPUTS;

const OutputListener = extern struct {
    geometry: *const fn (
        ?*anyopaque,
        ?*wl_proxy,
        i32,
        i32,
        i32,
        i32,
        i32,
        ?[*:0]const u8,
        ?[*:0]const u8,
        i32,
    ) callconv(.c) void,
    mode: *const fn (?*anyopaque, ?*wl_proxy, u32, i32, i32, i32) callconv(.c) void,
    done: *const fn (?*anyopaque, ?*wl_proxy) callconv(.c) void,
    scale: *const fn (?*anyopaque, ?*wl_proxy, i32) callconv(.c) void,
    name: *const fn (?*anyopaque, ?*wl_proxy, ?[*:0]const u8) callconv(.c) void,
    description: *const fn (?*anyopaque, ?*wl_proxy, ?[*:0]const u8) callconv(.c) void,
};

const output_listener = OutputListener{
    .geometry = on_output_geometry,
    .mode = on_output_mode,
    .done = on_output_done,
    .scale = on_output_scale,
    .name = on_output_name,
    .description = on_output_description,
};

fn on_output_geometry(
    data: ?*anyopaque,
    output: ?*wl_proxy,
    x: i32,
    y: i32,
    phys_w: i32,
    phys_h: i32,
    subpixel: i32,
    make: ?[*:0]const u8,
    model: ?[*:0]const u8,
    transform: i32,
) callconv(.c) void {
    _ = output;
    _ = phys_w;
    _ = phys_h;
    _ = subpixel;
    _ = make;
    _ = model;
    const info: *OutputInfo = @ptrCast(@alignCast(data.?));
    info.x = x;
    info.y = y;
    info.transform = transform;
}

fn on_output_mode(
    data: ?*anyopaque,
    output: ?*wl_proxy,
    flags: u32,
    width: i32,
    height: i32,
    refresh: i32,
) callconv(.c) void {
    _ = output;
    _ = refresh;
    if (flags & WL_OUTPUT_MODE_CURRENT == 0) return;
    std.debug.assert(width > 0);
    std.debug.assert(height > 0);
    const info: *OutputInfo = @ptrCast(@alignCast(data.?));
    info.mode_w = width;
    info.mode_h = height;
}

fn on_output_done(data: ?*anyopaque, output: ?*wl_proxy) callconv(.c) void {
    _ = data;
    std.debug.assert(output != null);
}

fn on_output_scale(data: ?*anyopaque, output: ?*wl_proxy, factor: i32) callconv(.c) void {
    _ = output;
    std.debug.assert(factor >= 1);
    const info: *OutputInfo = @ptrCast(@alignCast(data.?));
    info.scale = factor;
}

fn on_output_name(data: ?*anyopaque, output: ?*wl_proxy, name_z: ?[*:0]const u8) callconv(.c) void {
    _ = data;
    _ = name_z;
    std.debug.assert(output != null);
}

fn on_output_description(
    data: ?*anyopaque,
    output: ?*wl_proxy,
    description_z: ?[*:0]const u8,
) callconv(.c) void {
    _ = data;
    _ = description_z;
    std.debug.assert(output != null);
}

fn bind_output(registry: *wl_proxy, name: u32, version: u32) void {
    std.debug.assert(version >= 1);
    for (&outputs) |*slot| {
        if (slot.proxy != null) continue;
        const proxy = registry_bind(
            registry,
            name,
            &wl_output_interface,
            @min(version, OUTPUT_BIND_VERSION),
        ) orelse return;
        slot.* = .{ .proxy = proxy, .registry_name = name };
        add_listener(proxy, &output_listener, slot);
        return;
    }
    // More outputs than slots: the extras are ignored, never an error.
}

fn remove_output(name: u32) void {
    for (&outputs) |*slot| {
        if (slot.proxy == null or slot.registry_name != name) continue;
        fns.wl_proxy_destroy(slot.proxy.?);
        slot.* = .{};
        return;
    }
}

pub fn connect() Error!void {
    if (conn.display != null) return;
    try load();
    std.debug.assert(g_loaded);
    const display = fns.wl_display_connect(null) orelse return error.ConnectFailed;
    conn.display = display;
    const display_proxy: *wl_proxy = @ptrCast(display);
    var registry_args = [_]wl_argument{.{ .n = 0 }};
    const registry = marshal_constructor(
        display_proxy,
        WL_DISPLAY_GET_REGISTRY,
        &wl_registry_interface,
        &registry_args,
    ) orelse return error.ConnectFailed;
    g_registry = registry;
    add_listener(registry, &registry_listener, null);
    // One roundtrip delivers every advertised global; the handler binds ours.
    _ = fns.wl_display_roundtrip(display);
    if (conn.compositor == null) return error.MissingGlobal;
    if (conn.shm == null) return error.MissingGlobal;
    if (conn.wm_base == null) return error.MissingGlobal;
}

pub fn dispatch() i32 {
    std.debug.assert(g_loaded);
    std.debug.assert(conn.display != null);
    return @intCast(fns.wl_display_dispatch(conn.display.?));
}

pub fn roundtrip() void {
    std.debug.assert(g_loaded);
    std.debug.assert(conn.display != null);
    _ = fns.wl_display_roundtrip(conn.display.?);
}

pub fn flush() void {
    std.debug.assert(g_loaded);
    std.debug.assert(conn.display != null);
    _ = fns.wl_display_flush(conn.display.?);
}

pub fn disconnect() void {
    std.debug.assert(g_loaded);
    const display = conn.display orelse return;
    if (g_registry) |registry| fns.wl_proxy_destroy(registry);
    fns.wl_display_disconnect(display);
    conn = .{};
    g_registry = null;
    std.debug.assert(conn.display == null);
}

pub fn add_listener(proxy: *wl_proxy, listener: *const anyopaque, data: ?*anyopaque) void {
    std.debug.assert(g_loaded);
    const implementation: [*]const ?*const anyopaque = @ptrCast(@alignCast(listener));
    const rc = fns.wl_proxy_add_listener(proxy, implementation, data);
    std.debug.assert(rc == 0); // fails only when a listener was already set
}

fn marshal(proxy: *wl_proxy, opcode: u32, args: ?[*]wl_argument) void {
    std.debug.assert(g_loaded);
    const version = fns.wl_proxy_get_version(proxy);
    const created = fns.wl_proxy_marshal_array_flags(proxy, opcode, null, version, 0, args);
    std.debug.assert(created == null);
}

fn marshal_constructor(
    proxy: *wl_proxy,
    opcode: u32,
    interface: *const wl_interface,
    args: ?[*]wl_argument,
) ?*wl_proxy {
    std.debug.assert(g_loaded);
    std.debug.assert(interface.name[0] != 0);
    const version = fns.wl_proxy_get_version(proxy);
    return fns.wl_proxy_marshal_array_flags(proxy, opcode, interface, version, 0, args);
}

fn marshal_destructor(proxy: *wl_proxy, opcode: u32) void {
    std.debug.assert(g_loaded);
    const version = fns.wl_proxy_get_version(proxy);
    const created = fns.wl_proxy_marshal_array_flags(
        proxy,
        opcode,
        null,
        version,
        MARSHAL_FLAG_DESTROY,
        null,
    );
    std.debug.assert(created == null);
}

const RegistryListener = extern struct {
    global: *const fn (?*anyopaque, ?*wl_proxy, u32, ?[*:0]const u8, u32) callconv(.c) void,
    global_remove: *const fn (?*anyopaque, ?*wl_proxy, u32) callconv(.c) void,
};

const registry_listener = RegistryListener{
    .global = on_registry_global,
    .global_remove = on_registry_global_remove,
};

fn on_registry_global(
    data: ?*anyopaque,
    registry: ?*wl_proxy,
    name: u32,
    interface_z: ?[*:0]const u8,
    version: u32,
) callconv(.c) void {
    _ = data;
    std.debug.assert(registry != null);
    std.debug.assert(interface_z != null);
    const interface_name = std.mem.span(interface_z.?);
    if (std.mem.eql(u8, interface_name, "wl_compositor")) {
        const bind_version = @min(version, COMPOSITOR_BIND_VERSION);
        conn.compositor = registry_bind(registry.?, name, &wl_compositor_interface, bind_version);
    } else if (std.mem.eql(u8, interface_name, "wl_shm")) {
        conn.shm = registry_bind(registry.?, name, &wl_shm_interface, SHM_BIND_VERSION);
    } else if (std.mem.eql(u8, interface_name, "wl_seat")) {
        const bind_version = @min(version, SEAT_BIND_VERSION);
        conn.seat = registry_bind(registry.?, name, &wl_seat_input_interface, bind_version);
    } else if (std.mem.eql(u8, interface_name, "xdg_wm_base")) {
        const bind_version = @min(version, WM_BASE_BIND_VERSION);
        const wm_base = registry_bind(registry.?, name, &xdg_wm_base_interface, bind_version);
        conn.wm_base = wm_base;
        if (wm_base) |base| add_listener(base, &wm_base_listener, null);
    } else if (std.mem.eql(u8, interface_name, "wl_output")) {
        bind_output(registry.?, name, version);
    } else if (std.mem.eql(u8, interface_name, "zwp_pointer_constraints_v1")) {
        conn.pointer_constraints =
            registry_bind(registry.?, name, &zwp_pointer_constraints_v1_interface, 1);
    } else if (std.mem.eql(u8, interface_name, "zwp_relative_pointer_manager_v1")) {
        conn.relative_pointer_manager =
            registry_bind(registry.?, name, &zwp_relative_pointer_manager_v1_interface, 1);
    } else if (std.mem.eql(u8, interface_name, "wl_data_device_manager")) {
        // v1 is all the clipboard needs; higher versions only add DND actions.
        conn.data_device_manager =
            registry_bind(registry.?, name, &wl_data_device_manager_interface, 1);
    }
}

fn on_registry_global_remove(data: ?*anyopaque, registry: ?*wl_proxy, name: u32) callconv(.c) void {
    _ = data;
    // Outputs come and go with monitor hotplug; the other bound globals
    // (compositor/shm/wm_base/seat) never go away on a live session.
    std.debug.assert(registry != null);
    remove_output(name);
}

fn registry_bind(
    registry: *wl_proxy,
    name: u32,
    interface: *const wl_interface,
    version: u32,
) ?*wl_proxy {
    std.debug.assert(g_loaded);
    std.debug.assert(version >= 1);
    var args = [_]wl_argument{
        .{ .u = name },
        .{ .s = interface.name },
        .{ .u = version },
        .{ .n = 0 },
    };
    const bind = WL_REGISTRY_BIND;
    return fns.wl_proxy_marshal_array_flags(registry, bind, interface, version, 0, &args);
}

const WmBaseListener = extern struct {
    ping: *const fn (?*anyopaque, ?*wl_proxy, u32) callconv(.c) void,
};

const wm_base_listener = WmBaseListener{ .ping = on_wm_base_ping };

// Unanswered pings get the client killed as unresponsive, so pong lives here,
// invisible to the shell layer.
fn on_wm_base_ping(data: ?*anyopaque, wm_base: ?*wl_proxy, serial: u32) callconv(.c) void {
    _ = data;
    std.debug.assert(wm_base != null);
    std.debug.assert(conn.wm_base == wm_base);
    var args = [_]wl_argument{.{ .u = serial }};
    marshal(wm_base.?, XDG_WM_BASE_PONG, &args);
}

// ---- typed request wrappers ----

pub fn compositor_create_surface() ?*wl_proxy {
    std.debug.assert(g_loaded);
    const compositor = conn.compositor orelse return null;
    var args = [_]wl_argument{.{ .n = 0 }};
    const op = WL_COMPOSITOR_CREATE_SURFACE;
    return marshal_constructor(compositor, op, &wl_surface_interface, &args);
}

pub fn surface_attach(surface: *wl_proxy, buffer: ?*wl_proxy, x: i32, y: i32) void {
    std.debug.assert(x == 0); // non-zero attach offsets are a deprecated protocol path
    std.debug.assert(y == 0);
    var args = [_]wl_argument{ .{ .o = buffer }, .{ .i = x }, .{ .i = y } };
    marshal(surface, WL_SURFACE_ATTACH, &args);
}

pub fn surface_damage(surface: *wl_proxy, x: i32, y: i32, w: i32, h: i32) void {
    std.debug.assert(w > 0);
    std.debug.assert(h > 0);
    var args = [_]wl_argument{ .{ .i = x }, .{ .i = y }, .{ .i = w }, .{ .i = h } };
    marshal(surface, WL_SURFACE_DAMAGE, &args);
}

pub fn surface_commit(surface: *wl_proxy) void {
    marshal(surface, WL_SURFACE_COMMIT, null);
}

pub fn surface_destroy(surface: *wl_proxy) void {
    marshal_destructor(surface, WL_SURFACE_DESTROY);
}

pub fn shm_create_pool(fd: i32, size: i32) ?*wl_proxy {
    std.debug.assert(fd >= 0);
    std.debug.assert(size > 0);
    const shm = conn.shm orelse return null;
    var args = [_]wl_argument{ .{ .n = 0 }, .{ .h = fd }, .{ .i = size } };
    return marshal_constructor(shm, WL_SHM_CREATE_POOL, &wl_shm_pool_interface, &args);
}

pub fn shm_pool_create_buffer(
    pool: *wl_proxy,
    offset: i32,
    width: i32,
    height: i32,
    stride: i32,
    format: u32,
) ?*wl_proxy {
    std.debug.assert(offset >= 0);
    std.debug.assert(width > 0);
    std.debug.assert(height > 0);
    std.debug.assert(stride >= width * 4);
    var args = [_]wl_argument{
        .{ .n = 0 },
        .{ .i = offset },
        .{ .i = width },
        .{ .i = height },
        .{ .i = stride },
        .{ .u = format },
    };
    return marshal_constructor(pool, WL_SHM_POOL_CREATE_BUFFER, &wl_buffer_interface, &args);
}

pub fn shm_pool_destroy(pool: *wl_proxy) void {
    marshal_destructor(pool, WL_SHM_POOL_DESTROY);
}

pub fn buffer_destroy(buffer: *wl_proxy) void {
    marshal_destructor(buffer, WL_BUFFER_DESTROY);
}

pub fn wm_base_get_xdg_surface(surface: *wl_proxy) ?*wl_proxy {
    std.debug.assert(g_loaded);
    const wm_base = conn.wm_base orelse return null;
    var args = [_]wl_argument{ .{ .n = 0 }, .{ .o = surface } };
    return marshal_constructor(wm_base, XDG_WM_BASE_GET_XDG_SURFACE, &xdg_surface_interface, &args);
}

pub fn xdg_surface_get_toplevel(xdg_surface: *wl_proxy) ?*wl_proxy {
    std.debug.assert(g_loaded);
    var args = [_]wl_argument{.{ .n = 0 }};
    const op = XDG_SURFACE_GET_TOPLEVEL;
    return marshal_constructor(xdg_surface, op, &xdg_toplevel_interface, &args);
}

pub fn xdg_surface_ack_configure(xdg_surface: *wl_proxy, serial: u32) void {
    var args = [_]wl_argument{.{ .u = serial }};
    marshal(xdg_surface, XDG_SURFACE_ACK_CONFIGURE, &args);
}

pub fn xdg_surface_destroy(xdg_surface: *wl_proxy) void {
    marshal_destructor(xdg_surface, XDG_SURFACE_DESTROY);
}

pub fn toplevel_set_title(toplevel: *wl_proxy, title: [*:0]const u8) void {
    var args = [_]wl_argument{.{ .s = title }};
    marshal(toplevel, XDG_TOPLEVEL_SET_TITLE, &args);
}

pub fn toplevel_set_app_id(toplevel: *wl_proxy, app_id: [*:0]const u8) void {
    var args = [_]wl_argument{.{ .s = app_id }};
    marshal(toplevel, XDG_TOPLEVEL_SET_APP_ID, &args);
}

pub fn toplevel_set_min_size(toplevel: *wl_proxy, width: i32, height: i32) void {
    std.debug.assert(width >= 0);
    std.debug.assert(height >= 0);
    var args = [_]wl_argument{ .{ .i = width }, .{ .i = height } };
    marshal(toplevel, XDG_TOPLEVEL_SET_MIN_SIZE, &args);
}

pub fn toplevel_set_fullscreen(toplevel: *wl_proxy, on: bool) void {
    std.debug.assert(g_loaded);
    std.debug.assert(conn.display != null);
    if (on) {
        var args = [_]wl_argument{.{ .o = null }}; // null output: compositor picks
        marshal(toplevel, XDG_TOPLEVEL_SET_FULLSCREEN, &args);
    } else {
        marshal(toplevel, XDG_TOPLEVEL_UNSET_FULLSCREEN, null);
    }
}

pub fn toplevel_destroy(toplevel: *wl_proxy) void {
    marshal_destructor(toplevel, XDG_TOPLEVEL_DESTROY);
}

pub fn toplevel_move(toplevel: *wl_proxy, seat: *wl_proxy, serial: u32) void {
    std.debug.assert(serial != 0);
    var args = [_]wl_argument{ .{ .o = seat }, .{ .u = serial } };
    marshal(toplevel, XDG_TOPLEVEL_MOVE, &args);
}

pub fn toplevel_resize(toplevel: *wl_proxy, seat: *wl_proxy, serial: u32, edges: u32) void {
    std.debug.assert(serial != 0);
    std.debug.assert(edges >= 1);
    std.debug.assert(edges <= 10);
    var args = [_]wl_argument{ .{ .o = seat }, .{ .u = serial }, .{ .u = edges } };
    marshal(toplevel, XDG_TOPLEVEL_RESIZE, &args);
}

pub fn toplevel_set_maximized(toplevel: *wl_proxy, on: bool) void {
    std.debug.assert(g_loaded);
    if (on) {
        marshal(toplevel, XDG_TOPLEVEL_SET_MAXIMIZED, null);
    } else {
        marshal(toplevel, XDG_TOPLEVEL_UNSET_MAXIMIZED, null);
    }
}

pub fn toplevel_set_minimized(toplevel: *wl_proxy) void {
    std.debug.assert(g_loaded);
    marshal(toplevel, XDG_TOPLEVEL_SET_MINIMIZED, null);
}

pub fn seat_get_pointer(seat: *wl_proxy) ?*wl_proxy {
    std.debug.assert(g_loaded);
    var args = [_]wl_argument{.{ .n = 0 }};
    return marshal_constructor(seat, WL_SEAT_GET_POINTER, &wl_pointer_interface, &args);
}

pub fn seat_get_keyboard(seat: *wl_proxy) ?*wl_proxy {
    std.debug.assert(g_loaded);
    var args = [_]wl_argument{.{ .n = 0 }};
    return marshal_constructor(seat, WL_SEAT_GET_KEYBOARD, &wl_keyboard_interface, &args);
}

pub fn pointer_set_cursor(
    pointer: *wl_proxy,
    serial: u32,
    surface: ?*wl_proxy,
    hotspot_x: i32,
    hotspot_y: i32,
) void {
    std.debug.assert(serial != 0);
    std.debug.assert(hotspot_x >= 0);
    std.debug.assert(hotspot_y >= 0);
    var args = [_]wl_argument{
        .{ .u = serial },
        .{ .o = surface },
        .{ .i = hotspot_x },
        .{ .i = hotspot_y },
    };
    marshal(pointer, WL_POINTER_SET_CURSOR, &args);
}

pub fn display_fd() i32 {
    std.debug.assert(g_loaded);
    std.debug.assert(conn.display != null);
    return @intCast(fns.wl_display_get_fd(conn.display.?));
}

// The poll-loop read protocol: prepare_read fails while events are queued, so
// drain first; the caller then polls the fd and finishes with read or cancel.
pub fn prepare_read() bool {
    std.debug.assert(g_loaded);
    const display = conn.display.?;
    var guard: u32 = 0;
    while (fns.wl_display_prepare_read(display) != 0) : (guard += 1) {
        std.debug.assert(guard < 1024);
        if (fns.wl_display_dispatch_pending(display) < 0) return false;
    }
    return true;
}

pub fn read_events() void {
    std.debug.assert(g_loaded);
    _ = fns.wl_display_read_events(conn.display.?);
    _ = fns.wl_display_dispatch_pending(conn.display.?);
}

pub fn cancel_read() void {
    std.debug.assert(g_loaded);
    fns.wl_display_cancel_read(conn.display.?);
}

// ---- pointer constraints + relative pointer (grab) ----

pub const zwp_locked_pointer_v1_interface: wl_interface = .{
    .name = "zwp_locked_pointer_v1",
    .version = 1,
    .method_count = 3,
    .methods = &[_]wl_message{
        .{ .name = "destroy", .signature = "", .types = &null_types },
        .{ .name = "set_cursor_position_hint", .signature = "ff", .types = &null_types },
        .{
            .name = "set_region",
            .signature = "?o",
            .types = &[_]?*const wl_interface{&wl_region_interface},
        },
    },
    .event_count = 2,
    .events = &[_]wl_message{
        .{ .name = "locked", .signature = "", .types = &null_types },
        .{ .name = "unlocked", .signature = "", .types = &null_types },
    },
};

pub const zwp_confined_pointer_v1_interface: wl_interface = .{
    .name = "zwp_confined_pointer_v1",
    .version = 1,
    .method_count = 0,
    .methods = null,
    .event_count = 0,
    .events = null,
};

pub const zwp_pointer_constraints_v1_interface: wl_interface = .{
    .name = "zwp_pointer_constraints_v1",
    .version = 1,
    .method_count = 3,
    .methods = &[_]wl_message{
        .{ .name = "destroy", .signature = "", .types = &null_types },
        .{
            .name = "lock_pointer",
            .signature = "noo?ou",
            .types = &[_]?*const wl_interface{
                &zwp_locked_pointer_v1_interface,
                &wl_surface_interface,
                &wl_pointer_interface,
                &wl_region_interface,
                null,
            },
        },
        .{
            .name = "confine_pointer",
            .signature = "noo?ou",
            .types = &[_]?*const wl_interface{
                &zwp_confined_pointer_v1_interface,
                &wl_surface_interface,
                &wl_pointer_interface,
                &wl_region_interface,
                null,
            },
        },
    },
    .event_count = 0,
    .events = null,
};

pub const zwp_relative_pointer_v1_interface: wl_interface = .{
    .name = "zwp_relative_pointer_v1",
    .version = 1,
    .method_count = 1,
    .methods = &[_]wl_message{
        .{ .name = "destroy", .signature = "", .types = &null_types },
    },
    .event_count = 1,
    .events = &[_]wl_message{
        .{ .name = "relative_motion", .signature = "uuffff", .types = &null_types },
    },
};

pub const zwp_relative_pointer_manager_v1_interface: wl_interface = .{
    .name = "zwp_relative_pointer_manager_v1",
    .version = 1,
    .method_count = 2,
    .methods = &[_]wl_message{
        .{ .name = "destroy", .signature = "", .types = &null_types },
        .{
            .name = "get_relative_pointer",
            .signature = "no",
            .types = &[_]?*const wl_interface{
                &zwp_relative_pointer_v1_interface,
                &wl_pointer_interface,
            },
        },
    },
    .event_count = 0,
    .events = null,
};

const ZWP_POINTER_CONSTRAINTS_LOCK_POINTER: u32 = 1;
const ZWP_LOCKED_POINTER_DESTROY: u32 = 0;
const ZWP_RELATIVE_MANAGER_GET_RELATIVE_POINTER: u32 = 1;
const ZWP_RELATIVE_POINTER_DESTROY: u32 = 0;
pub const POINTER_LOCK_LIFETIME_PERSISTENT: u32 = 2;

pub fn lock_pointer(surface: *wl_proxy, pointer: *wl_proxy) ?*wl_proxy {
    std.debug.assert(g_loaded);
    const constraints = conn.pointer_constraints orelse return null;
    var args = [_]wl_argument{
        .{ .n = 0 },
        .{ .o = surface },
        .{ .o = pointer },
        .{ .o = null },
        .{ .u = POINTER_LOCK_LIFETIME_PERSISTENT },
    };
    return marshal_constructor(
        constraints,
        ZWP_POINTER_CONSTRAINTS_LOCK_POINTER,
        &zwp_locked_pointer_v1_interface,
        &args,
    );
}

pub fn locked_pointer_destroy(locked: *wl_proxy) void {
    std.debug.assert(g_loaded);
    marshal_destructor(locked, ZWP_LOCKED_POINTER_DESTROY);
}

pub fn get_relative_pointer(pointer: *wl_proxy) ?*wl_proxy {
    std.debug.assert(g_loaded);
    const manager = conn.relative_pointer_manager orelse return null;
    var args = [_]wl_argument{ .{ .n = 0 }, .{ .o = pointer } };
    return marshal_constructor(
        manager,
        ZWP_RELATIVE_MANAGER_GET_RELATIVE_POINTER,
        &zwp_relative_pointer_v1_interface,
        &args,
    );
}

pub fn relative_pointer_destroy(relative: *wl_proxy) void {
    std.debug.assert(g_loaded);
    marshal_destructor(relative, ZWP_RELATIVE_POINTER_DESTROY);
}

// ---- data device (clipboard) ----

pub const wl_data_offer_interface: wl_interface = .{
    .name = "wl_data_offer",
    .version = 3,
    .method_count = 5,
    .methods = &[_]wl_message{
        .{ .name = "accept", .signature = "u?s", .types = &null_types },
        .{ .name = "receive", .signature = "sh", .types = &null_types },
        .{ .name = "destroy", .signature = "", .types = &null_types },
        .{ .name = "finish", .signature = "3", .types = &null_types },
        .{ .name = "set_actions", .signature = "3uu", .types = &null_types },
    },
    .event_count = 3,
    .events = &[_]wl_message{
        .{ .name = "offer", .signature = "s", .types = &null_types },
        .{ .name = "source_actions", .signature = "3u", .types = &null_types },
        .{ .name = "action", .signature = "3u", .types = &null_types },
    },
};

pub const wl_data_source_interface: wl_interface = .{
    .name = "wl_data_source",
    .version = 3,
    .method_count = 3,
    .methods = &[_]wl_message{
        .{ .name = "offer", .signature = "s", .types = &null_types },
        .{ .name = "destroy", .signature = "", .types = &null_types },
        .{ .name = "set_actions", .signature = "3u", .types = &null_types },
    },
    .event_count = 6,
    .events = &[_]wl_message{
        .{ .name = "target", .signature = "?s", .types = &null_types },
        .{ .name = "send", .signature = "sh", .types = &null_types },
        .{ .name = "cancelled", .signature = "", .types = &null_types },
        .{ .name = "dnd_drop_performed", .signature = "3", .types = &null_types },
        .{ .name = "dnd_finished", .signature = "3", .types = &null_types },
        .{ .name = "action", .signature = "3u", .types = &null_types },
    },
};

pub const wl_data_device_interface: wl_interface = .{
    .name = "wl_data_device",
    .version = 3,
    .method_count = 3,
    .methods = &[_]wl_message{
        .{
            .name = "start_drag",
            .signature = "?oo?ou",
            .types = &[_]?*const wl_interface{
                &wl_data_source_interface,
                &wl_surface_interface,
                &wl_surface_interface,
                null,
            },
        },
        .{
            .name = "set_selection",
            .signature = "?ou",
            .types = &[_]?*const wl_interface{ &wl_data_source_interface, null },
        },
        .{ .name = "release", .signature = "2", .types = &null_types },
    },
    .event_count = 6,
    .events = &[_]wl_message{
        .{
            .name = "data_offer",
            .signature = "n",
            .types = &[_]?*const wl_interface{&wl_data_offer_interface},
        },
        .{
            .name = "enter",
            .signature = "uoff?o",
            .types = &[_]?*const wl_interface{
                null,
                &wl_surface_interface,
                null,
                null,
                &wl_data_offer_interface,
            },
        },
        .{ .name = "leave", .signature = "", .types = &null_types },
        .{ .name = "motion", .signature = "uff", .types = &null_types },
        .{ .name = "drop", .signature = "", .types = &null_types },
        .{
            .name = "selection",
            .signature = "?o",
            .types = &[_]?*const wl_interface{&wl_data_offer_interface},
        },
    },
};

pub const wl_data_device_manager_interface: wl_interface = .{
    .name = "wl_data_device_manager",
    .version = 3,
    .method_count = 2,
    .methods = &[_]wl_message{
        .{
            .name = "create_data_source",
            .signature = "n",
            .types = &[_]?*const wl_interface{&wl_data_source_interface},
        },
        .{
            .name = "get_data_device",
            .signature = "no",
            .types = &[_]?*const wl_interface{
                &wl_data_device_interface,
                &wl_seat_input_interface,
            },
        },
    },
    .event_count = 0,
    .events = null,
};

const WL_DATA_DEVICE_MANAGER_CREATE_SOURCE: u32 = 0;
const WL_DATA_DEVICE_MANAGER_GET_DEVICE: u32 = 1;
const WL_DATA_DEVICE_SET_SELECTION: u32 = 1;
const WL_DATA_OFFER_RECEIVE: u32 = 1;
const WL_DATA_OFFER_DESTROY: u32 = 2;
const WL_DATA_SOURCE_OFFER: u32 = 0;
const WL_DATA_SOURCE_DESTROY: u32 = 1;

pub fn create_data_source() ?*wl_proxy {
    std.debug.assert(g_loaded);
    const manager = conn.data_device_manager orelse return null;
    var args = [_]wl_argument{.{ .n = 0 }};
    return marshal_constructor(
        manager,
        WL_DATA_DEVICE_MANAGER_CREATE_SOURCE,
        &wl_data_source_interface,
        &args,
    );
}

pub fn get_data_device(seat: *wl_proxy) ?*wl_proxy {
    std.debug.assert(g_loaded);
    const manager = conn.data_device_manager orelse return null;
    var args = [_]wl_argument{ .{ .n = 0 }, .{ .o = seat } };
    return marshal_constructor(
        manager,
        WL_DATA_DEVICE_MANAGER_GET_DEVICE,
        &wl_data_device_interface,
        &args,
    );
}

pub fn data_device_set_selection(device: *wl_proxy, source: ?*wl_proxy, serial: u32) void {
    std.debug.assert(g_loaded);
    var args = [_]wl_argument{ .{ .o = source }, .{ .u = serial } };
    marshal(device, WL_DATA_DEVICE_SET_SELECTION, &args);
}

pub fn data_source_offer(source: *wl_proxy, mime: [*:0]const u8) void {
    std.debug.assert(g_loaded);
    std.debug.assert(mime[0] != 0);
    var args = [_]wl_argument{.{ .s = mime }};
    marshal(source, WL_DATA_SOURCE_OFFER, &args);
}

pub fn data_source_destroy(source: *wl_proxy) void {
    std.debug.assert(g_loaded);
    marshal_destructor(source, WL_DATA_SOURCE_DESTROY);
}

pub fn data_offer_receive(offer: *wl_proxy, mime: [*:0]const u8, fd: i32) void {
    std.debug.assert(g_loaded);
    std.debug.assert(mime[0] != 0);
    std.debug.assert(fd >= 0);
    var args = [_]wl_argument{ .{ .s = mime }, .{ .h = fd } };
    marshal(offer, WL_DATA_OFFER_RECEIVE, &args);
}

pub fn data_offer_destroy(offer: *wl_proxy) void {
    std.debug.assert(g_loaded);
    marshal_destructor(offer, WL_DATA_OFFER_DESTROY);
}
