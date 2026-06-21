// Device status: battery level + charging via UIDevice, plus the app's bundle version.
// Network reachability is not exposed here - it needs the Network framework.
const objc = @import("../../macos/objc.zig");
const util = @import("util.zig");
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
