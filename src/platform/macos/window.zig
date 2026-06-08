const std = @import("std");
const objc = @import("objc.zig");
const events = @import("../../events.zig");
const color = @import("../../color.zig");
const types = @import("../../window/types.zig");
const mac_icon = @import("icon.zig");
const Icon = @import("../../icon.zig").Icon;

const Rgba = color.Rgba;

pub const ToolbarSeparator = types.ToolbarSeparator;
pub const NativeShellOptions = types.NativeShellOptions;
pub const SidebarKind = types.SidebarKind;
pub const SidebarEntry = types.SidebarEntry;
pub const SidebarSelectFn = types.SidebarSelectFn;
pub const SidebarReorderFn = types.SidebarReorderFn;
pub const ToolbarItemKind = types.ToolbarItemKind;
pub const ToolbarSubItem = types.ToolbarSubItem;
pub const ToolbarMenuItem = types.ToolbarMenuItem;
pub const ToolbarEntry = types.ToolbarEntry;
pub const ToolbarSelectFn = types.ToolbarSelectFn;
pub const ToolbarSearchFn = types.ToolbarSearchFn;
pub const ScrollEvent = types.ScrollEvent;
pub const ScrollFn = types.ScrollFn;
pub const BodyMouseEvent = types.BodyMouseEvent;
pub const BodyMouseFn = types.BodyMouseFn;
pub const BodyExitFn = types.BodyExitFn;
pub const AlertStyle = types.AlertStyle;
pub const AlertOptions = types.AlertOptions;
pub const AlertFn = types.AlertFn;
pub const FilePickerOptions = types.FilePickerOptions;
pub const FilePickerFn = types.FilePickerFn;

const Id = objc.Id;
const Sel = objc.Sel;
const Class = objc.Class;
const NSRect = objc.NSRect;
const NSPoint = objc.NSPoint;
const NSSize = objc.NSSize;
const NSUInteger = objc.NSUInteger;
const CGFloat = objc.CGFloat;

const Event = events.Event;
const Modifiers = events.Modifiers;
const MouseButton = events.MouseButton;

const ResignEntry = struct {
    ctx: *anyopaque,
    callback: *const fn (*anyopaque) void,
};

const MouseEntry = struct {
    ctx: *anyopaque,
    callback: *const fn (*anyopaque, Event) void,
};

var resign_map: std.AutoHashMapUnmanaged(usize, ResignEntry) = .empty;
var mouse_map: std.AutoHashMapUnmanaged(usize, MouseEntry) = .empty;
var panel_delegate_class: ?Class = null;
var shared_panel_delegate: ?Id = null;
var keyable_window_class: ?Class = null;
var panel_event_view_class: ?Class = null;

const NSEventModifierFlagShift: NSUInteger = 1 << 17;
const NSEventModifierFlagControl: NSUInteger = 1 << 18;
const NSEventModifierFlagOption: NSUInteger = 1 << 19;
const NSEventModifierFlagCommand: NSUInteger = 1 << 20;

const NSTrackingMouseEnteredAndExited: NSUInteger = 0x01;
const NSTrackingMouseMoved: NSUInteger = 0x02;
const NSTrackingActiveInActiveApp: NSUInteger = 0x40;
const NSTrackingInVisibleRect: NSUInteger = 0x200;

const NSWindowStyleMaskTitled: NSUInteger = 1 << 0;
const NSWindowStyleMaskClosable: NSUInteger = 1 << 1;
const NSWindowStyleMaskMiniaturizable: NSUInteger = 1 << 2;
const NSWindowStyleMaskResizable: NSUInteger = 1 << 3;
const NSBackingStoreBuffered: NSUInteger = 2;

const NSViewWidthSizable: NSUInteger = 1 << 1;
const NSViewHeightSizable: NSUInteger = 1 << 4;
const NSViewMinYMargin: NSUInteger = 1 << 3;

const CGSize = extern struct { width: CGFloat, height: CGFloat };

const NSEdgeInsets = extern struct {
    top: CGFloat,
    left: CGFloat,
    bottom: CGFloat,
    right: CGFloat,
};

const MAX_NSSTRING_BYTES: usize = 512;

// Ceiling on AppKit-returned child counts (tracking areas / subviews) we walk;
// past this is a leak or a corrupt array, not a real view tree.
const SUBVIEWS_MAX: NSUInteger = 4096;

pub const Error = error{
    NoNSWindowClass,
    NoNSTextFieldClass,
    NoNSViewClass,
    NoCAMetalLayerClass,
    NSWindowInitFailed,
};

pub const SimpleOptions = struct {
    title: []const u8,
    width: f64 = 360,
    height: f64 = 200,
    label: ?[]const u8 = null,
};

pub const Handle = struct {
    raw: Id,

    pub fn focus(self: Handle) void {
        const NSApplication = objc.get_class("NSApplication") orelse return;
        const app = objc.msg_send(Id, NSApplication, "sharedApplication", .{});
        objc.msg_send(void, app, "activateIgnoringOtherApps:", .{objc.YES});
        objc.msg_send(void, self.raw, "makeKeyAndOrderFront:", .{@as(?Id, null)});
    }
};

pub fn open_simple(opts: SimpleOptions) Error!Handle {
    std.debug.assert(opts.width > 0);
    std.debug.assert(opts.height > 0);

    const NSWindow = objc.get_class("NSWindow") orelse return Error.NoNSWindowClass;
    const window_alloc = objc.alloc(NSWindow);

    const frame: NSRect = .{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{ .width = opts.width, .height = opts.height },
    };
    const style: NSUInteger =
        NSWindowStyleMaskTitled |
        NSWindowStyleMaskClosable |
        NSWindowStyleMaskMiniaturizable;

    const window = objc.msg_send(
        Id,
        window_alloc,
        "initWithContentRect:styleMask:backing:defer:",
        .{
            frame,
            style,
            NSBackingStoreBuffered,
            objc.NO,
        },
    );
    if (@intFromPtr(window) == 0) return Error.NSWindowInitFailed;

    // NSWindow init returns autoreleased; retain so handle outlives the pool.
    _ = objc.msg_send(Id, window, "retain", .{});
    errdefer objc.msg_send(void, window, "release", .{});

    var title_buf: [MAX_NSSTRING_BYTES]u8 = undefined;
    objc.msg_send(void, window, "setTitle:", .{nsstring_from_stack(&title_buf, opts.title)});
    objc.msg_send(void, window, "center", .{});

    if (opts.label) |label_text| {
        const NSTextField = objc.get_class("NSTextField") orelse return Error.NoNSTextFieldClass;
        var label_buf: [MAX_NSSTRING_BYTES]u8 = undefined;
        const label_ns = nsstring_from_stack(&label_buf, label_text);
        const label = objc.msg_send(Id, NSTextField, "labelWithString:", .{label_ns});

        const label_h: f64 = 40;
        const label_frame: NSRect = .{
            .origin = .{ .x = 20, .y = (opts.height - label_h) / 2 },
            .size = .{ .width = opts.width - 40, .height = label_h },
        };
        objc.msg_send(void, label, "setFrame:", .{label_frame});

        const content_view = objc.msg_send(Id, window, "contentView", .{});
        objc.msg_send(void, content_view, "addSubview:", .{label});
    }

    const handle: Handle = .{ .raw = window };
    handle.focus();
    return handle;
}

pub const MetalOptions = struct {
    title: []const u8,
    width: f64 = 800,
    height: f64 = 600,
    resizable: bool = true,
};

pub const PanelMaterial = enum(NSUInteger) {
    menu = 5,
    popover = 6,
    sidebar = 7,
    hud = 8,
    fullscreen_ui = 15,
    under_window = 21,
};

pub const PanelOptions = struct {
    width: f64 = 360,
    height: f64 = 480,
    corner_radius: f64 = 12,
    material: PanelMaterial = .menu,
};

extern "CoreGraphics" fn CGColorSpaceCreateDeviceRGB() *anyopaque;
extern "CoreGraphics" fn CGColorSpaceRelease(space: *anyopaque) void;
extern "CoreGraphics" fn CGColorCreate(space: *anyopaque, components: [*]const CGFloat) ?*anyopaque;
extern "CoreGraphics" fn CGColorRelease(color: *anyopaque) void;

fn begin_instant_transaction() void {
    const CATransaction = objc.get_class("CATransaction") orelse return;
    objc.msg_send(void, CATransaction, "begin", .{});
    objc.msg_send(void, CATransaction, "setDisableActions:", .{objc.YES});
}

fn commit_instant_transaction() void {
    const CATransaction = objc.get_class("CATransaction") orelse return;
    objc.msg_send(void, CATransaction, "commit", .{});
}

pub const PanelHandle = struct {
    window: Id,
    visual_effect: Id,
    metal_layer: Id,

    pub fn show(self: PanelHandle) void {
        const NSApplication = objc.get_class("NSApplication") orelse return;
        const app = objc.msg_send(Id, NSApplication, "sharedApplication", .{});
        objc.msg_send(void, app, "activateIgnoringOtherApps:", .{objc.YES});
        objc.msg_send(void, self.window, "makeKeyAndOrderFront:", .{@as(?Id, null)});
    }

    pub fn hide(self: PanelHandle) void {
        objc.msg_send(void, self.window, "orderOut:", .{@as(?Id, null)});
    }

    pub fn is_visible(self: PanelHandle) bool {
        const v: objc.BOOL = objc.msg_send(objc.BOOL, self.window, "isVisible", .{});
        return v != 0;
    }

    // AppKit screen coords: bottom-left origin.
    pub fn set_origin(self: PanelHandle, x: f64, y: f64) void {
        objc.msg_send(void, self.window, "setFrameOrigin:", .{
            NSPoint{ .x = x, .y = y },
        });
    }

    // animate:NO + CATransaction(disableActions:YES) so neither AppKit
    // nor implicit CALayer animation stretches the previous drawable.
    pub fn set_size(self: PanelHandle, w: f64, h: f64) void {
        const frame: NSRect = objc.msg_send(NSRect, self.window, "frame", .{});
        const new_frame = NSRect{
            .origin = frame.origin,
            .size = .{ .width = w, .height = h },
        };
        begin_instant_transaction();
        defer commit_instant_transaction();
        objc.msg_send(void, self.window, "setFrame:display:animate:", .{
            new_frame, objc.YES, objc.NO,
        });
    }

    // Anchor top edge; NSWindow's bottom-left growth would otherwise
    // make a menubar drop-down expand upward.
    pub fn set_size_top_anchored(self: PanelHandle, w: f64, h: f64) void {
        const frame: NSRect = objc.msg_send(NSRect, self.window, "frame", .{});
        const top = frame.origin.y + frame.size.height;
        const new_frame = NSRect{
            .origin = .{ .x = frame.origin.x, .y = top - h },
            .size = .{ .width = w, .height = h },
        };
        begin_instant_transaction();
        defer commit_instant_transaction();
        objc.msg_send(void, self.window, "setFrame:display:animate:", .{
            new_frame, objc.YES, objc.NO,
        });
    }

    pub fn on_resign_key(
        self: PanelHandle,
        ctx: *anyopaque,
        callback: *const fn (*anyopaque) void,
    ) void {
        ensure_panel_delegate_class();
        const delegate = get_shared_panel_delegate();

        resign_map.put(std.heap.page_allocator, @intFromPtr(self.window), .{
            .ctx = ctx,
            .callback = callback,
        }) catch return;

        objc.msg_send(void, self.window, "setDelegate:", .{delegate});
    }

    // Coords are point-space, top-left origin (view is force-flipped).
    pub fn set_mouse_handler(
        self: PanelHandle,
        ctx: *anyopaque,
        callback: *const fn (*anyopaque, Event) void,
    ) void {
        mouse_map.put(std.heap.page_allocator, @intFromPtr(self.visual_effect), .{
            .ctx = ctx,
            .callback = callback,
        }) catch return;
    }

    pub fn deinit(self: PanelHandle) void {
        _ = resign_map.remove(@intFromPtr(self.window));
        _ = mouse_map.remove(@intFromPtr(self.visual_effect));
        objc.msg_send(void, self.window, "release", .{});
    }
};

fn ensure_panel_event_view_class() void {
    if (panel_event_view_class != null) return;
    const NSVisualEffectView = objc.get_class("NSVisualEffectView") orelse return;
    const new_class = objc.objc_allocateClassPair(
        NSVisualEffectView,
        "ZigUIPanelEventView",
        0,
    ) orelse return;

    const accepts: *const fn (Id, Sel) callconv(.c) objc.BOOL = &accepts_first_responder_imp;
    _ = objc.class_addMethod(
        new_class,
        objc.sel("acceptsFirstResponder"),
        @ptrCast(accepts),
        "B@:",
    );

    const did_move: *const fn (Id, Sel) callconv(.c) void = &view_did_move_to_window_imp;
    _ = objc.class_addMethod(
        new_class,
        objc.sel("viewDidMoveToWindow"),
        @ptrCast(did_move),
        "v@:",
    );

    const ev_impl: *const fn (Id, Sel, Id) callconv(.c) void = &event_forward_imp;
    inline for (.{
        "mouseDown:",         "mouseUp:",
        "rightMouseDown:",    "rightMouseUp:",
        "mouseMoved:",        "mouseDragged:",
        "rightMouseDragged:", "mouseEntered:",
        "mouseExited:",       "scrollWheel:",
    }) |selector| {
        _ = objc.class_addMethod(new_class, objc.sel(selector), @ptrCast(ev_impl), "v@:@");
    }

    objc.objc_registerClassPair(new_class);
    panel_event_view_class = new_class;
}

fn accepts_first_responder_imp(_: Id, _: Sel) callconv(.c) objc.BOOL {
    return objc.YES;
}

fn view_did_move_to_window_imp(self_view: Id, _: Sel) callconv(.c) void {
    const win: ?Id = objc.msg_send(?Id, self_view, "window", .{});
    if (win == null) return;

    const NSTrackingArea = objc.get_class("NSTrackingArea") orelse return;
    const bounds: NSRect = objc.msg_send(NSRect, self_view, "bounds", .{});

    const options: NSUInteger = NSTrackingMouseEnteredAndExited |
        NSTrackingMouseMoved |
        NSTrackingActiveInActiveApp |
        NSTrackingInVisibleRect;

    const area_alloc = objc.alloc(NSTrackingArea);
    const area = objc.msg_send(Id, area_alloc, "initWithRect:options:owner:userInfo:", .{
        bounds,
        options,
        self_view,
        @as(?Id, null),
    });

    objc.msg_send(void, self_view, "addTrackingArea:", .{area});
}

fn event_forward_imp(self_view: Id, sel: Sel, ns_event: Id) callconv(.c) void {
    const entry = mouse_map.get(@intFromPtr(self_view)) orelse return;

    const loc_win: NSPoint = objc.msg_send(NSPoint, ns_event, "locationInWindow", .{});
    const loc_view: NSPoint = objc.msg_send(NSPoint, self_view, "convertPoint:fromView:", .{
        loc_win,
        @as(?Id, null),
    });
    // View keeps isFlipped=NO so the CAMetalLayer sublayer's orientation
    // survives; flip y here for the top-left coords the client expects.
    const view_bounds: NSRect = objc.msg_send(NSRect, self_view, "bounds", .{});
    const y_topleft: CGFloat = view_bounds.size.height - loc_view.y;
    const pos: [2]f32 = .{ @floatCast(loc_view.x), @floatCast(y_topleft) };

    const flags: NSUInteger = objc.msg_send(NSUInteger, ns_event, "modifierFlags", .{});
    const mods: Modifiers = .{
        .shift = (flags & NSEventModifierFlagShift) != 0,
        .control = (flags & NSEventModifierFlagControl) != 0,
        .alt = (flags & NSEventModifierFlagOption) != 0,
        .command = (flags & NSEventModifierFlagCommand) != 0,
    };

    const sel_name = std.mem.span(@as([*:0]const u8, @ptrCast(sel)));
    const ev: ?Event = blk: {
        if (std.mem.eql(u8, sel_name, "mouseDown:")) {
            const cc: NSUInteger = objc.msg_send(NSUInteger, ns_event, "clickCount", .{});
            break :blk .{ .mouse_down = .{
                .button = .left,
                .position = pos,
                .modifiers = mods,
                .click_count = @intCast(cc),
            } };
        } else if (std.mem.eql(u8, sel_name, "rightMouseDown:")) {
            const cc: NSUInteger = objc.msg_send(NSUInteger, ns_event, "clickCount", .{});
            break :blk .{ .mouse_down = .{
                .button = .right,
                .position = pos,
                .modifiers = mods,
                .click_count = @intCast(cc),
            } };
        } else if (std.mem.eql(u8, sel_name, "mouseUp:")) {
            break :blk .{ .mouse_up = .{
                .button = .left,
                .position = pos,
                .modifiers = mods,
                .click_count = 1,
            } };
        } else if (std.mem.eql(u8, sel_name, "rightMouseUp:")) {
            break :blk .{ .mouse_up = .{
                .button = .right,
                .position = pos,
                .modifiers = mods,
                .click_count = 1,
            } };
        } else if (std.mem.eql(u8, sel_name, "mouseMoved:") or
            std.mem.eql(u8, sel_name, "mouseEntered:"))
        {
            break :blk .{ .mouse_move = .{
                .position = pos,
                .pressed_button = null,
                .modifiers = mods,
            } };
        } else if (std.mem.eql(u8, sel_name, "mouseDragged:")) {
            break :blk .{ .mouse_move = .{
                .position = pos,
                .pressed_button = .left,
                .modifiers = mods,
            } };
        } else if (std.mem.eql(u8, sel_name, "rightMouseDragged:")) {
            break :blk .{ .mouse_move = .{
                .position = pos,
                .pressed_button = .right,
                .modifiers = mods,
            } };
        } else if (std.mem.eql(u8, sel_name, "mouseExited:")) {
            break :blk .{ .mouse_exit = .{
                .position = pos,
                .pressed_button = null,
                .modifiers = mods,
            } };
        } else if (std.mem.eql(u8, sel_name, "scrollWheel:")) {
            const dx: CGFloat = objc.msg_send(CGFloat, ns_event, "scrollingDeltaX", .{});
            const dy: CGFloat = objc.msg_send(
                CGFloat,
                ns_event,
                "scrollingDeltaY",
                .{},
            );
            break :blk .{ .scroll_wheel = .{
                .position = pos,
                .delta_x = @floatCast(dx),
                .delta_y = @floatCast(dy),
                .modifiers = mods,
            } };
        }
        break :blk null;
    };

    if (ev) |e| entry.callback(entry.ctx, e);
}

// Borderless NSWindow defaults canBecomeKeyWindow=NO, which suppresses
// windowDidResignKey. Subclass to override.
fn ensure_keyable_window_class() void {
    if (keyable_window_class != null) return;
    const NSWindow = objc.get_class("NSWindow") orelse return;
    const new_class = objc.objc_allocateClassPair(
        NSWindow,
        "ZigUIKeyableBorderlessWindow",
        0,
    ) orelse return;
    const impl: *const fn (Id, Sel) callconv(.c) objc.BOOL = &can_become_key_window_imp;
    _ = objc.class_addMethod(
        new_class,
        objc.sel("canBecomeKeyWindow"),
        @ptrCast(impl),
        "B@:",
    );
    objc.objc_registerClassPair(new_class);
    keyable_window_class = new_class;
}

fn can_become_key_window_imp(_: Id, _: Sel) callconv(.c) objc.BOOL {
    return objc.YES;
}

fn ensure_panel_delegate_class() void {
    if (panel_delegate_class != null) return;

    const ns_object = objc.get_class("NSObject") orelse return;
    const new_class = objc.objc_allocateClassPair(
        ns_object,
        "ZigUIPanelWindowDelegate",
        0,
    ) orelse return;

    const impl_ptr: *const fn (Id, Sel, Id) callconv(.c) void = &window_did_resign_key_imp;
    _ = objc.class_addMethod(
        new_class,
        objc.sel("windowDidResignKey:"),
        @ptrCast(impl_ptr),
        "v@:@",
    );

    objc.objc_registerClassPair(new_class);
    panel_delegate_class = new_class;
}

fn get_shared_panel_delegate() Id {
    if (shared_panel_delegate) |d| return d;
    const cls = panel_delegate_class orelse unreachable;
    const obj = objc.alloc(cls);
    shared_panel_delegate = objc.msg_send(Id, obj, "init", .{});
    return shared_panel_delegate.?;
}

fn window_did_resign_key_imp(_: Id, _: Sel, notification: Id) callconv(.c) void {
    const window: ?Id = objc.msg_send(?Id, notification, "object", .{});
    const w = window orelse return;
    const key = @intFromPtr(w);
    const entry = resign_map.get(key) orelse return;
    entry.callback(entry.ctx);
}

pub const MetalHandle = struct {
    window: Id,
    view: Id,
    metal_layer: Id,
    height: f32,

    pub fn focus(self: MetalHandle) void {
        const NSApplication = objc.get_class("NSApplication") orelse return;
        const app = objc.msg_send(Id, NSApplication, "sharedApplication", .{});
        objc.msg_send(void, app, "activateIgnoringOtherApps:", .{objc.YES});
        objc.msg_send(void, self.window, "makeKeyAndOrderFront:", .{@as(?Id, null)});
    }

    pub fn get_size(self: MetalHandle) NSSize {
        const frame: NSRect = objc.msg_send(NSRect, self.view, "frame", .{});
        return frame.size;
    }

    pub fn deinit(self: MetalHandle) void {
        objc.msg_send(void, self.window, "release", .{});
    }
};

pub fn open_metal(opts: MetalOptions) Error!MetalHandle {
    std.debug.assert(opts.width > 0);
    std.debug.assert(opts.height > 0);

    const NSWindow = objc.get_class("NSWindow") orelse return Error.NoNSWindowClass;
    const NSView = objc.get_class("NSView") orelse return Error.NoNSViewClass;
    const CAMetalLayer = objc.get_class("CAMetalLayer") orelse
        return Error.NoCAMetalLayerClass;

    const window_alloc = objc.alloc(NSWindow);

    const frame: NSRect = .{
        .origin = .{ .x = 100, .y = 100 },
        .size = .{ .width = opts.width, .height = opts.height },
    };
    var style: NSUInteger =
        NSWindowStyleMaskTitled |
        NSWindowStyleMaskClosable |
        NSWindowStyleMaskMiniaturizable;
    if (opts.resizable) style |= NSWindowStyleMaskResizable;

    const window = objc.msg_send(
        Id,
        window_alloc,
        "initWithContentRect:styleMask:backing:defer:",
        .{
            frame, style, NSBackingStoreBuffered, objc.NO,
        },
    );
    if (@intFromPtr(window) == 0) return Error.NSWindowInitFailed;

    _ = objc.msg_send(Id, window, "retain", .{});
    errdefer objc.msg_send(void, window, "release", .{});

    var title_buf: [MAX_NSSTRING_BYTES]u8 = undefined;
    objc.msg_send(void, window, "setTitle:", .{nsstring_from_stack(&title_buf, opts.title)});

    const view_alloc = objc.alloc(NSView);
    const view_rect: NSRect = .{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{ .width = opts.width, .height = opts.height },
    };
    const view = objc.msg_send(Id, view_alloc, "initWithFrame:", .{view_rect});
    objc.msg_send(void, view, "setAutoresizingMask:", .{
        NSViewWidthSizable | NSViewHeightSizable,
    });
    objc.msg_send(void, view, "setWantsLayer:", .{objc.YES});

    const metal_layer = objc.msg_send(Id, CAMetalLayer, "layer", .{});

    const scale: CGFloat = objc.msg_send(CGFloat, window, "backingScaleFactor", .{});
    objc.msg_send(void, metal_layer, "setContentsScale:", .{scale});

    const drawable_size = CGSize{
        .width = opts.width * scale,
        .height = opts.height * scale,
    };
    objc.msg_send(void, metal_layer, "setDrawableSize:", .{drawable_size});

    objc.msg_send(void, metal_layer, "setNeedsDisplayOnBoundsChange:", .{objc.YES});
    objc.msg_send(void, metal_layer, "setAutoresizingMask:", .{
        @as(c_uint, NSViewWidthSizable | NSViewHeightSizable),
    });
    // presentsWithTransaction stays NO: Renderer's async presentDrawable
    // is incompatible with sync CATransaction commit. Resize-stretch
    // tradeoff accepted.

    objc.msg_send(void, view, "setLayer:", .{metal_layer});
    objc.msg_send(void, window, "setContentView:", .{view});
    objc.msg_send(void, window, "center", .{});

    return .{
        .window = window,
        .view = view,
        .metal_layer = metal_layer,
        .height = @floatCast(opts.height),
    };
}

const NSPopUpMenuWindowLevel: i64 = 101;
const NSVisualEffectBlendingModeBehindWindow: NSUInteger = 0;
const NSVisualEffectStateActive: NSUInteger = 1;

pub fn open_panel(opts: PanelOptions) Error!PanelHandle {
    std.debug.assert(opts.width > 0);
    std.debug.assert(opts.height > 0);

    const NSWindow = objc.get_class("NSWindow") orelse return Error.NoNSWindowClass;
    const NSVisualEffectView = objc.get_class("NSVisualEffectView") orelse
        return Error.NoNSViewClass;
    const CAMetalLayer = objc.get_class("CAMetalLayer") orelse
        return Error.NoCAMetalLayerClass;
    const NSColor = objc.get_class("NSColor") orelse return Error.NoNSViewClass;

    const window_alloc = objc.alloc(NSWindow);

    const frame: NSRect = .{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{ .width = opts.width, .height = opts.height },
    };
    const window = objc.msg_send(
        Id,
        window_alloc,
        "initWithContentRect:styleMask:backing:defer:",
        .{
            frame,
            @as(NSUInteger, 0),
            NSBackingStoreBuffered,
            objc.NO,
        },
    );
    if (@intFromPtr(window) == 0) return Error.NSWindowInitFailed;

    _ = objc.msg_send(Id, window, "retain", .{});
    errdefer objc.msg_send(void, window, "release", .{});

    ensure_keyable_window_class();
    if (keyable_window_class) |kc| _ = objc.object_setClass(window, kc);

    objc.msg_send(void, window, "setLevel:", .{NSPopUpMenuWindowLevel});
    objc.msg_send(void, window, "setOpaque:", .{objc.NO});
    const clear_color = objc.msg_send(Id, NSColor, "clearColor", .{});
    objc.msg_send(void, window, "setBackgroundColor:", .{clear_color});
    objc.msg_send(void, window, "setHasShadow:", .{objc.YES});
    objc.msg_send(void, window, "setMovableByWindowBackground:", .{objc.NO});

    ensure_panel_event_view_class();

    const view_alloc = objc.alloc(NSVisualEffectView);
    const visual_effect = objc.msg_send(Id, view_alloc, "initWithFrame:", .{frame});

    if (panel_event_view_class) |pec| _ = objc.object_setClass(visual_effect, pec);

    objc.msg_send(void, visual_effect, "setMaterial:", .{
        @as(NSUInteger, @intFromEnum(opts.material)),
    });
    objc.msg_send(void, visual_effect, "setBlendingMode:", .{
        NSVisualEffectBlendingModeBehindWindow,
    });
    objc.msg_send(void, visual_effect, "setState:", .{NSVisualEffectStateActive});
    objc.msg_send(void, visual_effect, "setEmphasized:", .{objc.YES});
    objc.msg_send(void, visual_effect, "setAutoresizingMask:", .{
        NSViewWidthSizable | NSViewHeightSizable,
    });

    objc.msg_send(void, visual_effect, "setWantsLayer:", .{objc.YES});
    const ve_layer = objc.msg_send(Id, visual_effect, "layer", .{});
    objc.msg_send(void, ve_layer, "setCornerRadius:", .{opts.corner_radius});
    objc.msg_send(void, ve_layer, "setMasksToBounds:", .{objc.YES});

    objc.msg_send(void, ve_layer, "setBorderWidth:", .{@as(CGFloat, 0.5)});
    const CGColorRef = ?*anyopaque;
    var border_rgba = [_]CGFloat{ 1.0, 1.0, 1.0, 0.18 };
    const generic_rgb = CGColorSpaceCreateDeviceRGB();
    defer CGColorSpaceRelease(generic_rgb);
    const border_color: CGColorRef = CGColorCreate(generic_rgb, &border_rgba);
    defer if (border_color) |bc| CGColorRelease(bc);
    objc.msg_send(void, ve_layer, "setBorderColor:", .{border_color});

    const metal_layer = objc.msg_send(Id, CAMetalLayer, "layer", .{});
    const scale: CGFloat = objc.msg_send(CGFloat, window, "backingScaleFactor", .{});
    objc.msg_send(void, metal_layer, "setContentsScale:", .{scale});
    const drawable_size = CGSize{
        .width = opts.width * scale,
        .height = opts.height * scale,
    };
    objc.msg_send(void, metal_layer, "setDrawableSize:", .{drawable_size});
    objc.msg_send(void, metal_layer, "setNeedsDisplayOnBoundsChange:", .{objc.YES});
    objc.msg_send(void, metal_layer, "setAutoresizingMask:", .{
        @as(c_uint, NSViewWidthSizable | NSViewHeightSizable),
    });
    objc.msg_send(void, metal_layer, "setFrame:", .{frame});
    objc.msg_send(void, metal_layer, "setOpaque:", .{objc.NO});

    objc.msg_send(void, ve_layer, "addSublayer:", .{metal_layer});

    objc.msg_send(void, window, "setContentView:", .{visual_effect});

    return .{
        .window = window,
        .visual_effect = visual_effect,
        .metal_layer = metal_layer,
    };
}

fn nsstring_from_stack(buf: []u8, s: []const u8) Id {
    std.debug.assert(buf.len >= 1);
    const NSString = objc.get_class("NSString") orelse unreachable;
    const len = @min(s.len, buf.len - 1);
    @memcpy(buf[0..len], s[0..len]);
    buf[len] = 0;
    return objc.msg_send(Id, NSString, "stringWithUTF8String:", .{
        @as([*:0]const u8, @ptrCast(buf.ptr)),
    });
}

const NSWindowStyleMaskFullSizeContentView: NSUInteger = 1 << 15;
const NSVisualEffectMaterialSidebar: NSUInteger = 7;
const NSWindowTitleVisible: NSUInteger = 0;
const NSWindowTitleHidden: NSUInteger = 1;
const NSSplitViewItemBehaviorSidebar: NSInteger = 1;

const NSInteger = objc.NSInteger;

pub const NativeShellHandle = struct {
    window: Id,
    split_controller: Id,
    sidebar_view: Id,
    content_view: Id,
    metal_layer: Id,
    height: f32,

    pub fn focus(self: NativeShellHandle) void {
        const NSApplication = objc.get_class("NSApplication") orelse return;
        const app = objc.msg_send(Id, NSApplication, "sharedApplication", .{});
        objc.msg_send(void, app, "activateIgnoringOtherApps:", .{objc.YES});
        // Prevent NSSearchField auto-grab on key-window; window starts with
        // no first responder so the search field doesn't open focused.
        objc.msg_send(void, self.window, "setInitialFirstResponder:", .{@as(?Id, null)});
        objc.msg_send(void, self.window, "makeKeyAndOrderFront:", .{@as(?Id, null)});
        objc.msg_send(void, self.window, "makeFirstResponder:", .{@as(?Id, null)});
    }

    pub fn get_content_size(self: NativeShellHandle) NSSize {
        const frame: NSRect = objc.msg_send(NSRect, self.content_view, "frame", .{});
        return frame.size;
    }

    // Excludes the toolbar safe-area inset AppKit reserves at the top,
    // so content does not slip under the translucent toolbar surface.
    pub fn get_safe_content_bounds(self: NativeShellHandle) NSRect {
        const frame: NSRect = objc.msg_send(NSRect, self.content_view, "frame", .{});
        const insets: NSEdgeInsets = objc.msg_send(
            NSEdgeInsets,
            self.content_view,
            "safeAreaInsets",
            .{},
        );
        return .{
            .origin = .{ .x = insets.left, .y = insets.top },
            .size = .{
                .width = frame.size.width - insets.left - insets.right,
                .height = frame.size.height - insets.top - insets.bottom,
            },
        };
    }

    // Without this on every paint tick the drawable stays at its
    // initial size after live resize and the content stretches.
    pub fn sync_drawable_size(self: NativeShellHandle) NSSize {
        const size = self.get_content_size();
        const scale: CGFloat = objc.msg_send(CGFloat, self.window, "backingScaleFactor", .{});
        const drawable = CGSize{ .width = size.width * scale, .height = size.height * scale };
        objc.msg_send(void, self.metal_layer, "setDrawableSize:", .{drawable});
        return size;
    }

    pub fn deinit(self: NativeShellHandle) void {
        objc.msg_send(void, self.window, "release", .{});
    }
};

var g_body_view_class: ?Class = null;
var g_scroll_ctx: ?*anyopaque = null;
var g_scroll_fn: ?ScrollFn = null;

var g_body_move_ctx: ?*anyopaque = null;
var g_body_move_fn: ?BodyMouseFn = null;
var g_body_click_ctx: ?*anyopaque = null;
var g_body_click_fn: ?BodyMouseFn = null;
var g_body_exit_ctx: ?*anyopaque = null;
var g_body_exit_fn: ?BodyExitFn = null;

fn body_local_coords(self: Id, event: Id) BodyMouseEvent {
    const loc_win: NSPoint = objc.msg_send(NSPoint, event, "locationInWindow", .{});
    const loc_view: NSPoint = objc.msg_send(NSPoint, self, "convertPoint:fromView:", .{
        loc_win,
        @as(?Id, null),
    });
    const bounds: NSRect = objc.msg_send(NSRect, self, "bounds", .{});
    // Body view isFlipped=NO; convert to top-down to match renderer coords.
    const y_top: CGFloat = bounds.size.height - loc_view.y;
    return .{ .x = @floatCast(loc_view.x), .y = @floatCast(y_top) };
}

fn body_scroll_wheel_imp(_: Id, _: Sel, event: Id) callconv(.c) void {
    const dy: CGFloat = objc.msg_send(CGFloat, event, "scrollingDeltaY", .{});
    const dx: CGFloat = objc.msg_send(CGFloat, event, "scrollingDeltaX", .{});
    if (g_scroll_fn) |cb| if (g_scroll_ctx) |c| cb(c, .{
        .delta_x = @floatCast(dx),
        .delta_y = @floatCast(dy),
    });
}

fn body_mouse_down_imp(self: Id, _: Sel, event: Id) callconv(.c) void {
    const win: ?Id = objc.msg_send(?Id, self, "window", .{});
    if (win) |w| objc.msg_send(void, w, "makeFirstResponder:", .{@as(?Id, null)});
    if (g_body_click_fn) |cb| if (g_body_click_ctx) |c| cb(c, body_local_coords(self, event));
}

fn body_mouse_moved_imp(self: Id, _: Sel, event: Id) callconv(.c) void {
    if (g_body_move_fn) |cb| if (g_body_move_ctx) |c| cb(c, body_local_coords(self, event));
}

fn body_mouse_exited_imp(_: Id, _: Sel, _: Id) callconv(.c) void {
    if (g_body_exit_fn) |cb| if (g_body_exit_ctx) |c| cb(c);
}

fn body_update_tracking_areas_imp(self: Id, sel: Sel) callconv(.c) void {
    const areas: ?Id = objc.msg_send(?Id, self, "trackingAreas", .{});
    if (areas) |arr| {
        const count: NSUInteger = objc.msg_send(NSUInteger, arr, "count", .{});
        std.debug.assert(count <= SUBVIEWS_MAX);
        var i: NSUInteger = 0;
        while (i < count) : (i += 1) {
            const area: Id = objc.msg_send(Id, arr, "objectAtIndex:", .{i});
            objc.msg_send(void, self, "removeTrackingArea:", .{area});
        }
    }
    const NSTrackingArea = objc.get_class("NSTrackingArea") orelse return;
    const bounds: NSRect = objc.msg_send(NSRect, self, "bounds", .{});
    const opts: NSUInteger = 0x01 | 0x02 | 0x80 | 0x200;
    const ta_alloc = objc.alloc(NSTrackingArea);
    const ta: Id = objc.msg_send(Id, ta_alloc, "initWithRect:options:owner:userInfo:", .{
        bounds,
        opts,
        @as(Id, self),
        @as(?Id, null),
    });
    objc.msg_send(void, self, "addTrackingArea:", .{ta});

    if (g_body_view_class) |cls| {
        if (objc.class_getSuperclass(cls)) |super_cls| {
            var super_struct = objc.objc_super{ .receiver = self, .super_class = super_cls };
            objc.msg_send_super_sel(void, &super_struct, sel, .{});
        }
    }
}

fn ensure_body_view_class() ?Class {
    if (g_body_view_class) |c| return c;
    const NSView_cls = objc.get_class("NSView") orelse return null;
    const cls = objc.objc_allocateClassPair(NSView_cls, "ZigUIBodyView", 0) orelse return null;
    _ = objc.class_addMethod(
        cls,
        objc.sel("scrollWheel:"),
        @ptrCast(&body_scroll_wheel_imp),
        "v@:@",
    );
    _ = objc.class_addMethod(
        cls,
        objc.sel("mouseDown:"),
        @ptrCast(&body_mouse_down_imp),
        "v@:@",
    );
    _ = objc.class_addMethod(
        cls,
        objc.sel("mouseMoved:"),
        @ptrCast(&body_mouse_moved_imp),
        "v@:@",
    );
    _ = objc.class_addMethod(
        cls,
        objc.sel("mouseExited:"),
        @ptrCast(&body_mouse_exited_imp),
        "v@:@",
    );
    _ = objc.class_addMethod(
        cls,
        objc.sel("updateTrackingAreas"),
        @ptrCast(&body_update_tracking_areas_imp),
        "v@:",
    );
    objc.objc_registerClassPair(cls);
    g_body_view_class = cls;
    return cls;
}

pub fn set_native_shell_on_scroll(ctx: *anyopaque, callback: ScrollFn) void {
    g_scroll_ctx = ctx;
    g_scroll_fn = callback;
}

pub fn set_native_shell_on_body_move(ctx: *anyopaque, callback: BodyMouseFn) void {
    g_body_move_ctx = ctx;
    g_body_move_fn = callback;
}

pub fn set_native_shell_on_body_click(ctx: *anyopaque, callback: BodyMouseFn) void {
    g_body_click_ctx = ctx;
    g_body_click_fn = callback;
}

pub fn set_native_shell_on_body_exit(ctx: *anyopaque, callback: BodyExitFn) void {
    g_body_exit_ctx = ctx;
    g_body_exit_fn = callback;
}

// Single-window assumption: obj-c target/action thunks resolve to globals.
var g_sidebar_items: ?[]const SidebarEntry = null;
var g_sidebar_select_ctx: ?*anyopaque = null;
var g_sidebar_select_fn: ?SidebarSelectFn = null;
var g_sidebar_selected_id_buf: [64]u8 = std.mem.zeroes([64]u8);
var g_sidebar_selected_id_len: u8 = 0;
var g_sidebar_target_class: ?Class = null;
var g_sidebar_target_instance: ?Id = null;
var g_sidebar_buttons_buf: [64]Id = undefined;
var g_sidebar_buttons_len: usize = 0;
var g_sidebar_text_buf: [64]Id = undefined;
var g_sidebar_text_len: usize = 0;
var g_sidebar_row_idx_buf: [64]usize = undefined;
var g_row_hovered: [256]bool = std.mem.zeroes([256]bool);
var g_row_class: ?Class = null;
var g_sidebar_handle: ?NativeShellHandle = null;

// Keyed by the entry's index in the items slice. Re-seeded from the caller's
// `expanded` defaults when a new items slice arrives (different pointer), not on
// every call; user clicks flip the bit without touching the caller's slice.
var g_group_expanded: [256]bool = std.mem.zeroes([256]bool);
var g_group_buf: [16]Id = undefined;
var g_group_idx_buf: [16]usize = undefined;
var g_group_len: usize = 0;
var g_group_class: ?Class = null;

var g_sidebar_reorder_ctx: ?*anyopaque = null;
var g_sidebar_reorder_fn: ?SidebarReorderFn = null;
var g_drag_active: bool = false;
var g_drag_from_idx: usize = 0;
var g_drag_start_screen_y: CGFloat = 0;
var g_drag_origin_y: CGFloat = 0;

var g_sidebar_search_enabled: bool = false;
var g_sidebar_search_field: ?Id = null;
var g_sidebar_search_buf: [128]u8 = std.mem.zeroes([128]u8);
var g_sidebar_search_len: usize = 0;
var g_sidebar_search_target_class: ?Class = null;
var g_sidebar_search_target: ?Id = null;

fn sidebar_selected_id() []const u8 {
    return g_sidebar_selected_id_buf[0..g_sidebar_selected_id_len];
}

fn set_sidebar_selected_id(id: []const u8) void {
    const n = @min(id.len, g_sidebar_selected_id_buf.len);
    @memcpy(g_sidebar_selected_id_buf[0..n], id[0..n]);
    g_sidebar_selected_id_len = @intCast(n);
}

fn sidebar_button_clicked_imp(self: Id, sel: Sel, sender: Id) callconv(.c) void {
    _ = self;
    _ = sel;
    const tag: NSInteger = objc.msg_send(NSInteger, sender, "tag", .{});
    const items = g_sidebar_items orelse return;
    const idx: usize = @intCast(tag);
    if (idx >= items.len) return;
    const entry = items[idx];
    if (entry.kind != .item) return;
    set_sidebar_selected_id(entry.id);
    refresh_sidebar_button_states();
    if (g_sidebar_select_fn) |cb| {
        if (g_sidebar_select_ctx) |ctx| cb(ctx, entry.id);
    }
}

fn ensure_sidebar_target() ?Id {
    if (g_sidebar_target_instance) |i| return i;
    const NSObject = objc.get_class("NSObject") orelse return null;
    if (g_sidebar_target_class == null) {
        const cls = objc.objc_allocateClassPair(NSObject, "ZigUISidebarTarget", 0) orelse
            return null;
        _ = objc.class_addMethod(
            cls,
            objc.sel("sidebarButtonClicked:"),
            @ptrCast(&sidebar_button_clicked_imp),
            "v@:@",
        );
        objc.objc_registerClassPair(cls);
        g_sidebar_target_class = cls;
    }
    const alloc = objc.alloc(g_sidebar_target_class.?);
    g_sidebar_target_instance = objc.msg_send(Id, alloc, "init", .{});
    return g_sidebar_target_instance;
}

fn refresh_sidebar_button_states() void {
    const items = g_sidebar_items orelse return;
    const selected = sidebar_selected_id();
    const NSColor = objc.get_class("NSColor") orelse return;
    var row_i: usize = 0;
    for (items) |entry| {
        if (entry.kind != .item) continue;
        if (row_i >= g_sidebar_buttons_len) break;
        const row = g_sidebar_buttons_buf[row_i];
        const is_sel = std.mem.eql(u8, entry.id, selected);
        objc.msg_send(void, row, "setNeedsDisplay:", .{objc.YES});
        if (row_i < g_sidebar_text_len) {
            const tf = g_sidebar_text_buf[row_i];
            const text_color = if (is_sel)
                objc.msg_send(Id, NSColor, "whiteColor", .{})
            else
                objc.msg_send(Id, NSColor, "labelColor", .{});
            objc.msg_send(void, tf, "setTextColor:", .{text_color});
        }
        row_i += 1;
    }
}

fn row_is_flipped_imp(_: Id, _: Sel) callconv(.c) bool {
    return true;
}

fn entry_idx_for_row(self: Id) ?usize {
    var i: usize = 0;
    while (i < g_sidebar_buttons_len) : (i += 1) {
        if (@intFromPtr(g_sidebar_buttons_buf[i]) == @intFromPtr(self)) {
            if (i < g_sidebar_row_idx_buf.len) return g_sidebar_row_idx_buf[i];
            return null;
        }
    }
    return null;
}

fn row_mouse_down_imp(self: Id, _: Sel, event: Id) callconv(.c) void {
    const idx = entry_idx_for_row(self) orelse return;
    const items = g_sidebar_items orelse return;
    if (idx >= items.len) return;
    const entry = items[idx];
    if (entry.kind != .item) return;
    const win: ?Id = objc.msg_send(?Id, self, "window", .{});
    if (win) |w| objc.msg_send(void, w, "makeFirstResponder:", .{@as(?Id, null)});
    set_sidebar_selected_id(entry.id);
    refresh_sidebar_button_states();
    if (g_sidebar_select_fn) |cb| if (g_sidebar_select_ctx) |c| cb(c, entry.id);

    if (g_sidebar_reorder_fn != null) {
        const loc: NSPoint = objc.msg_send(NSPoint, event, "locationInWindow", .{});
        g_drag_from_idx = idx;
        g_drag_start_screen_y = loc.y;
        const f: NSRect = objc.msg_send(NSRect, self, "frame", .{});
        g_drag_origin_y = f.origin.y;
        g_drag_active = false;
    }
}

fn row_mouse_dragged_imp(self: Id, _: Sel, event: Id) callconv(.c) void {
    if (g_sidebar_reorder_fn == null) return;
    const loc: NSPoint = objc.msg_send(NSPoint, event, "locationInWindow", .{});
    const dy = g_drag_start_screen_y - loc.y;
    if (!g_drag_active and @abs(dy) < 4) return;
    if (!g_drag_active) {
        const sv: ?Id = objc.msg_send(?Id, self, "superview", .{});
        if (sv) |s| {
            objc.msg_send(void, s, "addSubview:positioned:relativeTo:", .{
                self, @as(NSInteger, 1), @as(?Id, null),
            });
        }
    }
    g_drag_active = true;
    var f: NSRect = objc.msg_send(NSRect, self, "frame", .{});
    f.origin.y = g_drag_origin_y + dy;
    objc.msg_send(void, self, "setFrame:", .{f});
}

fn row_mouse_up_imp(self: Id, _: Sel, _: Id) callconv(.c) void {
    if (!g_drag_active) return;
    g_drag_active = false;

    const my_frame: NSRect = objc.msg_send(NSRect, self, "frame", .{});
    const my_center = my_frame.origin.y + my_frame.size.height / 2;

    var best_dist: CGFloat = 1.0e9;
    var best_idx: usize = g_drag_from_idx;
    var k: usize = 0;
    while (k < g_sidebar_buttons_len) : (k += 1) {
        const row = g_sidebar_buttons_buf[k];
        if (@intFromPtr(row) == @intFromPtr(self)) continue;
        const rf: NSRect = objc.msg_send(NSRect, row, "frame", .{});
        const rc = rf.origin.y + rf.size.height / 2;
        const d = if (rc > my_center) rc - my_center else my_center - rc;
        if (d < best_dist) {
            best_dist = d;
            best_idx = g_sidebar_row_idx_buf[k];
        }
    }

    if (best_idx != g_drag_from_idx) {
        if (g_sidebar_reorder_fn) |cb| if (g_sidebar_reorder_ctx) |c|
            cb(c, g_drag_from_idx, best_idx);
    }

    const items = g_sidebar_items orelse return;
    const handle = g_sidebar_handle orelse return;
    set_sidebar_items(handle, items);
}

pub fn set_sidebar_on_reorder(ctx: *anyopaque, callback: SidebarReorderFn) void {
    g_sidebar_reorder_ctx = ctx;
    g_sidebar_reorder_fn = callback;
}

fn row_mouse_entered_imp(self: Id, _: Sel, _: Id) callconv(.c) void {
    const idx = entry_idx_for_row(self) orelse return;
    if (idx >= g_row_hovered.len) return;
    g_row_hovered[idx] = true;
    objc.msg_send(void, self, "setNeedsDisplay:", .{objc.YES});
}

fn row_mouse_exited_imp(self: Id, _: Sel, _: Id) callconv(.c) void {
    const idx = entry_idx_for_row(self) orelse return;
    if (idx >= g_row_hovered.len) return;
    g_row_hovered[idx] = false;
    objc.msg_send(void, self, "setNeedsDisplay:", .{objc.YES});
}

fn row_draw_rect_imp(self: Id, _: Sel, _: NSRect) callconv(.c) void {
    const idx = entry_idx_for_row(self) orelse return;
    const items = g_sidebar_items orelse return;
    if (idx >= items.len) return;
    const entry = items[idx];
    if (entry.kind != .item) return;

    const bounds: NSRect = objc.msg_send(NSRect, self, "bounds", .{});
    const w = bounds.size.width;
    const h = bounds.size.height;

    const NSColor = objc.get_class("NSColor") orelse return;
    const NSBezierPath = objc.get_class("NSBezierPath") orelse return;

    const selected = std.mem.eql(u8, entry.id, sidebar_selected_id());
    const hovered = g_row_hovered[idx];

    if (selected) {
        const accent = objc.msg_send(Id, NSColor, "controlAccentColor", .{});
        objc.msg_send(void, accent, "set", .{});
        const path = objc.msg_send(
            Id,
            NSBezierPath,
            "bezierPathWithRoundedRect:xRadius:yRadius:",
            .{
                NSRect{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = w, .height = h } },
                @as(CGFloat, 6),
                @as(CGFloat, 6),
            },
        );
        objc.msg_send(void, path, "fill", .{});
    } else if (hovered) {
        const hov = objc.msg_send(Id, NSColor, "colorWithSRGBRed:green:blue:alpha:", .{
            @as(CGFloat, 1.0), @as(CGFloat, 1.0), @as(CGFloat, 1.0), @as(CGFloat, 0.08),
        });
        objc.msg_send(void, hov, "set", .{});
        const path = objc.msg_send(
            Id,
            NSBezierPath,
            "bezierPathWithRoundedRect:xRadius:yRadius:",
            .{
                NSRect{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = w, .height = h } },
                @as(CGFloat, 6),
                @as(CGFloat, 6),
            },
        );
        objc.msg_send(void, path, "fill", .{});
    }

    const icon_sz: CGFloat = 22;
    const icon_x: CGFloat = 8;
    const icon_y: CGFloat = (h - icon_sz) / 2;
    if (entry.color) |c| {
        const NSGradient = objc.get_class("NSGradient") orelse return;
        const base = objc.msg_send(Id, NSColor, "colorWithSRGBRed:green:blue:alpha:", .{
            @as(CGFloat, c.r), @as(CGFloat, c.g), @as(CGFloat, c.b), @as(CGFloat, c.a),
        });
        const white = objc.msg_send(Id, NSColor, "whiteColor", .{});
        const black = objc.msg_send(Id, NSColor, "blackColor", .{});
        const top = objc.msg_send(Id, base, "blendedColorWithFraction:ofColor:", .{
            @as(CGFloat, 0.18), white,
        });
        const bottom = objc.msg_send(Id, base, "blendedColorWithFraction:ofColor:", .{
            @as(CGFloat, 0.10), black,
        });
        const grad_alloc = objc.alloc(NSGradient);
        const grad = objc.msg_send(Id, grad_alloc, "initWithStartingColor:endingColor:", .{
            top, bottom,
        });

        const ip_rect = NSRect{
            .origin = .{ .x = icon_x, .y = icon_y },
            .size = .{ .width = icon_sz, .height = icon_sz },
        };
        const ip = objc.msg_send(
            Id,
            NSBezierPath,
            "bezierPathWithRoundedRect:xRadius:yRadius:",
            .{
                ip_rect,
                @as(CGFloat, 5),
                @as(CGFloat, 5),
            },
        );
        // angle 270 = top -> bottom (lighter at top).
        objc.msg_send(void, grad, "drawInBezierPath:angle:", .{ ip, @as(CGFloat, 270) });

        // Low-alpha white stroke keeps the tile visible when its color
        // matches the selection pill.
        const stroke = objc.msg_send(Id, NSColor, "colorWithSRGBRed:green:blue:alpha:", .{
            @as(CGFloat, 1.0), @as(CGFloat, 1.0), @as(CGFloat, 1.0), @as(CGFloat, 0.22),
        });
        objc.msg_send(void, stroke, "set", .{});
        objc.msg_send(void, ip, "setLineWidth:", .{@as(CGFloat, 1.0)});
        objc.msg_send(void, ip, "stroke", .{});
    }

    const has_icon = entry.icon_image != null or entry.icon != null;
    if (has_icon) {
        const NSImage = objc.get_class("NSImage") orelse return;
        const NSImageSymbolConfiguration =
            objc.get_class("NSImageSymbolConfiguration") orelse return;
        const NSArray = objc.get_class("NSArray") orelse return;
        var sym_buf: [128]u8 = undefined;
        const sym_opt: ?Id = blk: {
            if (entry.icon_image) |img_ptr| break :blk @as(Id, @ptrCast(img_ptr));
            const sym = mac_icon.MacIconSystem.sf_name(entry.icon.?);
            const sym_ns = nsstring_from_stack(&sym_buf, sym);
            break :blk objc.msg_send(
                ?Id,
                NSImage,
                "imageWithSystemSymbolName:accessibilityDescription:",
                .{ sym_ns, @as(?Id, null) },
            );
        };
        if (sym_opt) |sym| {
            const white = objc.msg_send(Id, NSColor, "whiteColor", .{});
            const arr = objc.msg_send(Id, NSArray, "arrayWithObject:", .{white});
            const palette = objc.msg_send(
                Id,
                NSImageSymbolConfiguration,
                "configurationWithPaletteColors:",
                .{arr},
            );
            const pt = objc.msg_send(
                Id,
                NSImageSymbolConfiguration,
                "configurationWithPointSize:weight:scale:",
                .{
                    @as(CGFloat, 13), @as(CGFloat, 0.3), @as(NSInteger, 2),
                },
            );
            const cfg = objc.msg_send(Id, palette, "configurationByApplyingConfiguration:", .{pt});
            const sym_white = objc.msg_send(Id, sym, "imageWithSymbolConfiguration:", .{cfg});

            const ss: NSSize = objc.msg_send(NSSize, sym_white, "size", .{});
            const align_rect: NSRect = objc.msg_send(NSRect, sym_white, "alignmentRect", .{});

            const a_w = if (align_rect.size.width > 0) align_rect.size.width else ss.width;
            const a_h = if (align_rect.size.height > 0) align_rect.size.height else ss.height;
            const a_x = if (align_rect.size.width > 0) align_rect.origin.x else 0;
            const a_y = if (align_rect.size.height > 0) align_rect.origin.y else 0;

            const target: CGFloat = icon_sz * 0.80;
            const longest: CGFloat = if (a_w >= a_h) a_w else a_h;
            const scale: CGFloat = if (longest > 0) target / longest else 1.0;
            const draw_w: CGFloat = ss.width * scale;
            const draw_h: CGFloat = ss.height * scale;

            const backplate_cx = icon_x + icon_sz / 2;
            const backplate_cy = icon_y + icon_sz / 2;

            // alignmentRect is in image-bottom-up coords. The flipped-
            // context-aware respectFlipped:hints: draw still maps the
            // image's TOP-LEFT to the draw_rect.origin in row coords,
            // so subtract (a_x, ss.height - a_y - a_h) * scale from the
            // backplate's top-left to align the rect's content center.
            const align_cx_from_left = a_x + a_w / 2;
            const align_cy_from_top = ss.height - (a_y + a_h / 2);
            const draw_rect = NSRect{
                .origin = .{
                    .x = backplate_cx - align_cx_from_left * scale,
                    .y = backplate_cy - align_cy_from_top * scale,
                },
                .size = .{ .width = draw_w, .height = draw_h },
            };

            const DrawFn = *const fn (
                target_ptr: *anyopaque,
                sel: Sel,
                dst: NSRect,
                src: NSRect,
                op: NSUInteger,
                frac: CGFloat,
                respect_flipped: u8,
                hints: ?Id,
            ) callconv(.c) void;
            const draw_fn: DrawFn = @ptrCast(&objc.objc_msgSend);
            draw_fn(
                @ptrCast(sym_white),
                objc.sel("drawInRect:fromRect:operation:fraction:respectFlipped:hints:"),
                draw_rect,
                NSRect{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 0, .height = 0 } },
                2,
                1.0,
                1,
                null,
            );
        }
    }

    if (entry.badge.len > 0) {
        const NSFont = objc.get_class("NSFont") orelse return;
        const NSMutableDictionary =
            objc.get_class("NSMutableDictionary") orelse return;
        var bbuf: [32]u8 = undefined;
        const badge_ns = nsstring_from_stack(&bbuf, entry.badge);

        const font = objc.msg_send(Id, NSFont, "systemFontOfSize:weight:", .{
            @as(CGFloat, 11), @as(CGFloat, 0.3),
        });
        const text_color = if (selected)
            objc.msg_send(Id, NSColor, "systemRedColor", .{})
        else
            objc.msg_send(Id, NSColor, "whiteColor", .{});

        var k_font_buf: [16]u8 = undefined;
        var k_color_buf: [16]u8 = undefined;
        const attrs_alloc = objc.alloc(NSMutableDictionary);
        const attrs = objc.msg_send(Id, attrs_alloc, "init", .{});
        objc.msg_send(void, attrs, "setObject:forKey:", .{
            font, nsstring_from_stack(&k_font_buf, "NSFont"),
        });
        objc.msg_send(void, attrs, "setObject:forKey:", .{
            text_color, nsstring_from_stack(&k_color_buf, "NSColor"),
        });

        const text_size: NSSize = objc.msg_send(NSSize, badge_ns, "sizeWithAttributes:", .{attrs});
        const pad_x: CGFloat = 7;
        const pill_h: CGFloat = 18;
        const pill_w: CGFloat = @max(text_size.width + pad_x * 2, pill_h);
        const pill_x: CGFloat = w - pill_w - 10;
        const pill_y: CGFloat = (h - pill_h) / 2;

        const pill_bg = if (selected)
            objc.msg_send(Id, NSColor, "whiteColor", .{})
        else
            objc.msg_send(Id, NSColor, "systemRedColor", .{});
        objc.msg_send(void, pill_bg, "set", .{});
        const pill_rect = NSRect{
            .origin = .{ .x = pill_x, .y = pill_y },
            .size = .{ .width = pill_w, .height = pill_h },
        };
        const pill_path = objc.msg_send(
            Id,
            NSBezierPath,
            "bezierPathWithRoundedRect:xRadius:yRadius:",
            .{
                pill_rect,
                pill_h / 2,
                pill_h / 2,
            },
        );
        objc.msg_send(void, pill_path, "fill", .{});

        const text_x = pill_x + (pill_w - text_size.width) / 2;
        const text_y = pill_y + (pill_h - text_size.height) / 2;
        objc.msg_send(void, badge_ns, "drawAtPoint:withAttributes:", .{
            NSPoint{ .x = text_x, .y = text_y },
            attrs,
        });
    }
}

fn row_update_tracking_areas_imp(self: Id, _: Sel) callconv(.c) void {
    const prior: Id = objc.msg_send(Id, self, "trackingAreas", .{});
    if (@intFromPtr(prior) != 0) {
        const count: NSUInteger = objc.msg_send(NSUInteger, prior, "count", .{});
        std.debug.assert(count <= SUBVIEWS_MAX);
        var i: NSUInteger = 0;
        while (i < count) : (i += 1) {
            const ta = objc.msg_send(Id, prior, "objectAtIndex:", .{i});
            objc.msg_send(void, self, "removeTrackingArea:", .{ta});
        }
    }
    const NSTrackingArea = objc.get_class("NSTrackingArea") orelse return;
    const bounds: NSRect = objc.msg_send(NSRect, self, "bounds", .{});
    const opts: NSUInteger = NSTrackingMouseEnteredAndExited |
        NSTrackingActiveInActiveApp |
        NSTrackingInVisibleRect;
    const ta_alloc = objc.alloc(NSTrackingArea);
    const ta = objc.msg_send(Id, ta_alloc, "initWithRect:options:owner:userInfo:", .{
        bounds, opts, self, @as(?Id, null),
    });
    objc.msg_send(void, self, "addTrackingArea:", .{ta});
}

fn ascii_lower_eql(needle: []const u8, haystack: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var k: usize = 0;
        while (k < needle.len) : (k += 1) {
            const a = needle[k];
            const b = haystack[i + k];
            const al = if (a >= 'A' and a <= 'Z') a + 32 else a;
            const bl = if (b >= 'A' and b <= 'Z') b + 32 else b;
            if (al != bl) break;
        }
        if (k == needle.len) return true;
    }
    return false;
}

fn entry_passes_filter(entry: SidebarEntry) bool {
    if (g_sidebar_search_len == 0) return true;
    const needle = g_sidebar_search_buf[0..g_sidebar_search_len];
    return ascii_lower_eql(needle, entry.label);
}

fn sidebar_search_changed_imp(_: Id, _: Sel, sender: Id) callconv(.c) void {
    const text_ns: Id = objc.msg_send(Id, sender, "stringValue", .{});
    const c_str: ?[*:0]const u8 = objc.msg_send(?[*:0]const u8, text_ns, "UTF8String", .{});
    const ptr = c_str orelse return;
    const slice = std.mem.sliceTo(ptr, 0);
    const n = @min(slice.len, g_sidebar_search_buf.len);
    @memcpy(g_sidebar_search_buf[0..n], slice[0..n]);
    g_sidebar_search_len = n;
    const items = g_sidebar_items orelse return;
    const handle = g_sidebar_handle orelse return;
    set_sidebar_items(handle, items);
}

fn ensure_sidebar_search_target() ?Id {
    if (g_sidebar_search_target) |t| return t;
    const NSObject = objc.get_class("NSObject") orelse return null;
    if (g_sidebar_search_target_class == null) {
        const cls = objc.objc_allocateClassPair(NSObject, "ZigUISidebarSearchTarget", 0) orelse
            return null;
        _ = objc.class_addMethod(
            cls,
            objc.sel("sidebarSearchChanged:"),
            @ptrCast(&sidebar_search_changed_imp),
            "v@:@",
        );
        objc.objc_registerClassPair(cls);
        g_sidebar_search_target_class = cls;
    }
    const alloc = objc.alloc(g_sidebar_search_target_class.?);
    g_sidebar_search_target = objc.msg_send(Id, alloc, "init", .{});
    return g_sidebar_search_target;
}

fn entry_idx_for_group(self: Id) ?usize {
    var i: usize = 0;
    while (i < g_group_len) : (i += 1) {
        if (@intFromPtr(g_group_buf[i]) == @intFromPtr(self)) return g_group_idx_buf[i];
    }
    return null;
}

fn group_is_flipped_imp(_: Id, _: Sel) callconv(.c) bool {
    return true;
}

fn group_mouse_down_imp(self: Id, _: Sel, _: Id) callconv(.c) void {
    const idx = entry_idx_for_group(self) orelse return;
    const win: ?Id = objc.msg_send(?Id, self, "window", .{});
    if (win) |w| objc.msg_send(void, w, "makeFirstResponder:", .{@as(?Id, null)});
    g_group_expanded[idx] = !g_group_expanded[idx];
    const items = g_sidebar_items orelse return;
    const handle = g_sidebar_handle orelse return;
    set_sidebar_items(handle, items);
}

fn group_draw_rect_imp(self: Id, _: Sel, _: NSRect) callconv(.c) void {
    const idx = entry_idx_for_group(self) orelse return;
    const items = g_sidebar_items orelse return;
    if (idx >= items.len) return;
    const entry = items[idx];

    const NSColor = objc.get_class("NSColor") orelse return;
    const NSFont = objc.get_class("NSFont") orelse return;
    const NSMutableDictionary = objc.get_class("NSMutableDictionary") orelse return;

    const bounds: NSRect = objc.msg_send(NSRect, self, "bounds", .{});
    const w = bounds.size.width;
    const h = bounds.size.height;

    var lbl_buf: [128]u8 = undefined;
    const lbl_ns = nsstring_from_stack(&lbl_buf, entry.label);

    const font = objc.msg_send(Id, NSFont, "systemFontOfSize:weight:", .{
        @as(CGFloat, 10), @as(CGFloat, 0.4),
    });
    const tertiary = objc.msg_send(Id, NSColor, "secondaryLabelColor", .{});

    var k_font_buf: [16]u8 = undefined;
    var k_color_buf: [16]u8 = undefined;
    const attrs_alloc = objc.alloc(NSMutableDictionary);
    const attrs = objc.msg_send(Id, attrs_alloc, "init", .{});
    objc.msg_send(void, attrs, "setObject:forKey:", .{
        font, nsstring_from_stack(&k_font_buf, "NSFont"),
    });
    objc.msg_send(void, attrs, "setObject:forKey:", .{
        tertiary, nsstring_from_stack(&k_color_buf, "NSColor"),
    });

    const text_size: NSSize = objc.msg_send(NSSize, lbl_ns, "sizeWithAttributes:", .{attrs});
    const text_y = (h - text_size.height) / 2;
    objc.msg_send(void, lbl_ns, "drawAtPoint:withAttributes:", .{
        NSPoint{ .x = 0, .y = text_y },
        attrs,
    });

    const expanded = g_group_expanded[idx];
    const NSImage = objc.get_class("NSImage") orelse return;
    const NSImageSymbolConfiguration = objc.get_class("NSImageSymbolConfiguration") orelse return;
    const NSArray = objc.get_class("NSArray") orelse return;
    const chev_name: []const u8 = if (expanded) "chevron.down" else "chevron.right";
    var chev_buf: [32]u8 = undefined;
    const chev_ns = nsstring_from_stack(&chev_buf, chev_name);
    const chev_opt: ?Id = objc.msg_send(
        ?Id,
        NSImage,
        "imageWithSystemSymbolName:accessibilityDescription:",
        .{ chev_ns, @as(?Id, null) },
    );
    if (chev_opt) |chev_img| {
        const arr = objc.msg_send(Id, NSArray, "arrayWithObject:", .{tertiary});
        const palette = objc.msg_send(
            Id,
            NSImageSymbolConfiguration,
            "configurationWithPaletteColors:",
            .{arr},
        );
        const pt = objc.msg_send(
            Id,
            NSImageSymbolConfiguration,
            "configurationWithPointSize:weight:",
            .{ @as(CGFloat, 9), @as(CGFloat, 0.3) },
        );
        const cfg = objc.msg_send(Id, palette, "configurationByApplyingConfiguration:", .{pt});
        const chev_tinted = objc.msg_send(Id, chev_img, "imageWithSymbolConfiguration:", .{cfg});
        const cs: NSSize = objc.msg_send(NSSize, chev_tinted, "size", .{});
        const chev_x = w - cs.width - 6;
        const chev_y = (h - cs.height) / 2;
        const draw_rect = NSRect{ .origin = .{ .x = chev_x, .y = chev_y }, .size = cs };

        const NSGraphicsContext = objc.get_class("NSGraphicsContext") orelse return;
        const NSAffineTransform = objc.get_class("NSAffineTransform") orelse return;
        objc.msg_send(void, NSGraphicsContext, "saveGraphicsState", .{});
        defer objc.msg_send(void, NSGraphicsContext, "restoreGraphicsState", .{});

        const t_alloc = objc.alloc(NSAffineTransform);
        const t = objc.msg_send(Id, t_alloc, "init", .{});
        objc.msg_send(void, t, "translateXBy:yBy:", .{
            draw_rect.origin.x, draw_rect.origin.y + cs.height,
        });
        objc.msg_send(void, t, "scaleXBy:yBy:", .{ @as(CGFloat, 1.0), @as(CGFloat, -1.0) });
        objc.msg_send(void, t, "concat", .{});

        objc.msg_send(void, chev_tinted, "drawInRect:fromRect:operation:fraction:", .{
            NSRect{ .origin = .{ .x = 0, .y = 0 }, .size = cs },
            NSRect{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 0, .height = 0 } },
            @as(NSUInteger, 2),
            @as(CGFloat, 1.0),
        });
    }
}

fn ensure_group_class() ?Class {
    if (g_group_class) |c| return c;
    const NSView_cls = objc.get_class("NSView") orelse return null;
    const cls = objc.objc_allocateClassPair(NSView_cls, "ZigUISidebarGroup", 0) orelse
        return null;
    _ = objc.class_addMethod(
        cls,
        objc.sel("drawRect:"),
        @ptrCast(&group_draw_rect_imp),
        "v@:{NSRect={NSPoint=dd}{NSSize=dd}}",
    );
    _ = objc.class_addMethod(
        cls,
        objc.sel("mouseDown:"),
        @ptrCast(&group_mouse_down_imp),
        "v@:@",
    );
    _ = objc.class_addMethod(
        cls,
        objc.sel("isFlipped"),
        @ptrCast(&group_is_flipped_imp),
        "B@:",
    );
    objc.objc_registerClassPair(cls);
    g_group_class = cls;
    return cls;
}

fn ensure_row_class() ?Class {
    if (g_row_class) |c| return c;
    const NSView_cls = objc.get_class("NSView") orelse return null;
    const cls = objc.objc_allocateClassPair(NSView_cls, "ZigUISidebarRow", 0) orelse
        return null;
    _ = objc.class_addMethod(
        cls,
        objc.sel("drawRect:"),
        @ptrCast(&row_draw_rect_imp),
        "v@:{NSRect={NSPoint=dd}{NSSize=dd}}",
    );
    _ = objc.class_addMethod(cls, objc.sel("mouseDown:"), @ptrCast(&row_mouse_down_imp), "v@:@");
    _ = objc.class_addMethod(
        cls,
        objc.sel("mouseDragged:"),
        @ptrCast(&row_mouse_dragged_imp),
        "v@:@",
    );
    _ = objc.class_addMethod(cls, objc.sel("mouseUp:"), @ptrCast(&row_mouse_up_imp), "v@:@");
    _ = objc.class_addMethod(
        cls,
        objc.sel("mouseEntered:"),
        @ptrCast(&row_mouse_entered_imp),
        "v@:@",
    );
    _ = objc.class_addMethod(
        cls,
        objc.sel("mouseExited:"),
        @ptrCast(&row_mouse_exited_imp),
        "v@:@",
    );
    _ = objc.class_addMethod(cls, objc.sel("isFlipped"), @ptrCast(&row_is_flipped_imp), "B@:");
    _ = objc.class_addMethod(
        cls,
        objc.sel("updateTrackingAreas"),
        @ptrCast(&row_update_tracking_areas_imp),
        "v@:",
    );
    objc.objc_registerClassPair(cls);
    g_row_class = cls;
    return cls;
}

fn build_settings_icon(symbol: []const u8, bg: Rgba) ?Id {
    const NSImage = objc.get_class("NSImage") orelse return null;
    const NSColor = objc.get_class("NSColor") orelse return null;
    const NSBezierPath = objc.get_class("NSBezierPath") orelse return null;
    const NSImageSymbolConfiguration =
        objc.get_class("NSImageSymbolConfiguration") orelse return null;
    const NSArray = objc.get_class("NSArray") orelse return null;

    const sz: CGFloat = 24;
    const corner: CGFloat = 6;

    const img_alloc = objc.alloc(NSImage);
    const img = objc.msg_send(Id, img_alloc, "initWithSize:", .{
        NSSize{ .width = sz, .height = sz },
    });

    objc.msg_send(void, img, "lockFocus", .{});
    defer objc.msg_send(void, img, "unlockFocus", .{});

    const bg_color = objc.msg_send(Id, NSColor, "colorWithSRGBRed:green:blue:alpha:", .{
        @as(CGFloat, bg.r), @as(CGFloat, bg.g), @as(CGFloat, bg.b), @as(CGFloat, bg.a),
    });
    objc.msg_send(void, bg_color, "set", .{});

    const rect = NSRect{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{ .width = sz, .height = sz },
    };
    const path = objc.msg_send(
        Id,
        NSBezierPath,
        "bezierPathWithRoundedRect:xRadius:yRadius:",
        .{
            rect, corner, corner,
        },
    );
    objc.msg_send(void, path, "fill", .{});

    var sym_buf: [128]u8 = undefined;
    const sym_ns = nsstring_from_stack(&sym_buf, symbol);
    const symbol_img_opt: ?Id = objc.msg_send(
        ?Id,
        NSImage,
        "imageWithSystemSymbolName:accessibilityDescription:",
        .{ sym_ns, @as(?Id, null) },
    );
    if (symbol_img_opt) |symbol_img| {
        const white = objc.msg_send(Id, NSColor, "whiteColor", .{});
        const colors_arr = objc.msg_send(Id, NSArray, "arrayWithObject:", .{white});
        const cfg = objc.msg_send(
            Id,
            NSImageSymbolConfiguration,
            "configurationWithPaletteColors:",
            .{colors_arr},
        );
        const pt_cfg = objc.msg_send(
            Id,
            NSImageSymbolConfiguration,
            "configurationWithPointSize:weight:",
            .{ @as(CGFloat, 14), @as(CGFloat, 0.3) },
        );
        const merged = objc.msg_send(Id, cfg, "configurationByApplyingConfiguration:", .{pt_cfg});
        const sym_white = objc.msg_send(Id, symbol_img, "imageWithSymbolConfiguration:", .{merged});

        const sym_size: NSSize = objc.msg_send(NSSize, sym_white, "size", .{});
        const draw_rect = NSRect{
            .origin = .{
                .x = (sz - sym_size.width) / 2,
                .y = (sz - sym_size.height) / 2,
            },
            .size = sym_size,
        };
        objc.msg_send(void, sym_white, "drawInRect:fromRect:operation:fraction:", .{
            draw_rect,
            NSRect{ .origin = .{ .x = 0, .y = 0 }, .size = sym_size },
            @as(NSUInteger, 2),
            @as(CGFloat, 1.0),
        });
    }

    return img;
}

var g_flipped_view_class: ?Class = null;

fn is_flipped_yes_imp(_: Id, _: Sel) callconv(.c) bool {
    return true;
}

fn ensure_flipped_view_class() ?Class {
    if (g_flipped_view_class) |c| return c;
    const NSView_cls = objc.get_class("NSView") orelse return null;
    const cls = objc.objc_allocateClassPair(NSView_cls, "ZigUIFlippedView", 0) orelse
        return null;
    _ = objc.class_addMethod(
        cls,
        objc.sel("isFlipped"),
        @ptrCast(&is_flipped_yes_imp),
        "B@:",
    );
    objc.objc_registerClassPair(cls);
    g_flipped_view_class = cls;
    return cls;
}

pub fn set_sidebar_items(handle: NativeShellHandle, items: []const SidebarEntry) void {
    const items_changed = blk: {
        const prev = g_sidebar_items orelse break :blk true;
        break :blk prev.ptr != items.ptr;
    };
    if (items_changed) {
        for (items, 0..) |entry, i| {
            if (entry.kind == .group and entry.collapsible and i < g_group_expanded.len) {
                g_group_expanded[i] = entry.expanded;
            }
        }
    }
    g_sidebar_items = items;
    g_sidebar_handle = handle;
    g_sidebar_buttons_len = 0;
    g_sidebar_text_len = 0;
    g_group_len = 0;
    _ = ensure_sidebar_target();
    const flipped_cls = ensure_flipped_view_class() orelse return;
    const row_cls = ensure_row_class() orelse return;
    const group_cls = ensure_group_class() orelse return;

    const NSScrollView = objc.get_class("NSScrollView") orelse return;
    const NSTextField = objc.get_class("NSTextField") orelse return;
    const NSColor = objc.get_class("NSColor") orelse return;
    const NSFont = objc.get_class("NSFont") orelse return;

    const prior: Id = objc.msg_send(Id, handle.sidebar_view, "subviews", .{});
    if (@intFromPtr(prior) != 0) {
        const count: NSUInteger = objc.msg_send(NSUInteger, prior, "count", .{});
        std.debug.assert(count <= SUBVIEWS_MAX);
        var k: NSUInteger = 0;
        while (k < count) : (k += 1) {
            const v = objc.msg_send(Id, prior, "objectAtIndex:", .{k});
            if (g_sidebar_search_field) |sf| {
                if (@intFromPtr(v) == @intFromPtr(sf)) continue;
            }
            objc.msg_send(void, v, "removeFromSuperview", .{});
        }
    }

    const sidebar_frame: NSRect = objc.msg_send(NSRect, handle.sidebar_view, "frame", .{});
    const w_total: CGFloat = sidebar_frame.size.width;
    const h_total: CGFloat = sidebar_frame.size.height;

    const SAFE_TOP: CGFloat = 52; // traffic lights + toolbar safe area
    const SEARCH_H: CGFloat = 24;
    const SEARCH_GAP: CGFloat = 16;
    const TOP_INSET: CGFloat = if (g_sidebar_search_enabled)
        SAFE_TOP + SEARCH_H + SEARCH_GAP
    else
        SAFE_TOP;
    const BOTTOM_INSET: CGFloat = 12;
    const SIDE_PAD: CGFloat = 10;
    const ROW_H: CGFloat = 28;
    const GROUP_H: CGFloat = 18;
    const GAP: CGFloat = 0;
    const GROUP_TOP_GAP: CGFloat = 12;
    const GROUP_BOTTOM_GAP: CGFloat = 2;

    if (g_sidebar_search_enabled and g_sidebar_search_field == null) {
        const NSSearchField = objc.get_class("NSSearchField") orelse return;
        const sf_alloc = objc.alloc(NSSearchField);
        const sf_rect = NSRect{
            .origin = .{ .x = SIDE_PAD, .y = h_total - SAFE_TOP - SEARCH_H },
            .size = .{ .width = w_total - SIDE_PAD * 2, .height = SEARCH_H },
        };
        const sf = objc.msg_send(Id, sf_alloc, "initWithFrame:", .{sf_rect});
        objc.msg_send(void, sf, "setAutoresizingMask:", .{
            @as(c_uint, NSViewWidthSizable | NSViewMinYMargin),
        });
        if (ensure_sidebar_search_target()) |target| {
            objc.msg_send(void, sf, "setTarget:", .{target});
            objc.msg_send(void, sf, "setAction:", .{objc.sel("sidebarSearchChanged:")});
            objc.msg_send(void, sf, "setSendsSearchStringImmediately:", .{objc.YES});
        }
        objc.msg_send(void, handle.sidebar_view, "addSubview:", .{sf});
        g_sidebar_search_field = sf;
    }

    const sv_alloc = objc.alloc(NSScrollView);
    const sv = objc.msg_send(Id, sv_alloc, "initWithFrame:", .{NSRect{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{ .width = w_total, .height = h_total },
    }});
    objc.msg_send(void, sv, "setAutoresizingMask:", .{
        @as(c_uint, NSViewWidthSizable | NSViewHeightSizable),
    });
    objc.msg_send(void, sv, "setBorderType:", .{@as(NSUInteger, 0)});
    objc.msg_send(void, sv, "setDrawsBackground:", .{objc.NO});
    objc.msg_send(void, sv, "setHasVerticalScroller:", .{objc.YES});
    objc.msg_send(void, sv, "setHasHorizontalScroller:", .{objc.NO});
    objc.msg_send(void, sv, "setScrollerStyle:", .{@as(NSInteger, 1)});
    objc.msg_send(void, sv, "setAutomaticallyAdjustsContentInsets:", .{objc.NO});
    objc.msg_send(void, sv, "setContentInsets:", .{NSEdgeInsets{
        .top = TOP_INSET,
        .left = 0,
        .bottom = BOTTOM_INSET,
        .right = 0,
    }});

    // When the filter is active, hide a group header that has zero
    // matching items beneath it. Without this, search "bat" leaves
    // every section heading on screen with nothing under most of them.
    var group_has_visible: [256]bool = std.mem.zeroes([256]bool);
    if (g_sidebar_search_len > 0) {
        var i: usize = 0;
        while (i < items.len) : (i += 1) {
            if (items[i].kind != .group) continue;
            var any = false;
            var j: usize = i + 1;
            while (j < items.len) : (j += 1) {
                if (items[j].kind == .group) break;
                if (entry_passes_filter(items[j])) {
                    any = true;
                    break;
                }
            }
            if (i < group_has_visible.len) group_has_visible[i] = any;
        }
    }

    var content_h: CGFloat = 0;
    var group_open: bool = true;
    var current_group_visible: bool = true;
    var added_any: bool = false;
    for (items, 0..) |entry, i| {
        if (entry.kind == .group) {
            const visible = g_sidebar_search_len == 0 or
                (i < group_has_visible.len and group_has_visible[i]);
            current_group_visible = visible;
            if (!visible) {
                group_open = false;
                continue;
            }
            if (added_any) content_h += GROUP_TOP_GAP;
            content_h += GROUP_H + GROUP_BOTTOM_GAP;
            group_open = if (entry.collapsible) g_group_expanded[i] else true;
            added_any = true;
        } else {
            if (!current_group_visible) continue;
            if (!group_open) continue;
            if (!entry_passes_filter(entry)) continue;
            content_h += ROW_H + GAP;
            added_any = true;
        }
    }
    if (content_h < h_total - TOP_INSET - BOTTOM_INSET) {
        content_h = h_total - TOP_INSET - BOTTOM_INSET;
    }

    const doc_alloc = objc.alloc(flipped_cls);
    const doc_view = objc.msg_send(Id, doc_alloc, "initWithFrame:", .{NSRect{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{ .width = w_total, .height = content_h },
    }});
    objc.msg_send(void, doc_view, "setAutoresizingMask:", .{@as(c_uint, NSViewWidthSizable)});

    var y_off: CGFloat = 0;
    var open: bool = true;
    var group_visible: bool = true;
    var first_group: bool = true;
    for (items, 0..) |entry, i| {
        if (entry.kind == .group) {
            const visible = g_sidebar_search_len == 0 or
                (i < group_has_visible.len and group_has_visible[i]);
            group_visible = visible;
            if (!visible) {
                open = false;
                continue;
            }
            if (!first_group) y_off += GROUP_TOP_GAP;
            first_group = false;
            const rect: NSRect = .{
                .origin = .{ .x = SIDE_PAD, .y = y_off },
                .size = .{ .width = w_total - SIDE_PAD * 2, .height = GROUP_H },
            };
            if (entry.collapsible) {
                const alloc_g = objc.alloc(group_cls);
                const g = objc.msg_send(Id, alloc_g, "initWithFrame:", .{rect});
                objc.msg_send(void, g, "setAutoresizingMask:", .{@as(c_uint, NSViewWidthSizable)});
                objc.msg_send(void, doc_view, "addSubview:", .{g});
                if (g_group_len < g_group_buf.len) {
                    g_group_buf[g_group_len] = g;
                    g_group_idx_buf[g_group_len] = i;
                    g_group_len += 1;
                }
                open = g_group_expanded[i];
            } else {
                const alloc_lbl = objc.alloc(NSTextField);
                const lbl = objc.msg_send(Id, alloc_lbl, "initWithFrame:", .{rect});
                var buf: [128]u8 = undefined;
                objc.msg_send(void, lbl, "setStringValue:", .{
                    nsstring_from_stack(&buf, entry.label),
                });
                objc.msg_send(void, lbl, "setEditable:", .{objc.NO});
                objc.msg_send(void, lbl, "setBezeled:", .{objc.NO});
                objc.msg_send(void, lbl, "setDrawsBackground:", .{objc.NO});
                objc.msg_send(void, lbl, "setSelectable:", .{objc.NO});
                const font = objc.msg_send(Id, NSFont, "systemFontOfSize:weight:", .{
                    @as(CGFloat, 10), @as(CGFloat, 0.4),
                });
                objc.msg_send(void, lbl, "setFont:", .{font});
                const tertiary = objc.msg_send(Id, NSColor, "secondaryLabelColor", .{});
                objc.msg_send(void, lbl, "setTextColor:", .{tertiary});
                objc.msg_send(void, lbl, "setAutoresizingMask:", .{
                    @as(c_uint, NSViewWidthSizable),
                });
                objc.msg_send(void, doc_view, "addSubview:", .{lbl});
                open = true;
            }
            y_off += GROUP_H + GROUP_BOTTOM_GAP;
        } else {
            if (!group_visible) continue;
            if (!open) continue;
            if (!entry_passes_filter(entry)) continue;
            const rect: NSRect = .{
                .origin = .{ .x = SIDE_PAD, .y = y_off },
                .size = .{ .width = w_total - SIDE_PAD * 2, .height = ROW_H },
            };
            const alloc_row = objc.alloc(row_cls);
            const row = objc.msg_send(Id, alloc_row, "initWithFrame:", .{rect});
            objc.msg_send(void, row, "setAutoresizingMask:", .{@as(c_uint, NSViewWidthSizable)});
            objc.msg_send(void, row, "setWantsLayer:", .{objc.YES});

            const icon_size_x: CGFloat = 22;
            const icon_pad_x: CGFloat = 8;
            const label_left: CGFloat = icon_pad_x + icon_size_x + 10;
            const label_w: CGFloat = (w_total - SIDE_PAD * 2) - label_left - 4;
            const label_rect = NSRect{
                .origin = .{ .x = label_left, .y = (ROW_H - 18) / 2 },
                .size = .{ .width = label_w, .height = 18 },
            };
            const tf_alloc = objc.alloc(NSTextField);
            const tf = objc.msg_send(Id, tf_alloc, "initWithFrame:", .{label_rect});
            var lbl_buf: [128]u8 = undefined;
            objc.msg_send(void, tf, "setStringValue:", .{
                nsstring_from_stack(&lbl_buf, entry.label),
            });
            objc.msg_send(void, tf, "setEditable:", .{objc.NO});
            objc.msg_send(void, tf, "setBezeled:", .{objc.NO});
            objc.msg_send(void, tf, "setDrawsBackground:", .{objc.NO});
            objc.msg_send(void, tf, "setSelectable:", .{objc.NO});
            objc.msg_send(void, tf, "setAutoresizingMask:", .{
                @as(c_uint, NSViewWidthSizable),
            });
            const tf_font = objc.msg_send(Id, NSFont, "systemFontOfSize:", .{@as(CGFloat, 13)});
            objc.msg_send(void, tf, "setFont:", .{tf_font});
            const label_color = objc.msg_send(Id, NSColor, "labelColor", .{});
            objc.msg_send(void, tf, "setTextColor:", .{label_color});
            objc.msg_send(void, row, "addSubview:", .{tf});

            objc.msg_send(void, doc_view, "addSubview:", .{row});

            if (g_sidebar_buttons_len < g_sidebar_buttons_buf.len) {
                g_sidebar_buttons_buf[g_sidebar_buttons_len] = row;
                g_sidebar_buttons_len += 1;
            }
            if (g_sidebar_text_len < g_sidebar_text_buf.len) {
                g_sidebar_text_buf[g_sidebar_text_len] = tf;
                g_sidebar_text_len += 1;
            }
            if (g_sidebar_buttons_len <= g_sidebar_row_idx_buf.len) {
                g_sidebar_row_idx_buf[g_sidebar_buttons_len - 1] = i;
            }
            y_off += ROW_H + GAP;
        }
    }

    objc.msg_send(void, sv, "setDocumentView:", .{doc_view});
    objc.msg_send(void, handle.sidebar_view, "addSubview:", .{sv});
    refresh_sidebar_button_states();
}

pub fn set_sidebar_on_select(ctx: *anyopaque, callback: SidebarSelectFn) void {
    g_sidebar_select_ctx = ctx;
    g_sidebar_select_fn = callback;
}

pub fn set_sidebar_selection(id: []const u8) void {
    set_sidebar_selected_id(id);
    refresh_sidebar_button_states();
}

pub fn set_native_shell_title(handle: NativeShellHandle, title: []const u8) void {
    var buf: [MAX_NSSTRING_BYTES]u8 = undefined;
    objc.msg_send(void, handle.window, "setTitle:", .{nsstring_from_stack(&buf, title)});
}

const NSWindowToolbarStyleUnified: NSInteger = 3;
const NSToolbarDisplayModeIconOnly: NSInteger = 2;
const NSToolbarItemGroupSelectionModeMomentary: NSInteger = 2;

const TB_ID_SIDEBAR_TOGGLE: []const u8 = "NSToolbarToggleSidebarItem";
const TB_ID_TRACKING_SEP: []const u8 = "NSToolbarSidebarTrackingSeparatorItemIdentifier";
const TB_ID_FLEX_SPACE: []const u8 = "NSToolbarFlexibleSpaceItem";

var g_toolbar_items: ?[]const ToolbarEntry = null;
var g_toolbar_select_ctx: ?*anyopaque = null;
var g_toolbar_select_fn: ?ToolbarSelectFn = null;
var g_toolbar_search_ctx: ?*anyopaque = null;
var g_toolbar_search_fn: ?ToolbarSearchFn = null;
var g_toolbar_split_view: ?Id = null;
var g_toolbar_window: ?Id = null;
var g_toolbar_delegate_class: ?Class = null;
var g_toolbar_delegate_instance: ?Id = null;
var g_toolbar_target_class: ?Class = null;
var g_toolbar_target_instance: ?Id = null;

fn ns_string_equals_zig(ns: Id, expected: []const u8) bool {
    const c_str_opt: ?[*:0]const u8 = objc.msg_send(?[*:0]const u8, ns, "UTF8String", .{});
    const ptr = c_str_opt orelse return false;
    return std.mem.eql(u8, std.mem.sliceTo(ptr, 0), expected);
}

fn fire_toolbar_select(id: []const u8) void {
    if (g_toolbar_select_fn) |cb| if (g_toolbar_select_ctx) |c| cb(c, id);
}

fn tb_entry_id_string(entry: ToolbarEntry) []const u8 {
    return switch (entry.kind) {
        .sidebar_toggle => TB_ID_SIDEBAR_TOGGLE,
        .tracking_separator => TB_ID_TRACKING_SEP,
        .flexible_space => TB_ID_FLEX_SPACE,
        .button, .segmented_group, .search_field, .menu, .custom_view => entry.id,
    };
}

fn build_toolbar_identifier_array() Id {
    const NSMutableArray = objc.get_class("NSMutableArray") orelse unreachable;
    const arr_alloc = objc.alloc(NSMutableArray);
    const arr = objc.msg_send(Id, arr_alloc, "init", .{});
    const items = g_toolbar_items orelse return arr;
    for (items) |entry| {
        var buf: [MAX_NSSTRING_BYTES]u8 = undefined;
        const ns = nsstring_from_stack(&buf, tb_entry_id_string(entry));
        objc.msg_send(void, arr, "addObject:", .{ns});
    }
    return arr;
}

fn toolbar_default_items_imp(_: Id, _: Sel, _: Id) callconv(.c) Id {
    return build_toolbar_identifier_array();
}

fn toolbar_allowed_items_imp(_: Id, _: Sel, _: Id) callconv(.c) Id {
    return build_toolbar_identifier_array();
}

fn apply_item_image(item: Id, ic: ?Icon) void {
    const symbol = if (ic) |i| mac_icon.MacIconSystem.sf_name(i) else return;
    if (symbol.len == 0) return;
    const NSImage = objc.get_class("NSImage") orelse return;
    var sym_buf: [MAX_NSSTRING_BYTES]u8 = undefined;
    const sym = nsstring_from_stack(&sym_buf, symbol);
    const image: ?Id = objc.msg_send(
        ?Id,
        NSImage,
        "imageWithSystemSymbolName:accessibilityDescription:",
        .{ sym, @as(?Id, null) },
    );
    if (image) |img| objc.msg_send(void, item, "setImage:", .{img});
}

fn apply_menu_item_image(menu_item: Id, ic: ?Icon) void {
    const symbol = if (ic) |i| mac_icon.MacIconSystem.sf_name(i) else return;
    if (symbol.len == 0) return;
    const NSImage = objc.get_class("NSImage") orelse return;
    var sym_buf: [MAX_NSSTRING_BYTES]u8 = undefined;
    const sym = nsstring_from_stack(&sym_buf, symbol);
    const image: ?Id = objc.msg_send(
        ?Id,
        NSImage,
        "imageWithSystemSymbolName:accessibilityDescription:",
        .{ sym, @as(?Id, null) },
    );
    if (image) |img| objc.msg_send(void, menu_item, "setImage:", .{img});
}

fn build_button_item(entry: ToolbarEntry, identifier_ns: Id, target: Id) ?Id {
    const NSToolbarItem = objc.get_class("NSToolbarItem") orelse return null;
    const alloc_i = objc.alloc(NSToolbarItem);
    const item = objc.msg_send(Id, alloc_i, "initWithItemIdentifier:", .{identifier_ns});
    var lbl_buf: [MAX_NSSTRING_BYTES]u8 = undefined;
    objc.msg_send(void, item, "setLabel:", .{nsstring_from_stack(&lbl_buf, entry.label)});
    if (entry.tooltip.len > 0) {
        var tip_buf: [MAX_NSSTRING_BYTES]u8 = undefined;
        objc.msg_send(void, item, "setToolTip:", .{nsstring_from_stack(&tip_buf, entry.tooltip)});
    }
    apply_item_image(item, entry.icon);
    objc.msg_send(void, item, "setTarget:", .{target});
    objc.msg_send(void, item, "setAction:", .{objc.sel("toolbarButtonClicked:")});
    return item;
}

fn build_sub_button_item(sub: ToolbarSubItem, target: Id) ?Id {
    const NSToolbarItem = objc.get_class("NSToolbarItem") orelse return null;
    var sub_id_buf: [MAX_NSSTRING_BYTES]u8 = undefined;
    const sub_id_ns = nsstring_from_stack(&sub_id_buf, sub.id);
    const alloc_i = objc.alloc(NSToolbarItem);
    const item = objc.msg_send(Id, alloc_i, "initWithItemIdentifier:", .{sub_id_ns});
    var lbl_buf: [MAX_NSSTRING_BYTES]u8 = undefined;
    objc.msg_send(void, item, "setLabel:", .{nsstring_from_stack(&lbl_buf, sub.label)});
    if (sub.tooltip.len > 0) {
        var tip_buf: [MAX_NSSTRING_BYTES]u8 = undefined;
        objc.msg_send(void, item, "setToolTip:", .{nsstring_from_stack(&tip_buf, sub.tooltip)});
    }
    apply_item_image(item, sub.icon);
    objc.msg_send(void, item, "setTarget:", .{target});
    objc.msg_send(void, item, "setAction:", .{objc.sel("toolbarButtonClicked:")});
    return item;
}

fn build_segmented_group_item(entry: ToolbarEntry, identifier_ns: Id, target: Id) ?Id {
    const NSToolbarItemGroup = objc.get_class("NSToolbarItemGroup") orelse return null;
    const NSMutableArray = objc.get_class("NSMutableArray") orelse return null;
    const alloc_g = objc.alloc(NSToolbarItemGroup);
    const group = objc.msg_send(Id, alloc_g, "initWithItemIdentifier:", .{identifier_ns});
    var lbl_buf: [MAX_NSSTRING_BYTES]u8 = undefined;
    objc.msg_send(void, group, "setLabel:", .{nsstring_from_stack(&lbl_buf, entry.label)});
    objc.msg_send(void, group, "setSelectionMode:", .{NSToolbarItemGroupSelectionModeMomentary});

    const subs_alloc = objc.alloc(NSMutableArray);
    const subs = objc.msg_send(Id, subs_alloc, "init", .{});
    for (entry.sub_items) |sub| {
        const sub_item = build_sub_button_item(sub, target) orelse continue;
        objc.msg_send(void, subs, "addObject:", .{sub_item});
    }
    objc.msg_send(void, group, "setSubitems:", .{subs});
    return group;
}

fn build_search_field_item(
    entry: ToolbarEntry,
    identifier_ns: Id,
    entry_idx: usize,
    target: Id,
) ?Id {
    const NSSearchToolbarItem = objc.get_class("NSSearchToolbarItem") orelse return null;
    const alloc_i = objc.alloc(NSSearchToolbarItem);
    const item = objc.msg_send(Id, alloc_i, "initWithItemIdentifier:", .{identifier_ns});
    var lbl_buf: [MAX_NSSTRING_BYTES]u8 = undefined;
    objc.msg_send(void, item, "setLabel:", .{nsstring_from_stack(&lbl_buf, entry.label)});
    if (entry.tooltip.len > 0) {
        var tip_buf: [MAX_NSSTRING_BYTES]u8 = undefined;
        objc.msg_send(void, item, "setToolTip:", .{nsstring_from_stack(&tip_buf, entry.tooltip)});
    }
    const search_field: Id = objc.msg_send(Id, item, "searchField", .{});
    objc.msg_send(void, search_field, "setTag:", .{@as(NSInteger, @intCast(entry_idx))});
    objc.msg_send(void, search_field, "setTarget:", .{target});
    objc.msg_send(void, search_field, "setAction:", .{objc.sel("toolbarSearchChanged:")});
    objc.msg_send(void, search_field, "setSendsSearchStringImmediately:", .{objc.YES});
    return item;
}

fn build_menu_item(entry: ToolbarEntry, identifier_ns: Id, entry_idx: usize, target: Id) ?Id {
    const NSMenuToolbarItem = objc.get_class("NSMenuToolbarItem") orelse return null;
    const NSMenu = objc.get_class("NSMenu") orelse return null;
    const NSMenuItem = objc.get_class("NSMenuItem") orelse return null;
    const alloc_i = objc.alloc(NSMenuToolbarItem);
    const item = objc.msg_send(Id, alloc_i, "initWithItemIdentifier:", .{identifier_ns});
    var lbl_buf: [MAX_NSSTRING_BYTES]u8 = undefined;
    objc.msg_send(void, item, "setLabel:", .{nsstring_from_stack(&lbl_buf, entry.label)});
    if (entry.tooltip.len > 0) {
        var tip_buf: [MAX_NSSTRING_BYTES]u8 = undefined;
        objc.msg_send(void, item, "setToolTip:", .{nsstring_from_stack(&tip_buf, entry.tooltip)});
    }
    apply_item_image(item, entry.icon);

    const menu_alloc = objc.alloc(NSMenu);
    const menu = objc.msg_send(Id, menu_alloc, "init", .{});
    const click_sel = objc.sel("toolbarMenuClicked:");
    for (entry.menu_items, 0..) |mi, j| {
        var mi_lbl_buf: [MAX_NSSTRING_BYTES]u8 = undefined;
        var mi_key_buf: [MAX_NSSTRING_BYTES]u8 = undefined;
        const mi_lbl_ns = nsstring_from_stack(&mi_lbl_buf, mi.label);
        const mi_key_ns = nsstring_from_stack(&mi_key_buf, "");
        const mi_alloc = objc.alloc(NSMenuItem);
        const menu_item = objc.msg_send(Id, mi_alloc, "initWithTitle:action:keyEquivalent:", .{
            mi_lbl_ns, click_sel, mi_key_ns,
        });
        objc.msg_send(void, menu_item, "setTarget:", .{target});
        const tag: NSInteger = @intCast(entry_idx * 1000 + j);
        objc.msg_send(void, menu_item, "setTag:", .{tag});
        apply_menu_item_image(menu_item, mi.icon);
        objc.msg_send(void, menu, "addItem:", .{menu_item});
    }
    objc.msg_send(void, item, "setMenu:", .{menu});
    return item;
}

fn build_custom_view_item(entry: ToolbarEntry, identifier_ns: Id) ?Id {
    const NSToolbarItem = objc.get_class("NSToolbarItem") orelse return null;
    const view_ptr = entry.custom_view orelse return null;
    const view: Id = @ptrCast(view_ptr);
    const alloc_i = objc.alloc(NSToolbarItem);
    const item = objc.msg_send(Id, alloc_i, "initWithItemIdentifier:", .{identifier_ns});
    var lbl_buf: [MAX_NSSTRING_BYTES]u8 = undefined;
    objc.msg_send(void, item, "setLabel:", .{nsstring_from_stack(&lbl_buf, entry.label)});
    objc.msg_send(void, item, "setView:", .{view});
    if (entry.min_width > 0 or entry.max_width > 0) {
        const min_w: CGFloat = if (entry.min_width > 0) entry.min_width else 0;
        const max_w: CGFloat = if (entry.max_width > 0) entry.max_width else min_w;
        objc.msg_send(void, item, "setMinSize:", .{NSSize{ .width = min_w, .height = 24 }});
        objc.msg_send(void, item, "setMaxSize:", .{NSSize{ .width = max_w, .height = 24 }});
    }
    return item;
}

fn build_toolbar_item(entry: ToolbarEntry, entry_idx: usize, identifier_ns: Id) ?Id {
    const NSToolbarItem = objc.get_class("NSToolbarItem") orelse return null;
    const target = ensure_toolbar_target() orelse return null;
    const item_opt: ?Id = switch (entry.kind) {
        .sidebar_toggle, .flexible_space => blk: {
            const alloc_i = objc.alloc(NSToolbarItem);
            break :blk objc.msg_send(Id, alloc_i, "initWithItemIdentifier:", .{identifier_ns});
        },
        .tracking_separator => blk: {
            const NSTrackingSep =
                objc.get_class("NSTrackingSeparatorToolbarItem") orelse break :blk null;
            const split_view = g_toolbar_split_view orelse break :blk null;
            break :blk objc.msg_send(
                Id,
                NSTrackingSep,
                "trackingSeparatorToolbarItemWithIdentifier:splitView:dividerIndex:",
                .{
                    identifier_ns, split_view, @as(NSInteger, 0),
                },
            );
        },
        .button => build_button_item(entry, identifier_ns, target),
        .segmented_group => build_segmented_group_item(entry, identifier_ns, target),
        .search_field => build_search_field_item(entry, identifier_ns, entry_idx, target),
        .menu => build_menu_item(entry, identifier_ns, entry_idx, target),
        .custom_view => build_custom_view_item(entry, identifier_ns),
    };
    if (item_opt) |item| {
        objc.msg_send(void, item, "setEnabled:", .{if (entry.enabled) objc.YES else objc.NO});
    }
    return item_opt;
}

fn toolbar_item_for_identifier_imp(_: Id, _: Sel, _: Id, identifier: Id, _: bool) callconv(.c) ?Id {
    const items = g_toolbar_items orelse return null;
    for (items, 0..) |entry, i| {
        const id_str = tb_entry_id_string(entry);
        if (ns_string_equals_zig(identifier, id_str)) {
            return build_toolbar_item(entry, i, identifier);
        }
    }
    return null;
}

fn ensure_toolbar_delegate() ?Id {
    if (g_toolbar_delegate_instance) |i| return i;
    const NSObject = objc.get_class("NSObject") orelse return null;
    if (g_toolbar_delegate_class == null) {
        const cls = objc.objc_allocateClassPair(NSObject, "ZigUIToolbarDelegate", 0) orelse
            return null;
        _ = objc.class_addMethod(
            cls,
            objc.sel("toolbar:itemForItemIdentifier:willBeInsertedIntoToolbar:"),
            @ptrCast(&toolbar_item_for_identifier_imp),
            "@@:@@B",
        );
        _ = objc.class_addMethod(
            cls,
            objc.sel("toolbarDefaultItemIdentifiers:"),
            @ptrCast(&toolbar_default_items_imp),
            "@@:@",
        );
        _ = objc.class_addMethod(
            cls,
            objc.sel("toolbarAllowedItemIdentifiers:"),
            @ptrCast(&toolbar_allowed_items_imp),
            "@@:@",
        );
        objc.objc_registerClassPair(cls);
        g_toolbar_delegate_class = cls;
    }
    const alloc = objc.alloc(g_toolbar_delegate_class.?);
    g_toolbar_delegate_instance = objc.msg_send(Id, alloc, "init", .{});
    return g_toolbar_delegate_instance;
}

fn toolbar_button_clicked_imp(_: Id, _: Sel, sender: Id) callconv(.c) void {
    const identifier: Id = objc.msg_send(Id, sender, "itemIdentifier", .{});
    const items = g_toolbar_items orelse return;
    for (items) |entry| {
        switch (entry.kind) {
            .button => {
                if (ns_string_equals_zig(identifier, entry.id)) {
                    fire_toolbar_select(entry.id);
                    return;
                }
            },
            .segmented_group => {
                for (entry.sub_items) |sub| {
                    if (ns_string_equals_zig(identifier, sub.id)) {
                        fire_toolbar_select(sub.id);
                        return;
                    }
                }
            },
            else => {},
        }
    }
}

fn toolbar_menu_clicked_imp(_: Id, _: Sel, sender: Id) callconv(.c) void {
    const tag: NSInteger = objc.msg_send(NSInteger, sender, "tag", .{});
    const items = g_toolbar_items orelse return;
    const entry_idx: usize = @intCast(@divTrunc(tag, 1000));
    const sub_idx: usize = @intCast(@mod(tag, 1000));
    if (entry_idx >= items.len) return;
    const entry = items[entry_idx];
    if (entry.kind != .menu) return;
    if (sub_idx >= entry.menu_items.len) return;
    fire_toolbar_select(entry.menu_items[sub_idx].id);
}

fn toolbar_search_changed_imp(_: Id, _: Sel, sender: Id) callconv(.c) void {
    const tag: NSInteger = objc.msg_send(NSInteger, sender, "tag", .{});
    const items = g_toolbar_items orelse return;
    const idx: usize = @intCast(tag);
    if (idx >= items.len) return;
    const entry = items[idx];
    if (entry.kind != .search_field) return;
    const string_val: Id = objc.msg_send(Id, sender, "stringValue", .{});
    const c_str_opt: ?[*:0]const u8 = objc.msg_send(?[*:0]const u8, string_val, "UTF8String", .{});
    const ptr = c_str_opt orelse return;
    const text = std.mem.sliceTo(ptr, 0);
    if (g_toolbar_search_fn) |cb| if (g_toolbar_search_ctx) |c| cb(c, entry.id, text);
}

fn ensure_toolbar_target() ?Id {
    if (g_toolbar_target_instance) |i| return i;
    const NSObject = objc.get_class("NSObject") orelse return null;
    if (g_toolbar_target_class == null) {
        const cls = objc.objc_allocateClassPair(NSObject, "ZigUIToolbarTarget", 0) orelse
            return null;
        _ = objc.class_addMethod(
            cls,
            objc.sel("toolbarButtonClicked:"),
            @ptrCast(&toolbar_button_clicked_imp),
            "v@:@",
        );
        _ = objc.class_addMethod(
            cls,
            objc.sel("toolbarMenuClicked:"),
            @ptrCast(&toolbar_menu_clicked_imp),
            "v@:@",
        );
        _ = objc.class_addMethod(
            cls,
            objc.sel("toolbarSearchChanged:"),
            @ptrCast(&toolbar_search_changed_imp),
            "v@:@",
        );
        objc.objc_registerClassPair(cls);
        g_toolbar_target_class = cls;
    }
    const alloc = objc.alloc(g_toolbar_target_class.?);
    g_toolbar_target_instance = objc.msg_send(Id, alloc, "init", .{});
    return g_toolbar_target_instance;
}

pub fn set_toolbar_items(handle: NativeShellHandle, items: []const ToolbarEntry) void {
    g_toolbar_items = items;
    g_toolbar_window = handle.window;
    g_toolbar_split_view = objc.msg_send(Id, handle.split_controller, "splitView", .{});
    const delegate = ensure_toolbar_delegate() orelse return;

    const NSToolbar = objc.get_class("NSToolbar") orelse return;
    const tb_alloc = objc.alloc(NSToolbar);
    var id_buf: [MAX_NSSTRING_BYTES]u8 = undefined;
    const tb = objc.msg_send(Id, tb_alloc, "initWithIdentifier:", .{
        nsstring_from_stack(&id_buf, "ZigUIWindowToolbar"),
    });
    objc.msg_send(void, tb, "setDelegate:", .{delegate});
    objc.msg_send(void, tb, "setDisplayMode:", .{NSToolbarDisplayModeIconOnly});
    objc.msg_send(void, tb, "setAllowsUserCustomization:", .{objc.NO});
    objc.msg_send(void, tb, "setShowsBaselineSeparator:", .{objc.NO});

    objc.msg_send(void, handle.window, "setToolbarStyle:", .{NSWindowToolbarStyleUnified});
    objc.msg_send(void, handle.window, "setToolbar:", .{tb});
}

pub fn set_toolbar_on_select(ctx: *anyopaque, callback: ToolbarSelectFn) void {
    g_toolbar_select_ctx = ctx;
    g_toolbar_select_fn = callback;
}

pub fn set_toolbar_on_search(ctx: *anyopaque, callback: ToolbarSearchFn) void {
    g_toolbar_search_ctx = ctx;
    g_toolbar_search_fn = callback;
}

// Returned slice aliases out_buf; out_buf must outlive the caller's use of it.
pub fn open_file(opts: FilePickerOptions, out_buf: []u8) []const u8 {
    const NSOpenPanel = objc.get_class("NSOpenPanel") orelse return "";
    const panel = objc.msg_send(Id, NSOpenPanel, "openPanel", .{});

    if (opts.title.len > 0) {
        var b: [MAX_NSSTRING_BYTES]u8 = undefined;
        objc.msg_send(void, panel, "setTitle:", .{nsstring_from_stack(&b, opts.title)});
    }
    if (opts.message.len > 0) {
        var b: [MAX_NSSTRING_BYTES]u8 = undefined;
        objc.msg_send(void, panel, "setMessage:", .{nsstring_from_stack(&b, opts.message)});
    }
    if (opts.button_label.len > 0) {
        var b: [MAX_NSSTRING_BYTES]u8 = undefined;
        objc.msg_send(void, panel, "setPrompt:", .{nsstring_from_stack(&b, opts.button_label)});
    }

    objc.msg_send(void, panel, "setCanChooseFiles:", .{
        if (opts.allow_files) objc.YES else objc.NO,
    });
    objc.msg_send(void, panel, "setCanChooseDirectories:", .{
        if (opts.allow_directories) objc.YES else objc.NO,
    });
    objc.msg_send(void, panel, "setAllowsMultipleSelection:", .{
        if (opts.allow_multiple) objc.YES else objc.NO,
    });

    const resp: NSInteger = objc.msg_send(NSInteger, panel, "runModal", .{});
    if (resp != 1) return ""; // NSModalResponseOK = 1

    const url: Id = objc.msg_send(Id, panel, "URL", .{});
    if (@intFromPtr(url) == 0) return "";
    const path_ns: Id = objc.msg_send(Id, url, "path", .{});
    const c_str: ?[*:0]const u8 = objc.msg_send(?[*:0]const u8, path_ns, "UTF8String", .{});
    const ptr = c_str orelse return "";
    const slice = std.mem.sliceTo(ptr, 0);
    const n = @min(slice.len, out_buf.len);
    @memcpy(out_buf[0..n], slice[0..n]);
    return out_buf[0..n];
}

pub fn save_file(opts: FilePickerOptions, out_buf: []u8) []const u8 {
    const NSSavePanel = objc.get_class("NSSavePanel") orelse return "";
    const panel = objc.msg_send(Id, NSSavePanel, "savePanel", .{});

    if (opts.title.len > 0) {
        var b: [MAX_NSSTRING_BYTES]u8 = undefined;
        objc.msg_send(void, panel, "setTitle:", .{nsstring_from_stack(&b, opts.title)});
    }
    if (opts.message.len > 0) {
        var b: [MAX_NSSTRING_BYTES]u8 = undefined;
        objc.msg_send(void, panel, "setMessage:", .{nsstring_from_stack(&b, opts.message)});
    }
    if (opts.button_label.len > 0) {
        var b: [MAX_NSSTRING_BYTES]u8 = undefined;
        objc.msg_send(void, panel, "setPrompt:", .{nsstring_from_stack(&b, opts.button_label)});
    }
    if (opts.default_filename.len > 0) {
        var b: [MAX_NSSTRING_BYTES]u8 = undefined;
        objc.msg_send(void, panel, "setNameFieldStringValue:", .{
            nsstring_from_stack(&b, opts.default_filename),
        });
    }

    const resp: NSInteger = objc.msg_send(NSInteger, panel, "runModal", .{});
    if (resp != 1) return "";

    const url: Id = objc.msg_send(Id, panel, "URL", .{});
    if (@intFromPtr(url) == 0) return "";
    const path_ns: Id = objc.msg_send(Id, url, "path", .{});
    const c_str: ?[*:0]const u8 = objc.msg_send(?[*:0]const u8, path_ns, "UTF8String", .{});
    const ptr = c_str orelse return "";
    const slice = std.mem.sliceTo(ptr, 0);
    const n = @min(slice.len, out_buf.len);
    @memcpy(out_buf[0..n], slice[0..n]);
    return out_buf[0..n];
}

pub fn native_image_named(name: []const u8) ?*anyopaque {
    const NSImage = objc.get_class("NSImage") orelse return null;
    var b: [128]u8 = undefined;
    const ns = nsstring_from_stack(&b, name);
    const img: ?Id = objc.msg_send(?Id, NSImage, "imageNamed:", .{ns});
    if (img) |i| return @ptrCast(i);
    return null;
}

pub fn run_alert(opts: AlertOptions) usize {
    const NSAlert = objc.get_class("NSAlert") orelse return 0;
    const alloc = objc.alloc(NSAlert);
    const alert = objc.msg_send(Id, alloc, "init", .{});

    objc.msg_send(void, alert, "setAlertStyle:", .{@as(NSInteger, @intFromEnum(opts.style))});

    var title_buf: [MAX_NSSTRING_BYTES]u8 = undefined;
    objc.msg_send(void, alert, "setMessageText:", .{nsstring_from_stack(&title_buf, opts.title)});

    if (opts.message.len > 0) {
        var msg_buf: [MAX_NSSTRING_BYTES]u8 = undefined;
        objc.msg_send(void, alert, "setInformativeText:", .{
            nsstring_from_stack(&msg_buf, opts.message),
        });
    }

    for (opts.buttons) |btn| {
        var btn_buf: [MAX_NSSTRING_BYTES]u8 = undefined;
        objc.msg_send(void, alert, "addButtonWithTitle:", .{nsstring_from_stack(&btn_buf, btn)});
    }

    const NSAlertFirstButtonReturn: NSInteger = 1000;
    const resp: NSInteger = objc.msg_send(NSInteger, alert, "runModal", .{});
    if (resp < NSAlertFirstButtonReturn) return 0;
    return @intCast(resp - NSAlertFirstButtonReturn);
}

pub fn open_native_shell(opts: NativeShellOptions) Error!NativeShellHandle {
    std.debug.assert(opts.width > 0);
    std.debug.assert(opts.height > 0);
    std.debug.assert(opts.sidebar_width > 0);
    g_sidebar_search_enabled = opts.sidebar_search;

    const NSWindow = objc.get_class("NSWindow") orelse return Error.NoNSWindowClass;
    const NSVisualEffectView = objc.get_class("NSVisualEffectView") orelse
        return Error.NoNSViewClass;
    const NSViewController = objc.get_class("NSViewController") orelse
        return Error.NoNSViewClass;
    const NSSplitViewController = objc.get_class("NSSplitViewController") orelse
        return Error.NoNSViewClass;
    const NSSplitViewItem = objc.get_class("NSSplitViewItem") orelse return Error.NoNSViewClass;
    const CAMetalLayer = objc.get_class("CAMetalLayer") orelse
        return Error.NoCAMetalLayerClass;

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
        .{
            frame, style, NSBackingStoreBuffered, objc.NO,
        },
    );
    if (@intFromPtr(window) == 0) return Error.NSWindowInitFailed;
    _ = objc.msg_send(Id, window, "retain", .{});
    errdefer objc.msg_send(void, window, "release", .{});

    var title_buf: [MAX_NSSTRING_BYTES]u8 = undefined;
    objc.msg_send(void, window, "setTitle:", .{nsstring_from_stack(&title_buf, opts.title)});
    objc.msg_send(void, window, "setTitleVisibility:", .{NSWindowTitleVisible});
    objc.msg_send(void, window, "setTitlebarSeparatorStyle:", .{
        @intFromEnum(opts.toolbar_separator),
    });
    // Transparent titlebar lets the NSVisualEffectView canvas reach
    // edge-to-edge across toolbar + sidebar + body.
    objc.msg_send(void, window, "setTitlebarAppearsTransparent:", .{objc.YES});

    const NSView_for_sidebar = objc.get_class("NSView") orelse return Error.NoNSViewClass;
    const sidebar_view = blk: {
        const alloc_v = objc.alloc(NSView_for_sidebar);
        const v = objc.msg_send(Id, alloc_v, "initWithFrame:", .{NSRect{
            .origin = .{ .x = 0, .y = 0 },
            .size = .{ .width = opts.sidebar_width, .height = opts.height },
        }});
        objc.msg_send(void, v, "setAutoresizingMask:", .{
            @as(c_uint, NSViewWidthSizable | NSViewHeightSizable),
        });
        break :blk v;
    };
    _ = NSVisualEffectView;
    const sidebar_vc = blk: {
        const alloc_vc = objc.alloc(NSViewController);
        const vc = objc.msg_send(Id, alloc_vc, "init", .{});
        objc.msg_send(void, vc, "setView:", .{sidebar_view});
        break :blk vc;
    };

    const body_cls = ensure_body_view_class() orelse return Error.NoNSViewClass;
    const content_view = blk: {
        const alloc_v = objc.alloc(body_cls);
        const v = objc.msg_send(Id, alloc_v, "initWithFrame:", .{NSRect{
            .origin = .{ .x = 0, .y = 0 },
            .size = .{ .width = opts.width - opts.sidebar_width, .height = opts.height },
        }});
        objc.msg_send(void, v, "setAutoresizingMask:", .{
            @as(c_uint, NSViewWidthSizable | NSViewHeightSizable),
        });
        objc.msg_send(void, v, "setWantsLayer:", .{objc.YES});
        break :blk v;
    };

    const metal_layer = objc.msg_send(Id, CAMetalLayer, "layer", .{});
    const scale: CGFloat = objc.msg_send(CGFloat, window, "backingScaleFactor", .{});
    objc.msg_send(void, metal_layer, "setContentsScale:", .{scale});
    const drawable_size = CGSize{
        .width = (opts.width - opts.sidebar_width) * scale,
        .height = opts.height * scale,
    };
    objc.msg_send(void, metal_layer, "setDrawableSize:", .{drawable_size});
    objc.msg_send(void, metal_layer, "setNeedsDisplayOnBoundsChange:", .{objc.YES});
    objc.msg_send(void, metal_layer, "setAutoresizingMask:", .{
        @as(c_uint, NSViewWidthSizable | NSViewHeightSizable),
    });
    objc.msg_send(void, metal_layer, "setOpaque:", .{objc.NO});
    objc.msg_send(void, content_view, "setLayer:", .{metal_layer});

    const content_vc = blk: {
        const alloc_vc = objc.alloc(NSViewController);
        const vc = objc.msg_send(Id, alloc_vc, "init", .{});
        objc.msg_send(void, vc, "setView:", .{content_view});
        break :blk vc;
    };

    const sidebar_item = objc.msg_send(Id, NSSplitViewItem, "sidebarWithViewController:", .{
        sidebar_vc,
    });
    objc.msg_send(void, sidebar_item, "setMinimumThickness:", .{
        @as(CGFloat, opts.sidebar_min_width),
    });
    objc.msg_send(void, sidebar_item, "setMaximumThickness:", .{
        @as(CGFloat, opts.sidebar_max_width),
    });
    objc.msg_send(void, sidebar_item, "setPreferredThicknessFraction:", .{
        @as(CGFloat, opts.sidebar_width / opts.width),
    });

    const content_item = objc.msg_send(Id, NSSplitViewItem, "splitViewItemWithViewController:", .{
        content_vc,
    });

    const split_alloc = objc.alloc(NSSplitViewController);
    const split = objc.msg_send(Id, split_alloc, "init", .{});
    objc.msg_send(void, split, "addSplitViewItem:", .{sidebar_item});
    objc.msg_send(void, split, "addSplitViewItem:", .{content_item});

    objc.msg_send(void, window, "setContentViewController:", .{split});

    // Wrap split's view in NSVisualEffectView so toolbar + sidebar + body
    // share one translucent canvas; sidebar and body stay transparent.
    {
        const NSVE_root = objc.get_class("NSVisualEffectView") orelse unreachable;
        const split_view_id: Id = objc.msg_send(Id, split, "view", .{});
        const split_frame: NSRect = objc.msg_send(NSRect, split_view_id, "frame", .{});
        const vfx_alloc = objc.alloc(NSVE_root);
        const vfx = objc.msg_send(Id, vfx_alloc, "initWithFrame:", .{split_frame});
        // NSVisualEffectMaterialUnderWindowBackground
        objc.msg_send(void, vfx, "setMaterial:", .{@as(NSUInteger, 21)});
        objc.msg_send(void, vfx, "setBlendingMode:", .{NSVisualEffectBlendingModeBehindWindow});
        objc.msg_send(void, vfx, "setState:", .{NSVisualEffectStateActive});
        objc.msg_send(void, vfx, "setAutoresizingMask:", .{
            @as(c_uint, NSViewWidthSizable | NSViewHeightSizable),
        });
        objc.msg_send(void, split_view_id, "setAutoresizingMask:", .{
            @as(c_uint, NSViewWidthSizable | NSViewHeightSizable),
        });
        objc.msg_send(void, vfx, "addSubview:", .{split_view_id});
        objc.msg_send(void, window, "setContentView:", .{vfx});

        // Non-opaque + clearColor: required for the visual effect
        // material's translucency to reach the desktop.
        const NSColor_root = objc.get_class("NSColor") orelse unreachable;
        const clear_color = objc.msg_send(Id, NSColor_root, "clearColor", .{});
        objc.msg_send(void, window, "setBackgroundColor:", .{clear_color});
        objc.msg_send(void, window, "setOpaque:", .{objc.NO});
    }

    objc.msg_send(void, window, "setMinSize:", .{NSSize{
        .width = opts.min_width,
        .height = opts.min_height,
    }});
    objc.msg_send(void, window, "center", .{});

    return .{
        .window = window,
        .split_controller = split,
        .sidebar_view = sidebar_view,
        .content_view = content_view,
        .metal_layer = metal_layer,
        .height = @floatCast(opts.height),
    };
}
