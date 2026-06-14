// A real kit UI driven through the public App.init/run, the same API the desktop
// examples use. zigui's Android backend exports ANativeActivity_onCreate, which
// calls this main() (the @import("root").main bridge), then builds the surface
// and runs this render() through the real renderer + paint loop.
//
// One shape difference from desktop: App.run returns immediately on Android (the
// framework owns the loop), so the state must outlive main() - a container-scoped
// var, not a stack local. No defer app.deinit() for the same reason: the loop
// keeps running after main() returns.
const std = @import("std");
const zigui = @import("zigui");
const ahb = @import("ahb.zig");

const Counter = struct {
    clicks: u32 = 0,
    focus: u32 = 0, // id of the focused text field, 0 = none
    awake: bool = false, // FLAG_KEEP_SCREEN_ON while true
    immersive: bool = false, // system bars hidden while true
    // The last result a detail page returned, copied out of the stack on the frame
    // the pop delivered it (take_result yields it once, the slice is borrowed).
    last_result: [64]u8 = undefined,
    last_result_len: usize = 0,
};

fn toggle_awake(c: *Counter) void {
    c.awake = !c.awake;
}
fn toggle_immersive(c: *Counter) void {
    c.immersive = !c.immersive;
}

var state: Counter = .{};
var nav: zigui.NavStack = .{};
var list_scroll: zigui.ScrollState = .{};
var field: zigui.TextField = .{};

fn focus_field(c: *Counter) void {
    c.focus = 1;
}
fn blur_fields(c: *Counter) void {
    c.focus = 0;
}

// startActivity with extras: push the detail page carrying a payload it reads back.
fn open_detail(c: *Counter) void {
    _ = c;
    nav.push_with("detail", "Details", "hello from home");
}

// setResult + finish: stage a result, then pop so the home page receives it.
fn save_and_back(c: *Counter) void {
    _ = c;
    nav.set_result("saved at 42");
    nav.pop();
}

// Push the zero-copy frame page (an AHardwareBuffer imported with no copy).
fn open_frame(c: *Counter) void {
    _ = c;
    nav.push("frame", "Frame");
}

// Push the native-API page.
fn open_native(c: *Counter) void {
    _ = c;
    nav.push("native", "Native APIs");
}

fn do_vibrate(c: *Counter) void {
    _ = c;
    zigui.vibrate(40);
}
fn do_open_url(c: *Counter) void {
    _ = c;
    zigui.open_url("https://ziglang.org");
}
fn do_share(c: *Counter) void {
    _ = c;
    zigui.share_text("shared from zigui");
}
fn do_notify(c: *Counter) void {
    _ = c;
    zigui.notify("zigui", "hello from the native api demo");
}
// Round-trips the clipboard: write, then read it back into the result buffer.
fn do_clipboard(c: *Counter) void {
    zigui.set_clipboard_text("copied by zigui");
    const got = zigui.clipboard_text(&c.last_result);
    c.last_result_len = got.len;
}

pub fn main() !void {
    var app = try zigui.App.init(.{ .title = "zigui", .size = .{ 400, 800 } });
    try app.run(&state, .{ .body = render });
}

// A tap adds a dot, capped so the row never overflows the surface. With no font
// the label does not render, so the dot row is the visible proof a touch reached
// the kit.
const MAX_DOTS = 8;
// Enough rows to overflow the viewport so the list is scrollable by drag.
const LIST_ROWS = 16;

fn render(f: *zigui.Frame, counter: *Counter) *zigui.Node {
    if (nav.depth == 0) nav.go("home", "Home"); // seed the root once
    zigui.handle_back(&nav); // Esc / Android Back / chevron -> pop
    if (nav.take_result()) |r| { // a detail page returned a result: keep it
        const k = @min(r.len, counter.last_result.len);
        @memcpy(counter.last_result[0..k], r[0..k]);
        counter.last_result_len = k;
    }
    // Window properties, re-asserted every frame (the backend hops into the OS
    // only on a change): light status-bar icons over this dark theme, plus the
    // two live toggles below.
    zigui.status_bar_icons(.light);
    zigui.keep_awake(counter.awake);
    zigui.immersive(counter.immersive);

    const route = nav.current();
    const page = if (std.mem.eql(u8, route, "detail"))
        detail_page(f)
    else if (std.mem.eql(u8, route, "frame"))
        frame_page(f)
    else if (std.mem.eql(u8, route, "native"))
        native_page(f, counter)
    else
        home_page(f, counter);

    return zigui.col(.{}, &.{
        zigui.app_bar(nav.current_title(), .{ .show_back = nav.depth > 1 }),
        page,
    });
}

fn home_page(f: *zigui.Frame, counter: *Counter) *zigui.Node {
    const n = @min(counter.clicks, MAX_DOTS);
    var dots: []const *zigui.Node = &.{};
    if (f.arena.alloc(*zigui.Node, n)) |slice| {
        const box = zigui.Config{ .width = 28, .height = 28, .radius = 8, .bg = f.theme.primary };
        for (slice) |*dot| dot.* = zigui.col(box, &.{});
        dots = slice;
    } else |_| {}

    // A tall list of alternating bars; dragging inside it scrolls (the bars shift).
    var rows: []const *zigui.Node = &.{};
    if (f.arena.alloc(*zigui.Node, LIST_ROWS)) |slice| {
        for (slice, 0..) |*r, i| {
            const c = if (i % 2 == 0) f.theme.primary else f.theme.border;
            r.* = zigui.col(.{ .height = 44, .radius = 8, .bg = c }, &.{});
        }
        rows = slice;
    } else |_| {}

    // A click that misses the field blurs the shared editor (hides the keyboard).
    const page = zigui.Config{
        .pad = .lg,
        .gap = .md,
        .grow = 1,
        .on_click = zigui.on(Counter, blur_fields),
    };
    const returned = counter.last_result[0..counter.last_result_len];
    const note = if (counter.last_result_len > 0) returned else "(no result yet)";
    const awake_label = if (counter.awake) "Keep awake: ON" else "Keep awake: off";
    const imm_label = if (counter.immersive) "Immersive: ON" else "Immersive: off";
    return zigui.col(page, &.{
        zigui.text("Hello, Android.", .{ .size = 28 }),
        zigui.button("Tap me", .{ .on_click = zigui.on(Counter, on_click) }),
        zigui.button("Open details", .{ .on_click = zigui.on(Counter, open_detail) }),
        zigui.button("Show AHB frame", .{ .on_click = zigui.on(Counter, open_frame) }),
        zigui.button("Native APIs", .{ .on_click = zigui.on(Counter, open_native) }),
        zigui.button(awake_label, .{ .on_click = zigui.on(Counter, toggle_awake) }),
        zigui.button(imm_label, .{ .on_click = zigui.on(Counter, toggle_immersive) }),
        zigui.text(note, .{ .size = 16 }),
        zigui.text_input(&field, .{
            .placeholder = "Tap to type",
            .focused = counter.focus == 1,
            .id = 1,
            .on_focus = zigui.on(Counter, focus_field),
        }),
        zigui.row(.{ .gap = .sm }, dots),
        zigui.scroll(&list_scroll, .{ .grow = 1 }, zigui.col(.{ .gap = .sm }, rows)),
    });
}

// The native services, each one tap. Clipboard round-trips into the note.
fn native_page(f: *zigui.Frame, counter: *Counter) *zigui.Node {
    _ = f;
    const clip = counter.last_result[0..counter.last_result_len];
    const note = if (counter.last_result_len > 0) clip else "(clipboard empty)";
    return zigui.col(.{ .pad = .lg, .gap = .md, .grow = 1 }, &.{
        zigui.text("Native APIs.", .{ .size = 20 }),
        zigui.button("Vibrate", .{ .on_click = zigui.on(Counter, do_vibrate) }),
        zigui.button("Open URL", .{ .on_click = zigui.on(Counter, do_open_url) }),
        zigui.button("Share text", .{ .on_click = zigui.on(Counter, do_share) }),
        zigui.button("Notify", .{ .on_click = zigui.on(Counter, do_notify) }),
        zigui.button("Copy + paste", .{ .on_click = zigui.on(Counter, do_clipboard) }),
        zigui.text(note, .{ .size = 16 }),
    });
}

// The zero-copy frame page: a synthesized YUV AHardwareBuffer imported with no
// copy and sampled through the renderer's ycbcr pipeline.
fn frame_page(f: *zigui.Frame) *zigui.Node {
    _ = f;
    return zigui.col(.{ .pad = .lg, .gap = .md, .grow = 1 }, &.{
        zigui.text("AHardwareBuffer (zero-copy NV12).", .{ .size = 20 }),
        ahb.frame_node(),
    });
}

// The pushed page reads the payload it was opened with (current_args) and can stage
// a result for home; the chevron / Back / Esc pop back (Save returns the result).
fn detail_page(f: *zigui.Frame) *zigui.Node {
    _ = f;
    return zigui.col(.{ .pad = .lg, .gap = .md, .grow = 1 }, &.{
        zigui.text("Detail page.", .{ .size = 28 }),
        zigui.text("Got args:", .{ .size = 14 }),
        zigui.text(nav.current_args(), .{ .size = 16 }),
        zigui.button("Save & back", .{ .on_click = zigui.on(Counter, save_and_back) }),
        zigui.text("(or Back to return with no result)", .{ .size = 14 }),
    });
}

fn on_click(counter: *Counter) void {
    counter.clicks += 1;
}

// The NativeActivity entry export emits only when the compilation root keeps it
// reachable; a comptime reference to zigui.App pulls the backend (and its
// exported ANativeActivity_onCreate) into the .so. A runtime use inside main()
// alone does not, so the framework would otherwise fail to find the entry symbol.
comptime {
    _ = zigui.App;
}

// The JNI native method ZiguiActivity.nativeOnText resolves to this exported
// symbol (the name encodes this app's package/class). It just forwards the edited
// text to zigui's IME bridge, keeping the package name out of the library.
export fn Java_com_qoinly_zigui_androidapp_ZiguiActivity_nativeOnText(
    env: *anyopaque,
    this: *anyopaque,
    text: ?*anyopaque,
    caret: i32,
) callconv(.c) void {
    _ = this;
    zigui.android_on_native_text(env, text, caret);
}

// ZiguiActivity.onBackPressed -> here: pop the route stack (jboolean = whether the
// press was consumed; the Java side backgrounds the app when it was not).
export fn Java_com_qoinly_zigui_androidapp_ZiguiActivity_nativeOnBack(
    env: *anyopaque,
    this: *anyopaque,
) callconv(.c) u8 {
    _ = env;
    _ = this;
    return @intFromBool(zigui.android_on_native_back());
}
