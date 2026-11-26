// Development-only UI debugging. Two tools over the laid-out node tree:
//   - a self-describing overlay (a border per node, optionally each node's x,y,w,h printed
//     on it), so a single screenshot carries its own measurements;
//   - a layout dump to the log (one JSON line per node), so geometry can be checked as
//     numbers instead of eyeballed pixels.
//
// Compiled only in Debug builds; a release build (ReleaseSmall) strips every byte. Toggled
// live, no rebuild:
//   Android:  adb shell setprop debug.zigui "boxes labels"   // or "dump", "all", "off"
//   desktop:  ZIGUI_DEBUG="boxes labels" ./app
// `dump` is a one-shot: it covers every region of the next frame (body, overlay, hud) once
// each time the toggle string changes, so re-arm it by setting a different value first
// (e.g. "off" then "dump").
const std = @import("std");
const builtin = @import("builtin");

const is_android = builtin.abi == .android;

pub const Mode = struct {
    boxes: bool = false,
    labels: bool = false,
    dump: bool = false,
};

pub var mode: Mode = .{};

var prev: [96]u8 = undefined;
var prev_len: usize = 0;
// The frame clock when a dump was armed; the regions of that same frame all dump.
var dump_at: f64 = -1;

pub inline fn overlay_on() bool {
    if (comptime builtin.mode != .debug) return false;
    return mode.boxes or mode.labels;
}

pub inline fn any_on() bool {
    if (comptime builtin.mode != .debug) return false;
    return mode.boxes or mode.labels or mode.dump;
}

// Read the platform toggle (cheap) and apply it. Call once per region render, with the
// frame clock (null outside a running window).
pub fn poll(now: ?f64) void {
    if (comptime builtin.mode != .debug) return;
    var buf: [96]u8 = undefined;
    const raw = read(&buf);
    const changed = !std.mem.eql(u8, raw, prev[0..prev_len]);
    apply(raw, changed);
    if (now) |t| {
        if (mode.dump) {
            dump_at = t;
        } else if (t == dump_at and (has(raw, "dump") or has(raw, "all"))) {
            mode.dump = true;
        }
    }
    prev_len = @min(raw.len, prev.len);
    @memcpy(prev[0..prev_len], raw[0..prev_len]);
}

fn apply(raw: []const u8, changed: bool) void {
    if (has(raw, "off")) {
        mode = .{};
        return;
    }
    const all = has(raw, "all");
    mode.boxes = all or has(raw, "box");
    mode.labels = all or has(raw, "label");
    // dump only on the rising edge of the toggle string, else it spams every frame.
    mode.dump = changed and (all or has(raw, "dump"));
}

fn has(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

fn read(buf: []u8) []const u8 {
    if (comptime is_android) return read_prop(buf);
    if (comptime builtin.link_libc) {
        const v = std.c.getenv("ZIGUI_DEBUG") orelse return "";
        return std.mem.span(v);
    }
    return "";
}

extern fn __system_property_get(name: [*:0]const u8, value: [*:0]u8) c_int;

fn read_prop(buf: []u8) []const u8 {
    if (buf.len < 92) return ""; // PROP_VALUE_MAX
    const n = __system_property_get("debug.zigui", @ptrCast(buf.ptr));
    if (n <= 0) return "";
    return buf[0..@intCast(n)];
}
