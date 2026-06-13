// libxcb-randr binding for monitor enumeration: one request (GetMonitors,
// RandR 1.5) parsed by hand because the per-monitor iterators are static
// inline in the C headers, not symbols. dlopen like the other bindings.

const std = @import("std");
const xcb = @import("xcb.zig");

pub const Error = error{LibraryLoadFailed};

pub const MAX_MONITORS: u32 = 8;

pub const Monitor = struct {
    x: i16 = 0,
    y: i16 = 0,
    width: u16 = 0,
    height: u16 = 0,
    primary: bool = false,
};

const GetMonitorsCookie = extern struct { sequence: c_uint };

// Reply head; the variable-length MonitorInfo records follow the 32 bytes.
const GetMonitorsReply = extern struct {
    response_type: u8,
    pad0: u8,
    sequence: u16,
    length: u32,
    timestamp: u32,
    n_monitors: u32,
    n_outputs: u32,
    pad1: [12]u8,
};

// Fixed head of xcb_randr_monitor_info_t; ncrtcs u32 outputs trail each
// record, so records advance by 24 + 4 * ncrtcs bytes.
const MonitorInfo = extern struct {
    name: u32,
    primary: u8,
    automatic: u8,
    ncrtcs: u16,
    x: i16,
    y: i16,
    width: u16,
    height: u16,
    width_mm: u32,
    height_mm: u32,
};

extern "c" fn dlopen(file: [*:0]const u8, mode: c_int) ?*anyopaque;
extern "c" fn dlsym(handle: ?*anyopaque, name: [*:0]const u8) ?*anyopaque;
extern "c" fn free(ptr: ?*anyopaque) void;
const RTLD_NOW: c_int = 2;

const Fns = struct {
    xcb_randr_get_monitors: *const fn (*xcb.Connection, u32, u8) callconv(.c) GetMonitorsCookie,
    xcb_randr_get_monitors_reply: *const fn (
        *xcb.Connection,
        GetMonitorsCookie,
        ?*?*anyopaque,
    ) callconv(.c) ?*GetMonitorsReply,
};

var fns: Fns = undefined;
var g_loaded = false;
var g_present = false;

pub fn load() Error!void {
    if (g_loaded) return;
    const handle = dlopen("libxcb-randr.so.0", RTLD_NOW) orelse return error.LibraryLoadFailed;
    inline for (@typeInfo(Fns).@"struct".fields) |fn_field| {
        const sym = dlsym(handle, fn_field.name) orelse return error.LibraryLoadFailed;
        @field(fns, fn_field.name) = @ptrCast(@alignCast(sym));
    }
    // The id symbol gates on the server actually speaking RandR.
    const id = dlsym(handle, "xcb_randr_id") orelse return error.LibraryLoadFailed;
    g_present = xcb.extension_data(id) != null;
    g_loaded = true;
    std.debug.assert(g_loaded);
}

// Active monitors in pixel coordinates; out's unfilled tail stays zeroed.
pub fn monitors(root: u32, out: *[MAX_MONITORS]Monitor) u32 {
    std.debug.assert(xcb.conn != null);
    std.debug.assert(root != 0);
    if (!g_present) return 0;
    const cookie = fns.xcb_randr_get_monitors(xcb.conn.?, root, 1);
    const reply = fns.xcb_randr_get_monitors_reply(xcb.conn.?, cookie, null) orelse return 0;
    defer free(reply);
    const total_bytes = 32 + @as(usize, reply.length) * 4;
    const base: [*]const u8 = @ptrCast(reply);
    var offset: usize = 32;
    var count: u32 = 0;
    var index: u32 = 0;
    while (index < reply.n_monitors and count < MAX_MONITORS) : (index += 1) {
        if (offset + @sizeOf(MonitorInfo) > total_bytes) break;
        const info: *const MonitorInfo = @ptrCast(@alignCast(base + offset));
        out[count] = .{
            .x = info.x,
            .y = info.y,
            .width = info.width,
            .height = info.height,
            .primary = info.primary != 0,
        };
        count += 1;
        offset += @sizeOf(MonitorInfo) + @as(usize, info.ncrtcs) * 4;
    }
    std.debug.assert(count <= MAX_MONITORS);
    return count;
}
