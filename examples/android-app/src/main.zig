// A real kit UI driven through the public App.init/run, the same API the desktop
// examples use. zigui's Android backend exports ANativeActivity_onCreate, which
// calls this main() (the @import("root").main bridge), then builds the surface
// and runs this render() through the real renderer + paint loop.
//
// One shape difference from desktop: App.run returns immediately on Android (the
// framework owns the loop), so the state must outlive main() - a container-scoped
// var, not a stack local. No defer app.deinit() for the same reason: the loop
// keeps running after main() returns.
const zigui = @import("zigui");

const Counter = struct {
    clicks: u32 = 0,
    focus: u32 = 0, // id of the focused text field, 0 = none
};

var state: Counter = .{};
var list_scroll: zigui.ScrollState = .{};
var field: zigui.TextField = .{};

fn focus_field(c: *Counter) void {
    c.focus = 1;
}
fn blur_fields(c: *Counter) void {
    c.focus = 0;
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
    return zigui.col(.{ .pad = .lg, .gap = .md, .on_click = zigui.on(Counter, blur_fields) }, &.{
        zigui.text("Hello, Android.", .{ .size = 28 }),
        zigui.button("Tap me", .{ .on_click = zigui.on(Counter, on_click) }),
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
