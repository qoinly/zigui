// Device status: battery + charging via UIDevice, the app's bundle version, and network
// reachability + transport via NWPathMonitor (the Network framework).
const std = @import("std");
const objc = @import("../../macos/objc.zig");
const util = @import("util.zig");
const cs = @import("../custom_shell.zig");
const Id = objc.Id;

// UIDevice.currentDevice with battery monitoring enabled (idempotent).
fn current() ?Id {
    const cls = objc.get_class("UIDevice") orelse return null;
    const d = objc.msg_send(Id, cls, "currentDevice", .{});
    objc.msg_send(void, d, "setBatteryMonitoringEnabled:", .{objc.YES});
    return d;
}

// UIDevice.batteryLevel is 0..1 (-1 when unknown); scaled to a 0..100 percent.
pub fn battery_level() u8 {
    const d = current() orelse return 0;
    const lvl = objc.msg_send(f32, d, "batteryLevel", .{});
    if (lvl < 0) return 0; // unknown on this device / not monitoring yet
    return @intFromFloat(@min(lvl * 100, 100));
}

// UIDeviceBatteryState: 2 = charging, 3 = full (both on external power).
pub fn charging() bool {
    const d = current() orelse return false;
    const state = objc.msg_send(objc.NSInteger, d, "batteryState", .{});
    return state == 2 or state == 3;
}

// CFBundleShortVersionString from the main bundle's Info.plist - the app's marketing
// version (e.g. "1.2.0"); empty when the key is absent.
pub fn app_version(buf: []u8) []const u8 {
    const NSBundle = objc.get_class("NSBundle") orelse return "";
    const bundle = objc.msg_send(?Id, NSBundle, "mainBundle", .{}) orelse return "";
    var kbuf: [40]u8 = undefined;
    const key = util.nsstring(&kbuf, "CFBundleShortVersionString") orelse return "";
    const val = objc.msg_send(?Id, bundle, "objectForInfoDictionaryKey:", .{key}) orelse return "";
    return util.read_nsstring(val, buf);
}

// --- network reachability via NWPathMonitor (Network framework, a plain C API) ---

const NwMonitor = *opaque {};
const NwPath = *opaque {};
extern "c" fn nw_path_monitor_create() ?NwMonitor;
extern "c" fn nw_path_monitor_set_queue(monitor: NwMonitor, queue: *anyopaque) void;
extern "c" fn nw_path_monitor_set_update_handler(
    monitor: NwMonitor,
    handler: *const objc.Block,
) void;
extern "c" fn nw_path_monitor_start(monitor: NwMonitor) void;
extern "c" fn nw_path_get_status(path: NwPath) c_int;
extern "c" fn nw_path_uses_interface_type(path: NwPath, t: c_int) bool;
extern "c" fn dispatch_get_global_queue(identifier: isize, flags: usize) ?*anyopaque;

const PATH_SATISFIED: c_int = 1; // nw_path_status_satisfied
const IFACE_WIFI: c_int = 1; // nw_interface_type_wifi
const IFACE_CELLULAR: c_int = 2; // nw_interface_type_cellular

var g_started: bool = false;
var g_online: bool = false;
var g_net: u8 = 0; // device.Network code: 0 none, 1 wifi, 2 cellular, 3 other
var g_desc: objc.BlockDescriptor = .{ .size = @sizeOf(objc.Block) };
var g_block: objc.Block = undefined;
var g_monitor: ?NwMonitor = null;

// The path-update handler runs on a background queue: cache reachability + transport, wake.
fn path_update(_: *objc.Block, path: ?NwPath) callconv(.c) void {
    const p = path orelse return;
    const sat = nw_path_get_status(p) == PATH_SATISFIED;
    @atomicStore(bool, &g_online, sat, .release);
    var net: u8 = 0;
    if (sat) {
        if (nw_path_uses_interface_type(p, IFACE_WIFI)) {
            net = 1;
        } else if (nw_path_uses_interface_type(p, IFACE_CELLULAR)) {
            net = 2;
        } else net = 3;
    }
    std.debug.assert(net <= 3);
    @atomicStore(u8, &g_net, net, .release);
    cs.request_redraw();
}

// Create + start one monitor on first query; its handler then keeps the cache current.
fn ensure_monitor() void {
    if (g_started) return;
    g_started = true;
    const m = nw_path_monitor_create() orelse return;
    g_monitor = m;
    const q = dispatch_get_global_queue(0, 0) orelse return;
    g_block = objc.global_block(@ptrCast(&path_update), &g_desc);
    nw_path_monitor_set_update_handler(m, &g_block);
    nw_path_monitor_set_queue(m, q);
    nw_path_monitor_start(m);
}

pub fn online() bool {
    ensure_monitor();
    return @atomicLoad(bool, &g_online, .acquire);
}

pub fn network_code() u8 {
    ensure_monitor();
    return @atomicLoad(u8, &g_net, .acquire);
}
