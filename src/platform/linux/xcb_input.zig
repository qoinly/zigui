// libxcb-xinput binding for XInput2 raw motion: the unaccelerated deltas a
// pointer grab streams to the raw dispatch (the channel the Wayland arm gets
// from relative-pointer). One select request + a hand-parsed GE event.

const std = @import("std");
const xcb = @import("xcb.zig");

pub const Error = error{LibraryLoadFailed};

pub const RAW_MOTION: u16 = 17;

const XI_ALL_MASTER_DEVICES: u16 = 1;

// xcb_input_event_mask_t with one mask word, the only shape we send.
const EventMask = extern struct {
    deviceid: u16,
    mask_len: u16,
    mask: u32,
};

// Fixed head of xcb_input_raw_motion_event_t (a GE_GENERIC event); the
// valuator mask words, accelerated values, then raw values trail it.
// full_sequence is NOT wire data: libxcb inserts it at the 32-byte mark of
// every generic event, shifting the payload by 4.
const RawEventHead = extern struct {
    response_type: u8,
    extension: u8,
    sequence: u16,
    length: u32,
    event_type: u16,
    deviceid: u16,
    time: u32,
    detail: u32,
    sourceid: u16,
    valuators_len: u16,
    flags: u32,
    pad0: [4]u8,
    full_sequence: u32,
};

// Fixed-point 32.32, the XI2 axis value encoding.
const Fp3232 = extern struct {
    integral: i32,
    frac: u32,
};

extern "c" fn dlopen(file: [*:0]const u8, mode: c_int) ?*anyopaque;
extern "c" fn dlsym(handle: ?*anyopaque, name: [*:0]const u8) ?*anyopaque;
const RTLD_NOW: c_int = 2;

const Fns = struct {
    xcb_input_xi_select_events: *const fn (
        *xcb.Connection,
        u32,
        u16,
        *const EventMask,
    ) callconv(.c) extern struct { sequence: c_uint },
};

var fns: Fns = undefined;
var g_loaded = false;

// 0 means the extension is absent; raw motion never fires then.
pub var opcode: u8 = 0;

pub fn load() Error!void {
    if (g_loaded) return;
    const handle = dlopen("libxcb-xinput.so.0", RTLD_NOW) orelse return error.LibraryLoadFailed;
    inline for (@typeInfo(Fns).@"struct".fields) |fn_field| {
        const sym = dlsym(handle, fn_field.name) orelse return error.LibraryLoadFailed;
        @field(fns, fn_field.name) = @ptrCast(@alignCast(sym));
    }
    const id = dlsym(handle, "xcb_input_id") orelse return error.LibraryLoadFailed;
    const data = xcb.extension_data(id) orelse return error.LibraryLoadFailed;
    opcode = data.major_opcode;
    g_loaded = true;
    std.debug.assert(opcode != 0);
}

// Raw events are delivered to selections on the ROOT window only.
pub fn select_raw_motion(root: u32) void {
    std.debug.assert(g_loaded);
    std.debug.assert(root != 0);
    const mask = EventMask{
        .deviceid = XI_ALL_MASTER_DEVICES,
        .mask_len = 1,
        .mask = 1 << RAW_MOTION,
    };
    _ = fns.xcb_input_xi_select_events(xcb.conn.?, root, 1, &mask);
}

// An empty mask unsubscribes; raw events on the root are global traffic the
// connection must not keep paying for after the grab ends.
pub fn clear_raw_motion(root: u32) void {
    std.debug.assert(g_loaded);
    std.debug.assert(root != 0);
    const mask = EventMask{
        .deviceid = XI_ALL_MASTER_DEVICES,
        .mask_len = 1,
        .mask = 0,
    };
    _ = fns.xcb_input_xi_select_events(xcb.conn.?, root, 1, &mask);
}

pub const RawDelta = struct { dx: f32, dy: f32 };

// Pulls the x/y axis deltas out of a raw-motion event: the mask words list
// which axes are present, accelerated values come first, the raw
// (unaccelerated) block follows - that block is the one reported.
pub fn raw_motion_delta(event: *const xcb.GeGenericEvent) RawDelta {
    std.debug.assert(event.response_type & 0x7f == xcb.GE_GENERIC);
    const head: *const RawEventHead = @ptrCast(@alignCast(event));
    std.debug.assert(head.event_type == RAW_MOTION);
    const base: [*]const u8 = @ptrCast(event);
    const mask_words: [*]const u32 = @ptrCast(@alignCast(base + @sizeOf(RawEventHead)));
    const mask_len: usize = head.valuators_len;
    var total_axes: usize = 0;
    var word: usize = 0;
    while (word < mask_len) : (word += 1) {
        total_axes += @popCount(mask_words[word]);
    }
    const values: [*]const Fp3232 =
        @ptrCast(@alignCast(base + @sizeOf(RawEventHead) + mask_len * 4));
    const raw_block = values + total_axes;
    var delta = RawDelta{ .dx = 0, .dy = 0 };
    if (mask_len == 0) return delta;
    var value_index: usize = 0;
    var axis: u5 = 0;
    // Axes 0/1 are pointer x/y; both live in mask word 0 when present.
    while (axis < 31) : (axis += 1) {
        if (mask_words[0] & (@as(u32, 1) << axis) == 0) continue;
        if (axis == 0) delta.dx = fp_to_f32(raw_block[value_index]);
        if (axis == 1) delta.dy = fp_to_f32(raw_block[value_index]);
        if (axis > 1) break;
        value_index += 1;
    }
    return delta;
}

fn fp_to_f32(value: Fp3232) f32 {
    const frac: f64 = @as(f64, @floatFromInt(value.frac)) / 4294967296.0;
    return @floatCast(@as(f64, @floatFromInt(value.integral)) + frac);
}
