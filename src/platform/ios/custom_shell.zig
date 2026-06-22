// The iOS arm of the custom-shell facade. UIKit gives the app one fullscreen
// surface with no client-side decorations, pointer grab, or clipboard, so this is
// mostly an honest no-op set: it exposes the exact pub surface the desktop shells
// do - so the facade's non-macOS branches resolve here - while the window methods
// PaintContext reads (size, scale, theme) report the live view state.
//
// The handle carries the CAMetalLayer the renderer draws into. app.zig builds the
// view at launch and registers the IOSWindow storage here (the renderer holds the
// same pointer), set on surface ready.

const std = @import("std");
const objc = @import("../macos/objc.zig");
const native = @import("native.zig");
const shell_types = @import("../linux/shell_types.zig");
const types = @import("../../window/types.zig");
const geometry = @import("../../geometry.zig");

pub const KeyMods = shell_types.KeyMods;
pub const KeyCode = shell_types.KeyCode;
pub const KeyEvent = shell_types.KeyEvent;
pub const MouseDispatch = shell_types.MouseDispatch;
pub const RawDispatch = shell_types.RawDispatch;
pub const CursorKind = shell_types.CursorKind;
pub const CaptionButton = shell_types.CaptionButton;
pub const HitTestFn = shell_types.HitTestFn;
pub const RedrawFn = shell_types.RedrawFn;
pub const WindowCloseFn = shell_types.WindowCloseFn;
pub const CAPTION_BTN_W = shell_types.CAPTION_BTN_W;
pub const CAPTION_CLUSTER_W = shell_types.CAPTION_CLUSTER_W;
pub const Error = shell_types.Error;
pub const ContentSize = shell_types.ContentSize;

// The IOSWindow storage lives in app.zig; the shell reaches it to report
// size/scale and the layer.
var g_window: ?*native.IOSWindow = null;

// The paint loop registers a MouseDispatch (ctx = the PaintContext) once at surface
// start; the view's touch methods read it back to route a tap. Never cleared - one
// surface per app, so it stays valid for the app's life.
var g_dispatch: ?MouseDispatch = null;

pub fn set_window(window: *native.IOSWindow) void {
    g_window = window;
}

pub fn mouse_dispatch() ?MouseDispatch {
    return g_dispatch;
}

// A finger drag the input layer routes through this handler: it scrolls the region
// under the touch (or drags a captured control). The paint loop registers it; the
// view's touch methods read it back.
const TouchMoveFn = *const fn (ctx: *anyopaque, x: f32, y: f32) void;
const TouchMove = struct { cb: TouchMoveFn, ctx: *anyopaque };
var g_touch: ?TouchMove = null;

pub fn register_touch_move(cb: TouchMoveFn, ctx: *anyopaque) void {
    g_touch = .{ .cb = cb, .ctx = ctx };
}

pub fn touch_move() ?TouchMove {
    return g_touch;
}

const UIEdgeInsets = extern struct {
    top: objc.CGFloat,
    left: objc.CGFloat,
    bottom: objc.CGFloat,
    right: objc.CGFloat,
};

// Insets the paint loop carves off the body for the status bar, dynamic island,
// and home indicator. UIKit computes UIView.safeAreaInsets per device in points,
// so they are read live (they change with rotation and device), never hardcoded.
pub fn safe_area_insets() geometry.Insets {
    const w = g_window orelse return .{};
    const view = w.view orelse return .{};
    const e = objc.msg_send(UIEdgeInsets, view, "safeAreaInsets", .{});
    return .{
        .left = @floatCast(e.left),
        .top = @floatCast(e.top),
        .right = @floatCast(e.right),
        .bottom = @floatCast(e.bottom),
    };
}

pub const CustomShellHandle = struct {
    window: *anyopaque,
    metal_layer: objc.Id,
    height: f32,
    theme: types.Theme,
    titlebar: types.TitlebarOptions,

    fn win(self: CustomShellHandle) *native.IOSWindow {
        return @ptrCast(@alignCast(self.window));
    }

    // One fullscreen surface: the focus/state queries are constants - it is always
    // the key surface, never min/max/fullscreen in the desktop sense.
    pub fn focus(self: CustomShellHandle) void {
        _ = self;
    }

    pub fn is_fullscreen(self: CustomShellHandle) bool {
        _ = self;
        return false;
    }

    pub fn set_fullscreen(self: CustomShellHandle, on: bool) void {
        _ = self;
        _ = on;
    }

    pub fn is_maximized(self: CustomShellHandle) bool {
        _ = self;
        return false;
    }

    pub fn is_minimized(self: CustomShellHandle) bool {
        _ = self;
        return false;
    }

    pub fn is_key(self: CustomShellHandle) bool {
        _ = self;
        return true;
    }

    pub fn backing_scale_factor(self: CustomShellHandle) f32 {
        const s = self.win().scale;
        std.debug.assert(s >= 1);
        return @floatFromInt(s);
    }

    pub fn sync_drawable_size(self: CustomShellHandle) ContentSize {
        const w = self.win();
        w.sync_extent();
        std.debug.assert(w.width_pt >= 1);
        return .{
            .width = @floatFromInt(w.width_pt),
            .height = @floatFromInt(w.height_pt),
        };
    }

    pub fn deinit(self: CustomShellHandle) void {
        _ = self;
        // UIKit owns the window and view; teardown drops the renderer side, so
        // there is nothing to free here.
    }
};

// The iOS surface arrives through the delegate, not an open() call, so this wraps
// the already-built view app.zig registered. Chrome is disabled: the body fills
// the whole surface.
pub fn open(opts: types.NativeShellOptions) Error!CustomShellHandle {
    const window = g_window orelse return error.WindowCreateFailed;
    if (!window.in_use) return error.WindowCreateFailed;
    const layer = window.layer orelse return error.WindowCreateFailed;
    return .{
        .window = @ptrCast(window),
        .metal_layer = layer,
        .height = @floatCast(opts.height),
        .theme = opts.theme orelse types.Theme.default_dark(),
        .titlebar = .{ .enabled = false },
    };
}

// The paint loop registers a MouseDispatch here; the view's touch methods read it
// back to route a tap. The raw/grab/cursor hooks below have no iOS source and are
// accepted and dropped.
pub fn register_mouse_dispatch(d: MouseDispatch) void {
    g_dispatch = d;
}

pub fn register_raw_dispatch(d: RawDispatch) void {
    _ = d;
}

pub fn bind_surface_ctx(handle: CustomShellHandle, ctx: *anyopaque) void {
    _ = handle;
    _ = ctx;
}

pub fn register_window_close(cb: WindowCloseFn, ctx: *anyopaque) void {
    _ = cb;
    _ = ctx;
}

// The paint loop's redraw callback + its PaintContext, stored so an async napi result
// can wake an idle render loop (the CADisplayLink pauses when nothing is animating).
var g_redraw_cb: ?RedrawFn = null;
var g_redraw_ctx: ?*anyopaque = null;

pub fn register_hit_test(hit_test_cb: HitTestFn, redraw_cb: RedrawFn, ctx: *anyopaque) void {
    _ = hit_test_cb;
    g_redraw_cb = redraw_cb;
    g_redraw_ctx = ctx;
}

// Force the paint loop to render the next vsync. The napi calls this to surface an async
// result (e.g. a finished file pick) without the app polling while the loop idles.
pub fn request_redraw() void {
    if (g_redraw_cb) |cb| if (g_redraw_ctx) |c| cb(c);
}

pub fn register_paint_now(cb: RedrawFn) void {
    _ = cb;
}

// No relative-pointer capture on touch; grab is inert.
pub fn set_grab(on: bool) void {
    _ = on;
}

pub fn is_grabbed() bool {
    return false;
}

pub fn release_grab_if_blurred() void {}

pub fn apply_cursor(kind: CursorKind) void {
    _ = kind;
}

pub fn current_shift_down() bool {
    return false;
}

pub fn hovered_caption_button() CaptionButton {
    return .none;
}

// A native UITextField floats over the kit-drawn box (text_field_native_paint is
// true on iOS, as on macOS), so the OS owns caret placement, selection, the
// long-press edit menu, the magnifier, autocorrect, and dictation - editing a
// custom kit can't match by hand. The kit draws the box; this control draws the
// text + caret. It stays hidden until the kit focuses a field, so the first tap
// falls through to the kit (a hidden view is not hit-tested), which focuses and
// raises it; a re-seed runs only on a field change, keyed by id, so live typing is
// never clobbered. setFrame runs every frame so the control tracks the box (a field
// inside a scroll moves with it).
var g_field: ?objc.Id = null;
var g_visible: bool = false;
var g_active_id: u32 = 0;

const border_style_none: objc.NSInteger = 0;
const keyboard_type_default: objc.NSInteger = 0;
const keyboard_type_number_pad: objc.NSInteger = 4;
const field_buf_max: usize = 256;

fn ensure_field(view: objc.Id) ?objc.Id {
    std.debug.assert(@intFromPtr(view) != 0);
    if (g_field) |f| return f;
    const cls = objc.get_class("UITextField") orelse return null;
    const f = objc.msg_send(objc.Id, objc.alloc(cls), "init", .{});
    std.debug.assert(@intFromPtr(f) != 0);
    objc.msg_send(void, f, "setBorderStyle:", .{border_style_none}); // the kit draws the box
    if (objc.get_class("UIColor")) |UIColor| {
        const clear = objc.msg_send(objc.Id, UIColor, "clearColor", .{});
        objc.msg_send(void, f, "setBackgroundColor:", .{clear});
    }
    objc.msg_send(void, f, "setHidden:", .{objc.YES});
    objc.msg_send(void, view, "addSubview:", .{f});
    g_field = f;
    return f;
}

pub fn show_text_field(
    handle: CustomShellHandle,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    initial: []const u8,
    font_size: f32,
    color: types.Rgba,
    secure: bool,
    numeric: bool,
    id: u32,
) bool {
    std.debug.assert(id != 0);
    const view = handle.win().view orelse return false;
    std.debug.assert(@intFromPtr(view) != 0);
    const f = ensure_field(view) orelse return false;
    objc.msg_send(void, f, "setFrame:", .{native.CGRect{
        .origin = .{ .x = x, .y = y },
        .size = .{ .width = w, .height = h },
    }});
    if (!g_visible or g_active_id != id) {
        seed_field(f, initial, font_size, color, secure, numeric);
        objc.msg_send(void, f, "setHidden:", .{objc.NO});
        _ = objc.msg_send(bool, f, "becomeFirstResponder", .{});
        g_visible = true;
        g_active_id = id;
    }
    return true;
}

// Font, colour, and the secure/numeric traits hold steady while a field is focused,
// so apply them (and seed the text) only on a field change; the per-frame path in
// show_text_field just tracks the box.
fn seed_field(
    f: objc.Id,
    initial: []const u8,
    font_size: f32,
    color: types.Rgba,
    secure: bool,
    numeric: bool,
) void {
    std.debug.assert(@intFromPtr(f) != 0);
    std.debug.assert(font_size > 0);
    std.debug.assert(initial.len <= field_buf_max); // a field value never exceeds the buffer
    if (objc.get_class("UIFont")) |UIFont| {
        const fs = @as(objc.CGFloat, font_size);
        const font = objc.msg_send(objc.Id, UIFont, "systemFontOfSize:", .{fs});
        objc.msg_send(void, f, "setFont:", .{font});
    }
    if (objc.get_class("UIColor")) |UIColor| {
        const col = objc.msg_send(objc.Id, UIColor, "colorWithRed:green:blue:alpha:", .{
            @as(objc.CGFloat, color.r),
            @as(objc.CGFloat, color.g),
            @as(objc.CGFloat, color.b),
            @as(objc.CGFloat, color.a),
        });
        objc.msg_send(void, f, "setTextColor:", .{col});
    }
    objc.msg_send(void, f, "setSecureTextEntry:", .{if (secure) objc.YES else objc.NO});
    const kb = if (numeric) keyboard_type_number_pad else keyboard_type_default;
    objc.msg_send(void, f, "setKeyboardType:", .{kb});
    var buf: [field_buf_max]u8 = undefined;
    objc.msg_send(void, f, "setText:", .{ns_string_stack(&buf, initial)});
}

pub fn hide_text_field(handle: CustomShellHandle) void {
    _ = handle;
    if (!g_visible) return;
    std.debug.assert(g_field != null); // visible implies the field was created
    if (g_field) |f| {
        objc.msg_send(void, f, "setHidden:", .{objc.YES});
        _ = objc.msg_send(bool, f, "resignFirstResponder", .{});
    }
    g_visible = false;
}

pub fn text_field_value(buf: []u8) []const u8 {
    std.debug.assert(buf.len > 0);
    const f = g_field orelse return "";
    const s = objc.msg_send(objc.Id, f, "text", .{});
    if (@intFromPtr(s) == 0) return ""; // an empty UITextField hands back nil
    const cstr = objc.msg_send([*:0]const u8, s, "UTF8String", .{});
    var i: usize = 0;
    while (i < buf.len and cstr[i] != 0) : (i += 1) buf[i] = cstr[i];
    std.debug.assert(i <= buf.len); // the copy never ran past the caller's buffer
    return buf[0..i];
}

fn ns_string_stack(buf: []u8, s: []const u8) objc.Id {
    std.debug.assert(buf.len > 0);
    const NSString = objc.get_class("NSString") orelse unreachable;
    const n = @min(s.len, buf.len - 1);
    std.debug.assert(n < buf.len);
    @memcpy(buf[0..n], s[0..n]);
    buf[n] = 0;
    const cstr: [*:0]const u8 = @ptrCast(buf.ptr);
    return objc.msg_send(objc.Id, NSString, "stringWithUTF8String:", .{cstr});
}

pub fn pasteboard_read_into(buf: []u8) []const u8 {
    _ = buf;
    return "";
}

pub fn pasteboard_write_string(text: []const u8) void {
    _ = text;
}

pub fn clipboard_changed_external() bool {
    return false;
}

pub fn display_count() u32 {
    return 1;
}

pub fn display_bounds(index: u32) geometry.BoundsF {
    std.debug.assert(index == 0);
    const window = g_window orelse return .{};
    return .{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{
            .width = @floatFromInt(window.width_pt),
            .height = @floatFromInt(window.height_pt),
        },
    };
}
