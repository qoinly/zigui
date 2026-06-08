const std = @import("std");
const objc = @import("objc.zig");
const menu = @import("menu.zig");
const types = @import("../../status_bar.zig");

const Id = objc.Id;
const Sel = objc.Sel;
const Class = objc.Class;
const NSUInteger = objc.NSUInteger;
const NSInteger = objc.NSInteger;
const CGFloat = objc.CGFloat;

pub const MenuItem = menu.MenuItem;
pub const MenuAction = menu.MenuAction;
pub const Modifiers = menu.Modifiers;
pub const StatusItemConfig = types.StatusItemConfig;

const NSStatusItemLength = struct {
    const Variable: CGFloat = -1.0;
    const Square: CGFloat = -2.0;
};

const NSEventModifierFlagCommand: NSUInteger = 1 << 20;
const NSEventModifierFlagShift: NSUInteger = 1 << 17;
const NSEventModifierFlagOption: NSUInteger = 1 << 19;
const NSEventModifierFlagControl: NSUInteger = 1 << 18;

var status_items: std.ArrayListUnmanaged(StatusItemHandle) = .empty;
var allocator_ref: ?std.mem.Allocator = null;
var app_ptr: ?*anyopaque = null;
var stored_actions: std.ArrayListUnmanaged(StoredAction) = .empty;
var stored_button_actions: std.ArrayListUnmanaged(StoredButtonAction) = .empty;

const StoredAction = struct {
    menu_action: MenuAction,
};

const StoredButtonAction = struct {
    ctx: *anyopaque,
    callback: *const fn (*anyopaque) void,
    right_click_menu: ?Id = null,
};

const NSEventTypeRightMouseDown: NSUInteger = 3;
const NSEventTypeRightMouseUp: NSUInteger = 4;
const NSEventMaskLeftMouseUp: NSUInteger = 1 << 2;
const NSEventMaskRightMouseUp: NSUInteger = 1 << 4;

pub const ScreenRect = extern struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
};

const StatusItemHandle = struct {
    ns_status_item: Id,
    ns_menu: ?Id,
};

var status_menu_delegate_class: ?Class = null;
var shared_status_menu_delegate: ?Id = null;

pub fn init(allocator: std.mem.Allocator, app: *anyopaque) void {
    allocator_ref = allocator;
    app_ptr = app;
}

pub fn create_status_item(config: StatusItemConfig) ?*anyopaque {
    const allocator = allocator_ref orelse return null;
    const pool = objc.autorelease_pool_push();
    defer objc.autorelease_pool_pop(pool);

    const NSStatusBar = objc.get_class("NSStatusBar") orelse return null;
    const system_status_bar = objc.msg_send(Id, NSStatusBar, "systemStatusBar", .{});
    if (@intFromPtr(system_status_bar) == 0) return null;

    const ns_status_item = objc.msg_send(
        Id,
        system_status_bar,
        "statusItemWithLength:",
        .{NSStatusItemLength.Variable},
    );
    if (@intFromPtr(ns_status_item) == 0) return null;

    _ = objc.msg_send(Id, ns_status_item, "retain", .{}); // survive pool drain

    const button: ?Id = objc.msg_send(?Id, ns_status_item, "button", .{});

    if (button) |btn| {
        var has_image = false;

        if (config.symbol_name) |symbol| {
            const NSImage = objc.get_class("NSImage") orelse return null;
            const ns_symbol_name = create_ns_string(symbol);
            const image: ?Id = objc.msg_send(
                ?Id,
                NSImage,
                "imageWithSystemSymbolName:accessibilityDescription:",
                .{ ns_symbol_name, @as(?Id, null) },
            );
            if (image) |img| {
                objc.msg_send(void, img, "setTemplate:", .{objc.YES});
                const NSSize = extern struct { width: CGFloat, height: CGFloat };
                objc.msg_send(void, img, "setSize:", .{NSSize{ .width = 18.0, .height = 18.0 }});
                objc.msg_send(void, btn, "setImage:", .{img});
                has_image = true;
            }
        }

        if (!has_image) {
            if (config.title) |title| {
                const ns_title = create_ns_string(title);
                objc.msg_send(void, btn, "setTitle:", .{ns_title});
            }
        }

        if (config.tooltip) |tooltip| {
            const ns_tooltip = create_ns_string(tooltip);
            objc.msg_send(void, btn, "setToolTip:", .{ns_tooltip});
        }
    }

    var ns_menu: ?Id = null;
    if (config.menu_items.len > 0) {
        ns_menu = create_status_menu(allocator, config.menu_items, 0);
        if (ns_menu) |m| {
            objc.msg_send(void, ns_status_item, "setMenu:", .{m});
        }
    }

    objc.msg_send(void, ns_status_item, "setVisible:", .{
        if (config.visible) objc.YES else objc.NO,
    });

    const handle = StatusItemHandle{
        .ns_status_item = ns_status_item,
        .ns_menu = ns_menu,
    };
    status_items.append(allocator, handle) catch return null;

    return @ptrFromInt(@intFromPtr(ns_status_item));
}

pub fn set_title(status_item: *anyopaque, title: []const u8) void {
    const pool = objc.autorelease_pool_push();
    defer objc.autorelease_pool_pop(pool);

    const ns_status_item: Id = @ptrCast(status_item);
    const button: ?Id = objc.msg_send(?Id, ns_status_item, "button", .{});
    if (button) |btn| {
        const ns_title = create_ns_string(title);
        objc.msg_send(void, btn, "setTitle:", .{ns_title});
    }
}

pub const SegmentKind = enum(u8) { text, symbol };

pub const Segment = struct {
    kind: SegmentKind = .text,
    str: []const u8 = "",
    r: f32 = 1,
    g: f32 = 1,
    b: f32 = 1,
    a: f32 = 1,
    size: f32 = 12,
    weight: f32 = 0,
};

pub fn set_attributed_title(status_item: *anyopaque, segments: []const Segment) void {
    const pool = objc.autorelease_pool_push();
    defer objc.autorelease_pool_pop(pool);

    const ns_status_item: Id = @ptrCast(status_item);
    const button: ?Id = objc.msg_send(?Id, ns_status_item, "button", .{}) orelse return;
    const btn = button.?;

    const NSMutableAttributedString = objc.get_class("NSMutableAttributedString") orelse return;
    const NSAttributedString = objc.get_class("NSAttributedString") orelse return;
    const NSColor = objc.get_class("NSColor") orelse return;
    const NSFont = objc.get_class("NSFont") orelse return;
    const NSImage = objc.get_class("NSImage") orelse return;
    const NSTextAttachment = objc.get_class("NSTextAttachment") orelse return;
    const NSMutableDictionary = objc.get_class("NSMutableDictionary") orelse return;

    // These literals are the underlying string values of the
    // NSForegroundColorAttributeName / NSFontAttributeName constants.
    const FG_KEY = create_ns_string("NSColor");
    const FONT_KEY = create_ns_string("NSFont");

    var mstr = objc.msg_send(Id, NSMutableAttributedString, "alloc", .{});
    mstr = objc.msg_send(Id, mstr, "init", .{});
    defer objc.msg_send(void, mstr, "release", .{});

    for (segments) |seg| {
        const color = objc.msg_send(Id, NSColor, "colorWithSRGBRed:green:blue:alpha:", .{
            @as(CGFloat, seg.r),
            @as(CGFloat, seg.g),
            @as(CGFloat, seg.b),
            @as(CGFloat, seg.a),
        });
        switch (seg.kind) {
            .text => {
                const font = objc.msg_send(Id, NSFont, "systemFontOfSize:weight:", .{
                    @as(CGFloat, seg.size),
                    @as(CGFloat, seg.weight),
                });
                var attrs = objc.msg_send(Id, NSMutableDictionary, "alloc", .{});
                attrs = objc.msg_send(Id, attrs, "init", .{});
                defer objc.msg_send(void, attrs, "release", .{});
                objc.msg_send(void, attrs, "setObject:forKey:", .{ color, FG_KEY });
                objc.msg_send(void, attrs, "setObject:forKey:", .{ font, FONT_KEY });

                const ns_text = create_ns_string(seg.str);
                var run = objc.msg_send(Id, NSAttributedString, "alloc", .{});
                run = objc.msg_send(Id, run, "initWithString:attributes:", .{ ns_text, attrs });
                defer objc.msg_send(void, run, "release", .{});
                objc.msg_send(void, mstr, "appendAttributedString:", .{run});
            },
            .symbol => {
                const ns_name = create_ns_string(seg.str);
                const image: ?Id = objc.msg_send(
                    ?Id,
                    NSImage,
                    "imageWithSystemSymbolName:accessibilityDescription:",
                    .{ ns_name, @as(?Id, null) },
                );
                if (image == null) continue;
                const img = image.?;
                objc.msg_send(void, img, "setTemplate:", .{objc.YES});

                var attachment = objc.msg_send(Id, NSTextAttachment, "alloc", .{});
                attachment = objc.msg_send(Id, attachment, "init", .{});
                defer objc.msg_send(void, attachment, "release", .{});
                objc.msg_send(void, attachment, "setImage:", .{img});

                const run = objc.msg_send(
                    Id,
                    NSAttributedString,
                    "attributedStringWithAttachment:",
                    .{attachment},
                );

                var mrun = objc.msg_send(Id, NSMutableAttributedString, "alloc", .{});
                mrun = objc.msg_send(Id, mrun, "initWithAttributedString:", .{run});
                defer objc.msg_send(void, mrun, "release", .{});

                const len = objc.msg_send(NSUInteger, mrun, "length", .{});
                const RangeT = extern struct { location: NSUInteger, length: NSUInteger };
                objc.msg_send(void, mrun, "addAttribute:value:range:", .{
                    FG_KEY,
                    color,
                    RangeT{ .location = 0, .length = len },
                });
                objc.msg_send(void, mstr, "appendAttributedString:", .{mrun});
            },
        }
    }

    objc.msg_send(void, btn, "setAttributedTitle:", .{mstr});
}

pub fn set_symbol(status_item: *anyopaque, symbol_name: []const u8) void {
    const pool = objc.autorelease_pool_push();
    defer objc.autorelease_pool_pop(pool);

    const ns_status_item: Id = @ptrCast(status_item);
    const button: ?Id = objc.msg_send(?Id, ns_status_item, "button", .{});
    if (button) |btn| {
        const NSImage = objc.get_class("NSImage") orelse return;
        const ns_symbol_name = create_ns_string(symbol_name);
        const image: ?Id = objc.msg_send(
            ?Id,
            NSImage,
            "imageWithSystemSymbolName:accessibilityDescription:",
            .{ ns_symbol_name, @as(?Id, null) },
        );
        if (image) |img| {
            objc.msg_send(void, btn, "setImage:", .{img});
        }
    }
}

// Detaches any prior menu: NSStatusItem.menu intercepts every click and
// bypasses the button's target+action.
pub fn set_button_action(
    status_item: *anyopaque,
    ctx: *anyopaque,
    callback: *const fn (*anyopaque) void,
) void {
    const allocator = allocator_ref orelse return;
    const ns_status_item: Id = @ptrCast(status_item);
    const button: ?Id = objc.msg_send(?Id, ns_status_item, "button", .{});
    const btn = button orelse return;

    objc.msg_send(void, ns_status_item, "setMenu:", .{@as(?Id, null)});

    const tag = stored_button_actions.items.len;
    stored_button_actions.append(allocator, .{ .ctx = ctx, .callback = callback }) catch return;

    ensure_status_menu_delegate_class();
    const delegate = get_shared_status_menu_delegate();

    objc.msg_send(void, btn, "setTarget:", .{delegate});
    objc.msg_send(void, btn, "setAction:", .{objc.sel("statusButtonLeftClicked:")});
    objc.msg_send(void, btn, "setTag:", .{@as(NSInteger, @intCast(tag))});
    objc.msg_send(void, btn, "sendActionOn:", .{NSEventMaskLeftMouseUp | NSEventMaskRightMouseUp});
}

// Must be called AFTER set_button_action; routes through the same delegate.
pub fn set_right_click_menu(status_item: *anyopaque, items: []const MenuItem) void {
    const allocator = allocator_ref orelse return;
    const ns_status_item: Id = @ptrCast(status_item);
    const button: ?Id = objc.msg_send(?Id, ns_status_item, "button", .{});
    const btn = button orelse return;

    const tag = objc.msg_send(NSInteger, btn, "tag", .{});
    const index: usize = @intCast(tag);
    if (index >= stored_button_actions.items.len) return;

    const ns_menu = create_status_menu(allocator, items, 0) orelse return;
    stored_button_actions.items[index].right_click_menu = ns_menu;
}

pub fn get_button_screen_rect(status_item: *anyopaque) ScreenRect {
    const ns_status_item: Id = @ptrCast(status_item);
    const button: ?Id = objc.msg_send(?Id, ns_status_item, "button", .{});
    const btn = button orelse return .{ .x = 0, .y = 0, .width = 0, .height = 0 };

    const win: ?Id = objc.msg_send(?Id, btn, "window", .{});
    const w = win orelse return .{ .x = 0, .y = 0, .width = 0, .height = 0 };

    const CGRect = extern struct {
        origin: extern struct { x: CGFloat, y: CGFloat },
        size: extern struct { width: CGFloat, height: CGFloat },
    };

    const button_frame: CGRect = objc.msg_send(CGRect, btn, "frame", .{});
    const screen_frame: CGRect = objc.msg_send(CGRect, w, "convertRectToScreen:", .{button_frame});

    return .{
        .x = screen_frame.origin.x,
        .y = screen_frame.origin.y,
        .width = screen_frame.size.width,
        .height = screen_frame.size.height,
    };
}

pub fn set_visible(status_item: *anyopaque, visible: bool) void {
    const ns_status_item: Id = @ptrCast(status_item);
    objc.msg_send(void, ns_status_item, "setVisible:", .{
        if (visible) objc.YES else objc.NO,
    });
}

pub fn remove_status_item(status_item: *anyopaque) void {
    const pool = objc.autorelease_pool_push();
    defer objc.autorelease_pool_pop(pool);

    const ns_status_item: Id = @ptrCast(status_item);

    const NSStatusBar = objc.get_class("NSStatusBar") orelse return;
    const system_status_bar = objc.msg_send(Id, NSStatusBar, "systemStatusBar", .{});
    if (@intFromPtr(system_status_bar) != 0) {
        objc.msg_send(void, system_status_bar, "removeStatusItem:", .{ns_status_item});
    }

    objc.msg_send(void, ns_status_item, "release", .{});

    const target_ptr = @intFromPtr(ns_status_item);
    for (status_items.items, 0..) |item, i| {
        if (@intFromPtr(item.ns_status_item) == target_ptr) {
            _ = status_items.swapRemove(i);
            break;
        }
    }
}

pub fn deinit() void {
    const pool = objc.autorelease_pool_push();
    defer objc.autorelease_pool_pop(pool);

    const NSStatusBar = objc.get_class("NSStatusBar") orelse return;
    const system_status_bar = objc.msg_send(Id, NSStatusBar, "systemStatusBar", .{});
    if (@intFromPtr(system_status_bar) != 0) {
        for (status_items.items) |item| {
            objc.msg_send(void, system_status_bar, "removeStatusItem:", .{item.ns_status_item});
            objc.msg_send(void, item.ns_status_item, "release", .{});
        }
    }

    if (allocator_ref) |alloc| {
        status_items.deinit(alloc);
        status_items = .empty;
        stored_actions.deinit(alloc);
        stored_actions = .empty;
        stored_button_actions.deinit(alloc);
        stored_button_actions = .empty;
    }

    allocator_ref = null;
    app_ptr = null;
}

const MENU_DEPTH_MAX: u8 = 8;

fn create_status_menu(allocator: std.mem.Allocator, items: []const MenuItem, depth: u8) ?Id {
    std.debug.assert(depth <= MENU_DEPTH_MAX);
    if (depth > MENU_DEPTH_MAX) return null; // release-safe submenu-nesting guard
    const ns_menu_class = objc.get_class("NSMenu") orelse return null;
    const menu_obj = objc.alloc(ns_menu_class);
    const ns_menu = objc.msg_send(Id, menu_obj, "init", .{});

    add_menu_items(allocator, ns_menu, items, depth);

    return ns_menu;
}

fn add_menu_items(
    allocator: std.mem.Allocator,
    menu_obj: Id,
    items: []const MenuItem,
    depth: u8,
) void {
    for (items) |item| {
        switch (item) {
            .separator => {
                const sep_class = objc.get_class("NSMenuItem") orelse continue;
                const sep = objc.msg_send(Id, sep_class, "separatorItem", .{});
                objc.msg_send(void, menu_obj, "addItem:", .{sep});
            },
            .submenu => |sub| {
                const submenu = create_status_menu(allocator, sub.items, depth + 1) orelse continue;
                const menu_item = create_ns_menu_item(sub.name, null, .{});
                objc.msg_send(void, menu_item, "setSubmenu:", .{submenu});
                objc.msg_send(void, menu_obj, "addItem:", .{menu_item});
            },
            .action => |act| {
                const menu_item = create_action_item(allocator, act);
                objc.msg_send(void, menu_obj, "addItem:", .{menu_item});
            },
        }
    }
}

fn create_ns_menu_item(title: []const u8, key: ?u21, modifiers: Modifiers) Id {
    const ns_menu_item_class = objc.get_class("NSMenuItem") orelse unreachable;
    const item = objc.alloc(ns_menu_item_class);

    const ns_title = create_ns_string(title);
    const ns_key = if (key) |k| create_ns_string_from_char(k) else create_ns_string("");

    const initialized = objc.msg_send(Id, item, "initWithTitle:action:keyEquivalent:", .{
        ns_title,
        @as(?Sel, null),
        ns_key,
    });

    if (key != null) {
        const mask = modifiers_to_ns(modifiers);
        objc.msg_send(void, initialized, "setKeyEquivalentModifierMask:", .{mask});
    }

    return initialized;
}

fn create_action_item(allocator: std.mem.Allocator, act: MenuItem.ActionItem) Id {
    const item = create_ns_menu_item(act.name, act.key, act.modifiers);

    const tag = stored_actions.items.len;
    stored_actions.append(allocator, .{ .menu_action = act.menu_action }) catch return item;

    ensure_status_menu_delegate_class();
    const delegate = get_shared_status_menu_delegate();

    objc.msg_send(void, item, "setAction:", .{objc.sel("statusMenuItemClicked:")});
    objc.msg_send(void, item, "setTarget:", .{delegate});
    objc.msg_send(void, item, "setTag:", .{@as(NSInteger, @intCast(tag))});

    return item;
}

fn ensure_status_menu_delegate_class() void {
    if (status_menu_delegate_class != null) return;

    const ns_object = objc.get_class("NSObject") orelse return;
    const new_class = objc.objc_allocateClassPair(
        ns_object,
        "ZigUIStatusMenuDelegate",
        0,
    ) orelse return;

    const menu_impl: *const fn (Id, Sel, Id) callconv(.c) void = &status_menu_item_clicked_imp;
    _ = objc.class_addMethod(
        new_class,
        objc.sel("statusMenuItemClicked:"),
        @ptrCast(menu_impl),
        "v@:@",
    );

    const button_impl: *const fn (Id, Sel, Id) callconv(.c) void = &status_button_left_clicked_imp;
    _ = objc.class_addMethod(
        new_class,
        objc.sel("statusButtonLeftClicked:"),
        @ptrCast(button_impl),
        "v@:@",
    );

    objc.objc_registerClassPair(new_class);
    status_menu_delegate_class = new_class;
}

fn get_shared_status_menu_delegate() Id {
    if (shared_status_menu_delegate) |d| return d;

    const cls = status_menu_delegate_class orelse unreachable;
    const obj = objc.alloc(cls);
    shared_status_menu_delegate = objc.msg_send(Id, obj, "init", .{});
    return shared_status_menu_delegate.?;
}

fn status_menu_item_clicked_imp(_: Id, _: Sel, sender: Id) callconv(.c) void {
    const tag = objc.msg_send(NSInteger, sender, "tag", .{});
    const index: usize = @intCast(tag);

    if (index < stored_actions.items.len) {
        const stored = stored_actions.items[index];
        if (app_ptr) |app| {
            stored.menu_action.dispatch_fn(stored.menu_action.action_ptr, app);
        }
    }
}

fn status_button_left_clicked_imp(_: Id, _: Sel, sender: Id) callconv(.c) void {
    const tag = objc.msg_send(NSInteger, sender, "tag", .{});
    const index: usize = @intCast(tag);
    if (index >= stored_button_actions.items.len) return;
    const stored = stored_button_actions.items[index];

    const NSApplication = objc.get_class("NSApplication") orelse {
        stored.callback(stored.ctx);
        return;
    };
    const app = objc.msg_send(Id, NSApplication, "sharedApplication", .{});
    const current_event: ?Id = objc.msg_send(?Id, app, "currentEvent", .{});

    if (current_event) |ev| {
        const ev_type = objc.msg_send(NSUInteger, ev, "type", .{});
        if (ev_type == NSEventTypeRightMouseDown or ev_type == NSEventTypeRightMouseUp) {
            if (stored.right_click_menu) |menu_obj| {
                const NSZeroPoint = extern struct {
                    x: CGFloat = 0,
                    y: CGFloat = 0,
                };
                objc.msg_send(void, menu_obj, "popUpMenuPositioningItem:atLocation:inView:", .{
                    @as(?Id, null),
                    NSZeroPoint{},
                    sender,
                });
            }
            return;
        }
    }

    stored.callback(stored.ctx);
}

fn modifiers_to_ns(mods: Modifiers) NSUInteger {
    var flags: NSUInteger = 0;
    if (mods.cmd) flags |= NSEventModifierFlagCommand;
    if (mods.shift) flags |= NSEventModifierFlagShift;
    if (mods.alt) flags |= NSEventModifierFlagOption;
    if (mods.ctrl) flags |= NSEventModifierFlagControl;
    return flags;
}

fn create_ns_string(str: []const u8) Id {
    const ns_string_class = objc.get_class("NSString") orelse unreachable;
    var buf: [512]u8 = undefined;
    std.debug.assert(str.len < buf.len); // status item text never approaches 512 bytes
    const len = @min(str.len, buf.len - 1);
    @memcpy(buf[0..len], str[0..len]);
    buf[len] = 0;
    return objc.msg_send(Id, ns_string_class, "stringWithUTF8String:", .{&buf});
}

fn create_ns_string_from_char(char: u21) Id {
    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(char, &buf) catch return create_ns_string("");
    buf[len] = 0;
    return create_ns_string(buf[0..len]);
}
