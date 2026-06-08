const std = @import("std");
const objc = @import("objc.zig");
const types = @import("../../window/types.zig");

const Id = objc.Id;
const Sel = objc.Sel;
const Class = objc.Class;
const NSRect = objc.NSRect;
const NSPoint = objc.NSPoint;
const NSSize = objc.NSSize;
const NSUInteger = objc.NSUInteger;
const NSInteger = objc.NSInteger;
const CGFloat = objc.CGFloat;

const NSWindowStyleMaskTitled: NSUInteger = 1 << 0;
const NSWindowStyleMaskClosable: NSUInteger = 1 << 1;
const NSWindowStyleMaskMiniaturizable: NSUInteger = 1 << 2;
const NSWindowStyleMaskResizable: NSUInteger = 1 << 3;
const NSWindowStyleMaskFullSizeContentView: NSUInteger = 1 << 15;
const NSBackingStoreBuffered: NSUInteger = 2;

const NSViewWidthSizable: NSUInteger = 1 << 1;
const NSViewHeightSizable: NSUInteger = 1 << 4;

const NSVisualEffectMaterialSidebar: NSUInteger = 7;
const NSVisualEffectMaterialUnderWindowBackground: NSUInteger = 21;
const NSVisualEffectBlendingModeBehindWindow: NSUInteger = 0;
const NSVisualEffectStateActive: NSUInteger = 1;

const NSWindowTitleVisible: NSUInteger = 0;
const NSWindowTitleHidden: NSUInteger = 1;
const NSWindowToolbarStyleUnified: NSInteger = 3;

const CGSize = extern struct { width: CGFloat, height: CGFloat };
const NSEdgeInsets = extern struct {
    top: CGFloat,
    left: CGFloat,
    bottom: CGFloat,
    right: CGFloat,
};

const MAX_NSSTRING_BYTES: usize = 512;

pub const Error = error{
    NoNSWindowClass,
    NoNSViewClass,
    NoCAMetalLayerClass,
    NSWindowInitFailed,
};

pub const KeyMods = packed struct {
    cmd: bool = false,
    shift: bool = false,
    alt: bool = false,
    ctrl: bool = false,
};

// Decoded from the first unichar of charactersIgnoringModifiers. .char carries a
// printable codepoint in KeyEvent.ch (Shift applied; Cmd/Opt/Ctrl ignored, so
// Cmd-K arrives as .char ch='k' mods.cmd). The rest are control/navigation keys.
pub const KeyCode = enum(u8) {
    char,
    left,
    right,
    up,
    down,
    backspace,
    delete_fwd,
    enter,
    tab,
    escape,
    home,
    end,
    page_up,
    page_down,
};

pub const KeyEvent = struct {
    code: KeyCode = .char,
    ch: u21 = 0, // codepoint when code == .char
    mods: KeyMods = .{},
};

pub const MouseDispatch = struct {
    on_move: *const fn (ctx: *anyopaque, x: f32, y: f32) void,
    on_exit: *const fn (ctx: *anyopaque) void,
    on_down: *const fn (ctx: *anyopaque, x: f32, y: f32) void,
    on_right_down: *const fn (ctx: *anyopaque, x: f32, y: f32) void,
    on_drag: *const fn (ctx: *anyopaque, x: f32, y: f32) void,
    on_up: *const fn (ctx: *anyopaque) void,
    on_scroll: *const fn (ctx: *anyopaque, dx: f32, dy: f32) void,
    on_key: *const fn (ctx: *anyopaque, ev: KeyEvent) void,
    ctx: *anyopaque,
};

// AppKit NSEventModifierFlag bits.
const MOD_SHIFT: NSUInteger = 1 << 17;
const MOD_CONTROL: NSUInteger = 1 << 18;
const MOD_OPTION: NSUInteger = 1 << 19;
const MOD_COMMAND: NSUInteger = 1 << 20;

var g_mouse_dispatch: ?MouseDispatch = null;
var g_custom_body_class: ?Class = null;

pub fn register_mouse_dispatch(d: MouseDispatch) void {
    g_mouse_dispatch = d;
}

// The paint layer's titlebar hit-test, so a press on the band background can be
// told apart from one on a titlebar control. The band height is stashed at open.
pub const HitTestFn = *const fn (ctx: *anyopaque, x: f32, y: f32, band_h: f32) bool;
pub const RedrawFn = *const fn (ctx: *anyopaque) void;
var g_hit_test: ?HitTestFn = null;
var g_hit_ctx: ?*anyopaque = null;
var g_titlebar_band_h: f32 = 0;

pub fn register_hit_test(hit_test_cb: HitTestFn, redraw_cb: RedrawFn, ctx: *anyopaque) void {
    g_hit_test = hit_test_cb;
    g_hit_ctx = ctx;
    _ = redraw_cb; // macOS redraws on its own; only Windows needs the paint poke
}

fn is_flipped_yes_imp(_: Id, _: Sel) callconv(.c) bool {
    return true;
}

fn custom_body_mouse_down_imp(self: Id, _: Sel, event: Id) callconv(.c) void {
    const d = g_mouse_dispatch orelse return;
    const win_loc: NSPoint = objc.msg_send(NSPoint, event, "locationInWindow", .{});
    const loc: NSPoint = objc.msg_send(
        NSPoint,
        self,
        "convertPoint:fromView:",
        .{ win_loc, @as(?Id, null) },
    );
    const lx: f32 = @floatCast(loc.x);
    const ly: f32 = @floatCast(loc.y);
    // A press on the title-band background (not over a titlebar control) belongs to
    // AppKit: it owns window drag AND the double-click zoom/minimize the system
    // preference selects. Our full-size body view would otherwise swallow both.
    if (g_titlebar_band_h > 0 and ly < g_titlebar_band_h) {
        const over_ctrl = if (g_hit_test) |ht| blk: {
            std.debug.assert(g_hit_ctx != null); // set together with g_hit_test
            break :blk ht(g_hit_ctx.?, lx, ly, g_titlebar_band_h);
        } else false;
        const clicks: isize = objc.msg_send(isize, event, "clickCount", .{});
        if (!over_ctrl) {
            const win = objc.msg_send(Id, self, "window", .{});
            // performWindowDragWithEvent handles the drag but not the double-click
            // zoom, so dispatch that explicitly (full-size maximize / restore).
            if (clicks >= 2) {
                objc.msg_send(void, win, "zoom:", .{@as(?Id, null)});
            } else {
                objc.msg_send(void, win, "performWindowDragWithEvent:", .{event});
            }
            return;
        }
    }
    d.on_down(d.ctx, lx, ly);
}

fn custom_body_right_mouse_down_imp(self: Id, _: Sel, event: Id) callconv(.c) void {
    const d = g_mouse_dispatch orelse return;
    const win_loc: NSPoint = objc.msg_send(NSPoint, event, "locationInWindow", .{});
    const loc: NSPoint = objc.msg_send(
        NSPoint,
        self,
        "convertPoint:fromView:",
        .{ win_loc, @as(?Id, null) },
    );
    d.on_right_down(d.ctx, @floatCast(loc.x), @floatCast(loc.y));
}

fn custom_body_mouse_moved_imp(self: Id, _: Sel, event: Id) callconv(.c) void {
    const d = g_mouse_dispatch orelse return;
    const win_loc: NSPoint = objc.msg_send(NSPoint, event, "locationInWindow", .{});
    const loc: NSPoint = objc.msg_send(
        NSPoint,
        self,
        "convertPoint:fromView:",
        .{ win_loc, @as(?Id, null) },
    );
    d.on_move(d.ctx, @floatCast(loc.x), @floatCast(loc.y));
}

fn custom_body_mouse_dragged_imp(self: Id, _: Sel, event: Id) callconv(.c) void {
    const d = g_mouse_dispatch orelse return;
    const win_loc: NSPoint = objc.msg_send(NSPoint, event, "locationInWindow", .{});
    const loc: NSPoint = objc.msg_send(
        NSPoint,
        self,
        "convertPoint:fromView:",
        .{ win_loc, @as(?Id, null) },
    );
    d.on_drag(d.ctx, @floatCast(loc.x), @floatCast(loc.y));
}

fn custom_body_mouse_up_imp(_: Id, _: Sel, _: Id) callconv(.c) void {
    const d = g_mouse_dispatch orelse return;
    d.on_up(d.ctx);
}

fn custom_body_mouse_exited_imp(_: Id, _: Sel, _: Id) callconv(.c) void {
    const d = g_mouse_dispatch orelse return;
    d.on_exit(d.ctx);
}

fn custom_body_scroll_wheel_imp(_: Id, _: Sel, event: Id) callconv(.c) void {
    const d = g_mouse_dispatch orelse return;
    const dx: CGFloat = objc.msg_send(CGFloat, event, "scrollingDeltaX", .{});
    const dy: CGFloat = objc.msg_send(CGFloat, event, "scrollingDeltaY", .{});
    d.on_scroll(d.ctx, @floatCast(dx), @floatCast(dy));
}

// YES so the body view gets keyDown: while it's the window's first responder.
fn accepts_first_responder_yes_imp(_: Id, _: Sel) callconv(.c) bool {
    return true;
}

pub const CursorKind = enum { default, col_resize, row_resize };
var g_cursor: CursorKind = .default;

fn ns_cursor(kind: CursorKind) ?Id {
    const NSCursor = objc.get_class("NSCursor") orelse return null;
    return switch (kind) {
        .default => objc.msg_send(Id, NSCursor, "arrowCursor", .{}),
        .col_resize => objc.msg_send(Id, NSCursor, "resizeLeftRightCursor", .{}),
        .row_resize => objc.msg_send(Id, NSCursor, "resizeUpDownCursor", .{}),
    };
}

// Consumer requests a cursor each frame; only act on a change so AppKit's own
// cursor management isn't fought every tick. Over a focused native text field
// AppKit re-asserts the I-beam via its cursor rects, so a one-shot arrow here is
// harmless and transient.
pub fn apply_cursor(kind: CursorKind) void {
    if (kind == g_cursor) return;
    g_cursor = kind;
    if (ns_cursor(kind)) |c| objc.msg_send(void, c, "set", .{});
}

// AppKit re-asserts the cursor as the mouse moves over the tracking area; keep
// it on the requested one.
fn custom_body_cursor_update_imp(_: Id, _: Sel, _: Id) callconv(.c) void {
    if (ns_cursor(g_cursor)) |c| objc.msg_send(void, c, "set", .{});
}

// AppKit function-key unichars (NSEvent.h, 0xF7xx private-use range) plus the
// control chars charactersIgnoringModifiers returns for the editing keys.
const FK_UP: u16 = 0xF700;
const FK_DOWN: u16 = 0xF701;
const FK_LEFT: u16 = 0xF702;
const FK_RIGHT: u16 = 0xF703;
const FK_DELETE_FWD: u16 = 0xF728;
const FK_HOME: u16 = 0xF729;
const FK_END: u16 = 0xF72B;
const FK_PAGE_UP: u16 = 0xF72C;
const FK_PAGE_DOWN: u16 = 0xF72D;
const CH_TAB: u16 = 0x09;
const CH_ENTER: u16 = 0x0D;
const CH_ESCAPE: u16 = 0x1B;
const CH_BACKSPACE: u16 = 0x7F; // the Backspace key reports DEL, not 0x08

fn key_code_for(ch: u16) KeyCode {
    return switch (ch) {
        FK_LEFT => .left,
        FK_RIGHT => .right,
        FK_UP => .up,
        FK_DOWN => .down,
        FK_DELETE_FWD => .delete_fwd,
        FK_HOME => .home,
        FK_END => .end,
        FK_PAGE_UP => .page_up,
        FK_PAGE_DOWN => .page_down,
        CH_TAB => .tab,
        CH_ENTER => .enter,
        CH_ESCAPE => .escape,
        CH_BACKSPACE => .backspace,
        else => .char,
    };
}

fn custom_body_key_down_imp(_: Id, _: Sel, event: Id) callconv(.c) void {
    const d = g_mouse_dispatch orelse return;
    const chars: Id = objc.msg_send(Id, event, "charactersIgnoringModifiers", .{});
    if (@intFromPtr(chars) == 0) return;
    const len: NSUInteger = objc.msg_send(NSUInteger, chars, "length", .{});
    if (len == 0) return;
    // First BMP unichar only; surrogate pairs and dead-key composition not handled.
    const ch: u16 = objc.msg_send(u16, chars, "characterAtIndex:", .{@as(NSUInteger, 0)});
    const flags: NSUInteger = objc.msg_send(NSUInteger, event, "modifierFlags", .{});
    const code = key_code_for(ch);
    d.on_key(d.ctx, .{
        .code = code,
        .ch = if (code == .char) @as(u21, ch) else 0,
        .mods = .{
            .cmd = (flags & MOD_COMMAND) != 0,
            .shift = (flags & MOD_SHIFT) != 0,
            .alt = (flags & MOD_OPTION) != 0,
            .ctrl = (flags & MOD_CONTROL) != 0,
        },
    });
}

const NSTrackingMouseEnteredAndExited: NSUInteger = 0x01;
const NSTrackingMouseMoved: NSUInteger = 0x02;
const NSTrackingCursorUpdate: NSUInteger = 0x04;
const NSTrackingActiveInActiveApp: NSUInteger = 0x40;
const NSTrackingInVisibleRect: NSUInteger = 0x200;

fn custom_body_update_tracking_areas_imp(self: Id, _: Sel) callconv(.c) void {
    const prior: Id = objc.msg_send(Id, self, "trackingAreas", .{});
    if (@intFromPtr(prior) != 0) {
        const count: NSUInteger = objc.msg_send(NSUInteger, prior, "count", .{});
        var i: NSUInteger = 0;
        while (i < count) : (i += 1) {
            const ta = objc.msg_send(Id, prior, "objectAtIndex:", .{i});
            objc.msg_send(void, self, "removeTrackingArea:", .{ta});
        }
    }
    const NSTrackingArea = objc.get_class("NSTrackingArea") orelse return;
    const bounds: NSRect = objc.msg_send(NSRect, self, "bounds", .{});
    const opts: NSUInteger = NSTrackingMouseEnteredAndExited |
        NSTrackingMouseMoved |
        NSTrackingCursorUpdate |
        NSTrackingActiveInActiveApp |
        NSTrackingInVisibleRect;
    const ta_alloc = objc.alloc(NSTrackingArea);
    const ta = objc.msg_send(Id, ta_alloc, "initWithRect:options:owner:userInfo:", .{
        bounds, opts, self, @as(?Id, null),
    });
    objc.msg_send(void, self, "addTrackingArea:", .{ta});
}

fn ensure_custom_body_class() ?Class {
    if (g_custom_body_class) |c| return c;
    const NSView_cls = objc.get_class("NSView") orelse return null;
    const cls = objc.objc_allocateClassPair(NSView_cls, "ZigUICustomBody", 0) orelse return null;
    _ = objc.class_addMethod(cls, objc.sel("isFlipped"), @ptrCast(&is_flipped_yes_imp), "B@:");
    _ = objc.class_addMethod(
        cls,
        objc.sel("mouseDown:"),
        @ptrCast(&custom_body_mouse_down_imp),
        "v@:@",
    );
    _ = objc.class_addMethod(
        cls,
        objc.sel("rightMouseDown:"),
        @ptrCast(&custom_body_right_mouse_down_imp),
        "v@:@",
    );
    _ = objc.class_addMethod(
        cls,
        objc.sel("mouseDragged:"),
        @ptrCast(&custom_body_mouse_dragged_imp),
        "v@:@",
    );
    _ = objc.class_addMethod(
        cls,
        objc.sel("mouseUp:"),
        @ptrCast(&custom_body_mouse_up_imp),
        "v@:@",
    );
    _ = objc.class_addMethod(
        cls,
        objc.sel("mouseMoved:"),
        @ptrCast(&custom_body_mouse_moved_imp),
        "v@:@",
    );
    _ = objc.class_addMethod(
        cls,
        objc.sel("mouseExited:"),
        @ptrCast(&custom_body_mouse_exited_imp),
        "v@:@",
    );
    _ = objc.class_addMethod(
        cls,
        objc.sel("scrollWheel:"),
        @ptrCast(&custom_body_scroll_wheel_imp),
        "v@:@",
    );
    _ = objc.class_addMethod(
        cls,
        objc.sel("keyDown:"),
        @ptrCast(&custom_body_key_down_imp),
        "v@:@",
    );
    _ = objc.class_addMethod(
        cls,
        objc.sel("acceptsFirstResponder"),
        @ptrCast(&accepts_first_responder_yes_imp),
        "B@:",
    );
    _ = objc.class_addMethod(
        cls,
        objc.sel("cursorUpdate:"),
        @ptrCast(&custom_body_cursor_update_imp),
        "v@:@",
    );
    _ = objc.class_addMethod(
        cls,
        objc.sel("updateTrackingAreas"),
        @ptrCast(&custom_body_update_tracking_areas_imp),
        "v@:",
    );
    objc.objc_registerClassPair(cls);
    g_custom_body_class = cls;
    return cls;
}

pub const CustomShellHandle = struct {
    window: Id,
    content_view: Id,
    metal_layer: Id,
    height: f32,
    // Resolved at open: the paint loop reads these to draw the default titlebar
    // band + inset the body, with no per-frame option plumbing.
    theme: types.Theme,
    titlebar: types.TitlebarOptions,

    pub fn focus(self: CustomShellHandle) void {
        const NSApplication = objc.get_class("NSApplication") orelse return;
        const app = objc.msg_send(Id, NSApplication, "sharedApplication", .{});
        objc.msg_send(void, app, "activateIgnoringOtherApps:", .{objc.YES});
        objc.msg_send(void, self.window, "makeKeyAndOrderFront:", .{@as(?Id, null)});
    }

    pub fn get_content_size(self: CustomShellHandle) NSSize {
        const frame: NSRect = objc.msg_send(NSRect, self.content_view, "frame", .{});
        return frame.size;
    }

    pub fn sync_drawable_size(self: CustomShellHandle) NSSize {
        const size = self.get_content_size();
        const scale: CGFloat = objc.msg_send(CGFloat, self.window, "backingScaleFactor", .{});
        const drawable = CGSize{ .width = size.width * scale, .height = size.height * scale };
        objc.msg_send(void, self.metal_layer, "setDrawableSize:", .{drawable});
        return size;
    }

    pub fn deinit(self: CustomShellHandle) void {
        objc.msg_send(void, self.window, "release", .{});
    }
};

const NSWindowCloseButton: NSUInteger = 0;
const NSWindowMiniaturizeButton: NSUInteger = 1;
const NSWindowZoomButton: NSUInteger = 2;

// center_y is top-down points; the button superview (theme frame) is not
// flipped, so convert y to bottom-up. dx is computed once from the close button
// and applied to all three so the cluster keeps its spacing while its left edge
// lands where the caller wants.
fn center_traffic_light(window: Id, which: NSUInteger, center_y: CGFloat, dx: CGFloat) void {
    const btn = objc.msg_send(?Id, window, "standardWindowButton:", .{which}) orelse return;
    if (@intFromPtr(btn) == 0) return;
    const sv = objc.msg_send(?Id, btn, "superview", .{}) orelse return;
    const svf: NSRect = objc.msg_send(NSRect, sv, "frame", .{});
    const bf: NSRect = objc.msg_send(NSRect, btn, "frame", .{});
    const new_y = svf.size.height - center_y - bf.size.height / 2.0;
    objc.msg_send(void, btn, "setFrameOrigin:", .{NSPoint{ .x = bf.origin.x + dx, .y = new_y }});
}

fn close_button_x(window: Id) CGFloat {
    const which = NSWindowCloseButton;
    const btn = objc.msg_send(?Id, window, "standardWindowButton:", .{which}) orelse return 0;
    if (@intFromPtr(btn) == 0) return 0;
    const bf: NSRect = objc.msg_send(NSRect, btn, "frame", .{});
    return bf.origin.x;
}

// Stashed so the delegate can re-apply after AppKit relays out the buttons
// (resize / fullscreen). _x = desired close button left edge; 0 leaves the
// horizontal default.
var g_traffic_light_y: CGFloat = 0;
var g_traffic_light_x: CGFloat = 0;
var g_window_delegate_class: ?Class = null;
var g_window_delegate: ?Id = null;

fn recenter_traffic_lights(window: Id) void {
    if (g_traffic_light_y <= 0) return;
    const dx = if (g_traffic_light_x > 0) g_traffic_light_x - close_button_x(window) else 0;
    center_traffic_light(window, NSWindowCloseButton, g_traffic_light_y, dx);
    center_traffic_light(window, NSWindowMiniaturizeButton, g_traffic_light_y, dx);
    center_traffic_light(window, NSWindowZoomButton, g_traffic_light_y, dx);
}

fn window_did_resize_imp(_: Id, _: Sel, notif: Id) callconv(.c) void {
    const win = objc.msg_send(Id, notif, "object", .{});
    if (@intFromPtr(win) != 0) recenter_traffic_lights(win);
}

fn ensure_window_delegate() ?Id {
    if (g_window_delegate) |d| return d;
    const NSObject = objc.get_class("NSObject") orelse return null;
    const cls = g_window_delegate_class orelse blk: {
        const c = objc.objc_allocateClassPair(
            NSObject,
            "ZigUICustomWindowDelegate",
            0,
        ) orelse return null;
        // AppKit resets standard-button frames on relayout; re-apply after.
        _ = objc.class_addMethod(
            c,
            objc.sel("windowDidResize:"),
            @ptrCast(&window_did_resize_imp),
            "v@:@",
        );
        _ = objc.class_addMethod(
            c,
            objc.sel("windowDidExitFullScreen:"),
            @ptrCast(&window_did_resize_imp),
            "v@:@",
        );
        objc.objc_registerClassPair(c);
        g_window_delegate_class = c;
        break :blk c;
    };
    const obj = objc.msg_send(Id, objc.alloc(cls), "init", .{});
    g_window_delegate = obj;
    return obj;
}

// The immediate-mode UI draws the box; a real NSTextField (NSSecureTextField for
// a masked password) sits over the focused field's text area so typing lands in
// place. One editor at a time, shared across every input: the caller's field id
// and secure flag drive when the text is re-seeded, so moving between inputs
// swaps cleanly.
var g_field: ?Id = null;
var g_secure_field: ?Id = null;
var g_visible: bool = false;
var g_active_secure: bool = false;
var g_active_id: u32 = 0;

const NSFocusRingTypeNone: NSUInteger = 1;
const NSNumberFormatterDecimalStyle: NSUInteger = 1;

// Rejecting non-numeric keystrokes is what makes a number input numeric, not the
// steppers. NSTextField asks the formatter to validate each partial edit, so
// letters never land.
var g_int_fmt: ?Id = null;
fn int_formatter() ?Id {
    if (g_int_fmt) |f| return f;
    const NSNumberFormatter = objc.get_class("NSNumberFormatter") orelse return null;
    const f = objc.msg_send(Id, objc.alloc(NSNumberFormatter), "init", .{});
    objc.msg_send(void, f, "setNumberStyle:", .{NSNumberFormatterDecimalStyle});
    objc.msg_send(void, f, "setMaximumFractionDigits:", .{@as(NSUInteger, 0)});
    objc.msg_send(void, f, "setAllowsFloats:", .{objc.NO});
    objc.msg_send(void, f, "setUsesGroupingSeparator:", .{objc.NO});
    g_int_fmt = f;
    return f;
}

fn ensure_field(content_view: Id, secure: bool) ?Id {
    if (secure) {
        if (g_secure_field) |f| return f;
    } else {
        if (g_field) |f| return f;
    }
    const cls_name = if (secure) "NSSecureTextField" else "NSTextField";
    const cls = objc.get_class(cls_name) orelse return null;
    const f = objc.msg_send(Id, objc.alloc(cls), "initWithFrame:", .{NSRect{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{ .width = 100, .height = 22 },
    }});
    objc.msg_send(void, f, "setBordered:", .{objc.NO});
    objc.msg_send(void, f, "setBezeled:", .{objc.NO});
    objc.msg_send(void, f, "setDrawsBackground:", .{objc.NO});
    objc.msg_send(void, f, "setEditable:", .{objc.YES});
    objc.msg_send(void, f, "setSelectable:", .{objc.YES});
    objc.msg_send(void, f, "setFocusRingType:", .{NSFocusRingTypeNone});
    objc.msg_send(void, f, "setHidden:", .{objc.YES});
    objc.msg_send(void, content_view, "addSubview:", .{f});
    if (secure) g_secure_field = f else g_field = f;
    return f;
}

// (x,y,w,h) are content-view flipped coords = renderer points. Re-seeds the text
// only when the active field changes (id / secure), so live typing isn't
// clobbered each frame.
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
) void {
    std.debug.assert(id != 0); // 0 is the inactive sentinel for g_active_id
    const f = ensure_field(handle.content_view, secure) orelse return;
    objc.msg_send(void, f, "setFrame:", .{NSRect{
        .origin = .{ .x = x, .y = y },
        .size = .{ .width = w, .height = h },
    }});
    if (!g_visible or g_active_secure != secure or g_active_id != id) {
        // Font + colour stay constant while a field is focused, so resolve and
        // apply them only on (re)seed - colorWithRed: allocs an NSColor per call,
        // which on the per-frame path would be pure waste.
        if (objc.get_class("NSFont")) |NSFont| {
            const fs = @as(CGFloat, font_size);
            const font = objc.msg_send(Id, NSFont, "systemFontOfSize:", .{fs});
            objc.msg_send(void, f, "setFont:", .{font});
        }
        if (objc.get_class("NSColor")) |NSColor| {
            const col = objc.msg_send(Id, NSColor, "colorWithRed:green:blue:alpha:", .{
                @as(CGFloat, color.r),
                @as(CGFloat, color.g),
                @as(CGFloat, color.b),
                @as(CGFloat, color.a),
            });
            objc.msg_send(void, f, "setTextColor:", .{col});
        }
        if (g_active_secure != secure) {
            const other = if (secure) g_field else g_secure_field;
            if (other) |o| objc.msg_send(void, o, "setHidden:", .{objc.YES});
        }
        // Plain field is shared by text + numeric inputs; (un)set the formatter
        // per focus so only the number field rejects letters.
        if (!secure) {
            const formatter = if (numeric) int_formatter() else @as(?Id, null);
            objc.msg_send(void, f, "setFormatter:", .{formatter});
        }
        var buf: [MAX_NSSTRING_BYTES]u8 = undefined;
        objc.msg_send(void, f, "setStringValue:", .{nsstring_from_stack(&buf, initial)});
        objc.msg_send(void, f, "setHidden:", .{objc.NO});
        objc.msg_send(void, handle.window, "makeFirstResponder:", .{f});
        g_visible = true;
        g_active_secure = secure;
        g_active_id = id;
    }
}

pub fn hide_text_field() void {
    if (!g_visible) return;
    if (g_field) |f| objc.msg_send(void, f, "setHidden:", .{objc.YES});
    if (g_secure_field) |f| objc.msg_send(void, f, "setHidden:", .{objc.YES});
    g_visible = false;
}

pub fn text_field_value(buf: []u8) []const u8 {
    std.debug.assert(buf.len > 0);
    const f = (if (g_active_secure) g_secure_field else g_field) orelse return "";
    const s = objc.msg_send(Id, f, "stringValue", .{});
    const cstr = objc.msg_send([*:0]const u8, s, "UTF8String", .{});
    var i: usize = 0;
    while (i < buf.len and cstr[i] != 0) : (i += 1) buf[i] = cstr[i];
    return buf[0..i];
}

fn nsstring_from_stack(buf: []u8, s: []const u8) Id {
    std.debug.assert(buf.len > 0); // buf.len - 1 below underflows on an empty buffer
    const NSString = objc.get_class("NSString") orelse unreachable;
    const n = @min(s.len, buf.len - 1);
    @memcpy(buf[0..n], s[0..n]);
    buf[n] = 0;
    const cstr_ptr: [*:0]const u8 = @ptrCast(buf.ptr);
    return objc.msg_send(Id, NSString, "stringWithUTF8String:", .{cstr_ptr});
}

// UTI for plain UTF-8 text (NSPasteboardTypeString). Built once as an NSString
// and cached; the read/write calls want an NSString type.
const PASTEBOARD_TYPE = "public.utf8-plain-text";
var g_pb_type: ?Id = null;

fn pasteboard_type() Id {
    if (g_pb_type) |t| return t;
    const NSString = objc.get_class("NSString") orelse unreachable;
    const pb_type_cstr = @as([*:0]const u8, PASTEBOARD_TYPE);
    const t = objc.msg_send(Id, NSString, "stringWithUTF8String:", .{pb_type_cstr});
    // Retain so it survives past the autorelease pool of this call.
    _ = objc.msg_send(Id, t, "retain", .{});
    g_pb_type = t;
    return t;
}

fn general_pasteboard() ?Id {
    const NSPasteboard = objc.get_class("NSPasteboard") orelse return null;
    const pb = objc.msg_send(Id, NSPasteboard, "generalPasteboard", .{});
    return if (@intFromPtr(pb) == 0) null else pb;
}

// The UTF8String pointer is an inner pointer valid only until the autorelease
// pool drains, so the bytes are copied out immediately.
pub fn pasteboard_read_into(buf: []u8) []const u8 {
    std.debug.assert(buf.len > 0);
    const pb = general_pasteboard() orelse return "";
    const s = objc.msg_send(Id, pb, "stringForType:", .{pasteboard_type()});
    if (@intFromPtr(s) == 0) return "";
    const cstr = objc.msg_send([*:0]const u8, s, "UTF8String", .{});
    var i: usize = 0;
    while (i < buf.len and cstr[i] != 0) : (i += 1) buf[i] = cstr[i];
    return buf[0..i];
}

const NSUTF8StringEncoding: NSUInteger = 4;

// clearContents first, else other representations linger and a rich-text target
// pastes stale data. stringWithBytes:length:encoding: takes the slice directly
// (no NUL, no stack copy, no length cap) so a large body isn't truncated or cut
// mid-codepoint.
pub fn pasteboard_write_string(text: []const u8) void {
    const pb = general_pasteboard() orelse return;
    const NSString = objc.get_class("NSString") orelse return;
    const ns = objc.msg_send(Id, NSString, "stringWithBytes:length:encoding:", .{
        @as(?*const anyopaque, text.ptr), @as(NSUInteger, text.len), NSUTF8StringEncoding,
    });
    if (@intFromPtr(ns) == 0) return; // invalid UTF-8 -> leave the clipboard alone
    _ = objc.msg_send(NSInteger, pb, "clearContents", .{});
    _ = objc.msg_send(bool, pb, "setString:forType:", .{ ns, pasteboard_type() });
}

// The mouse dispatch carries no modifier flags, so a shift-click reads live
// state here. Polling +[NSEvent modifierFlags] (not a per-event field) is fine:
// if Shift releases between dispatch and this read it degrades to a plain click,
// which is harmless.
pub fn current_shift_down() bool {
    const NSEvent = objc.get_class("NSEvent") orelse return false;
    const flags: NSUInteger = objc.msg_send(NSUInteger, NSEvent, "modifierFlags", .{});
    return (flags & MOD_SHIFT) != 0;
}

pub fn open(opts: types.NativeShellOptions) Error!CustomShellHandle {
    std.debug.assert(opts.width > 0);
    std.debug.assert(opts.height > 0);

    const NSWindow = objc.get_class("NSWindow") orelse return Error.NoNSWindowClass;
    const NSView = objc.get_class("NSView") orelse return Error.NoNSViewClass;
    const NSVisualEffectView = objc.get_class("NSVisualEffectView") orelse
        return Error.NoNSViewClass;
    const CAMetalLayer = objc.get_class("CAMetalLayer") orelse return Error.NoCAMetalLayerClass;
    const NSColor = objc.get_class("NSColor") orelse return Error.NoNSWindowClass;

    const window_alloc = objc.alloc(NSWindow);
    const frame: NSRect = .{
        .origin = .{ .x = 100, .y = 100 },
        .size = .{ .width = opts.width, .height = opts.height },
    };
    var style: NSUInteger =
        NSWindowStyleMaskTitled |
        NSWindowStyleMaskClosable |
        NSWindowStyleMaskMiniaturizable |
        NSWindowStyleMaskFullSizeContentView;
    if (opts.resizable) style |= NSWindowStyleMaskResizable;

    const window = objc.msg_send(
        Id,
        window_alloc,
        "initWithContentRect:styleMask:backing:defer:",
        .{ frame, style, NSBackingStoreBuffered, objc.NO },
    );
    if (@intFromPtr(window) == 0) return Error.NSWindowInitFailed;
    _ = objc.msg_send(Id, window, "retain", .{});
    errdefer objc.msg_send(void, window, "release", .{});

    var title_buf: [MAX_NSSTRING_BYTES]u8 = undefined;
    objc.msg_send(void, window, "setTitle:", .{nsstring_from_stack(&title_buf, opts.title)});
    // Custom shells draw their own chrome, so hide the system title text - it
    // would collide with a full-width top bar.
    objc.msg_send(void, window, "setTitleVisibility:", .{NSWindowTitleHidden});
    objc.msg_send(void, window, "setTitlebarAppearsTransparent:", .{objc.YES});

    if (opts.feel != .flat) {
        const clear = objc.msg_send(Id, NSColor, "clearColor", .{});
        objc.msg_send(void, window, "setBackgroundColor:", .{clear});
        objc.msg_send(void, window, "setOpaque:", .{objc.NO});
    }

    const content_w = opts.width;
    const content_h = opts.height;
    const autoresize_mask = @as(c_uint, NSViewWidthSizable | NSViewHeightSizable);

    const root_view: Id = blk: {
        switch (opts.feel) {
            .liquid_glass => {
                const ve_alloc = objc.alloc(NSVisualEffectView);
                const ve = objc.msg_send(Id, ve_alloc, "initWithFrame:", .{NSRect{
                    .origin = .{ .x = 0, .y = 0 },
                    .size = .{ .width = content_w, .height = content_h },
                }});
                objc.msg_send(void, ve, "setMaterial:", .{
                    NSVisualEffectMaterialUnderWindowBackground,
                });
                objc.msg_send(void, ve, "setBlendingMode:", .{
                    NSVisualEffectBlendingModeBehindWindow,
                });
                objc.msg_send(void, ve, "setState:", .{NSVisualEffectStateActive});
                objc.msg_send(void, ve, "setAutoresizingMask:", .{autoresize_mask});
                break :blk ve;
            },
            .flat, .transparent => {
                const v_alloc = objc.alloc(NSView);
                const v = objc.msg_send(Id, v_alloc, "initWithFrame:", .{NSRect{
                    .origin = .{ .x = 0, .y = 0 },
                    .size = .{ .width = content_w, .height = content_h },
                }});
                objc.msg_send(void, v, "setAutoresizingMask:", .{autoresize_mask});
                break :blk v;
            },
        }
    };
    // Owned (retain 1) until setContentView below retains it; release on any error
    // return before then so it can't leak.
    errdefer objc.msg_send(void, root_view, "release", .{});

    const body_cls = ensure_custom_body_class() orelse return Error.NoNSViewClass;
    const metal_view_alloc = objc.alloc(body_cls);
    const metal_view = objc.msg_send(Id, metal_view_alloc, "initWithFrame:", .{NSRect{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{ .width = content_w, .height = content_h },
    }});
    objc.msg_send(void, metal_view, "setAutoresizingMask:", .{autoresize_mask});
    objc.msg_send(void, metal_view, "setWantsLayer:", .{objc.YES});

    const metal_layer = objc.msg_send(Id, CAMetalLayer, "layer", .{});
    const scale: CGFloat = objc.msg_send(CGFloat, window, "backingScaleFactor", .{});
    objc.msg_send(void, metal_layer, "setContentsScale:", .{scale});
    objc.msg_send(void, metal_layer, "setDrawableSize:", .{CGSize{
        .width = content_w * scale,
        .height = content_h * scale,
    }});
    objc.msg_send(void, metal_layer, "setNeedsDisplayOnBoundsChange:", .{objc.YES});
    objc.msg_send(void, metal_layer, "setAutoresizingMask:", .{
        @as(c_uint, NSViewWidthSizable | NSViewHeightSizable),
    });
    objc.msg_send(void, metal_layer, "setOpaque:", .{objc.NO});
    objc.msg_send(void, metal_view, "setLayer:", .{metal_layer});
    objc.msg_send(void, root_view, "addSubview:", .{metal_view});

    objc.msg_send(void, window, "setContentView:", .{root_view});
    // Body view as first responder so it gets keyDown: for shortcuts; a native
    // text field takes over while a field is being edited.
    _ = objc.msg_send(bool, window, "makeFirstResponder:", .{metal_view});
    objc.msg_send(void, window, "setMinSize:", .{NSSize{
        .width = opts.min_width,
        .height = opts.min_height,
    }});
    objc.msg_send(void, window, "setAcceptsMouseMovedEvents:", .{objc.YES});
    objc.msg_send(void, window, "center", .{});

    // An explicit override wins, else derive from the default titlebar (centered
    // on the band, left edge at the content pad) so the lights align with zero
    // caller tuning.
    const tb = opts.titlebar;
    g_titlebar_band_h = if (tb.enabled) @floatCast(tb.height) else 0;
    const tl_y: f64 = if (opts.traffic_light_y > 0)
        opts.traffic_light_y
    else if (tb.enabled) tb.height / 2 else 0;
    const tl_x: f64 = if (opts.traffic_light_x > 0)
        opts.traffic_light_x
    else if (tb.enabled) tb.content_left else 0;
    if (tl_y > 0) {
        g_traffic_light_y = @floatCast(tl_y);
        g_traffic_light_x = @floatCast(tl_x);
        recenter_traffic_lights(window);
        if (ensure_window_delegate()) |d| objc.msg_send(void, window, "setDelegate:", .{d});
    }

    return .{
        .window = window,
        .content_view = metal_view,
        .metal_layer = metal_layer,
        .height = @floatCast(opts.height),
        .theme = opts.theme orelse types.Theme.default_dark(),
        .titlebar = tb,
    };
}
