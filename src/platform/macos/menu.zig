const std = @import("std");
const objc = @import("objc.zig");
const types = @import("../../menu.zig");

const Id = objc.Id;
const Sel = objc.Sel;
const Class = objc.Class;
const NSUInteger = objc.NSUInteger;

pub const Menu = types.Menu;
pub const MenuItem = types.MenuItem;
pub const MenuAction = types.MenuAction;
pub const Modifiers = types.Modifiers;
pub const OsAction = types.OsAction;

const NSEventModifierFlagCommand: NSUInteger = 1 << 20;
const NSEventModifierFlagShift: NSUInteger = 1 << 17;
const NSEventModifierFlagOption: NSUInteger = 1 << 19;
const NSEventModifierFlagControl: NSUInteger = 1 << 18;

const MENU_DEPTH_MAX: u8 = 8;

var stored_actions: std.ArrayListUnmanaged(StoredAction) = .empty;
var allocator_ref: ?std.mem.Allocator = null;
var app_ptr: ?*anyopaque = null;

const StoredAction = struct {
    menu_action: MenuAction,
};

pub fn set_app_ptr(ptr: *anyopaque) void {
    app_ptr = ptr;
}

pub fn set_app_menus(allocator: std.mem.Allocator, menus: []const Menu, app: *anyopaque) void {
    allocator_ref = allocator;
    app_ptr = app;
    stored_actions.clearRetainingCapacity();

    const pool = objc.autorelease_pool_push();
    defer objc.autorelease_pool_pop(pool);

    const ns_app = objc.get_class("NSApplication") orelse return;
    const ns_app_instance = objc.msg_send(Id, ns_app, "sharedApplication", .{});

    const menu_bar = create_ns_menu("");

    for (menus) |m| {
        const submenu = create_ns_menu(m.name);
        add_menu_items(allocator, submenu, m.items, 0);

        const menu_item = create_ns_menu_item(m.name, null, .{});
        objc.msg_send(void, menu_item, "setSubmenu:", .{submenu});
        objc.msg_send(void, menu_bar, "addItem:", .{menu_item});
    }

    objc.msg_send(void, ns_app_instance, "setMainMenu:", .{menu_bar});
}

fn create_ns_menu(title: []const u8) Id {
    const ns_menu_class = objc.get_class("NSMenu") orelse unreachable;
    const menu_obj = objc.alloc(ns_menu_class);
    const ns_string = create_ns_string(title);
    return objc.msg_send(Id, menu_obj, "initWithTitle:", .{ns_string});
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

fn modifiers_to_ns(mods: Modifiers) NSUInteger {
    var flags: NSUInteger = 0;
    if (mods.cmd) flags |= NSEventModifierFlagCommand;
    if (mods.shift) flags |= NSEventModifierFlagShift;
    if (mods.alt) flags |= NSEventModifierFlagOption;
    if (mods.ctrl) flags |= NSEventModifierFlagControl;
    return flags;
}

fn add_menu_items(
    allocator: std.mem.Allocator,
    menu_obj: Id,
    items: []const MenuItem,
    depth: u8,
) void {
    std.debug.assert(depth <= MENU_DEPTH_MAX);
    if (depth > MENU_DEPTH_MAX) return; // release-safe submenu-nesting guard
    for (items) |item| {
        switch (item) {
            .separator => {
                const sep_class = objc.get_class("NSMenuItem") orelse continue;
                const sep = objc.msg_send(Id, sep_class, "separatorItem", .{});
                objc.msg_send(void, menu_obj, "addItem:", .{sep});
            },
            .submenu => |sub| {
                const submenu = create_ns_menu(sub.name);
                add_menu_items(allocator, submenu, sub.items, depth + 1);

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

fn create_action_item(allocator: std.mem.Allocator, act: MenuItem.ActionItem) Id {
    const item = create_ns_menu_item(act.name, act.key, act.modifiers);

    const tag = stored_actions.items.len;
    stored_actions.append(allocator, .{ .menu_action = act.menu_action }) catch return item;

    if (act.os_action) |os_act| {
        const selector = get_os_action_selector(os_act);
        objc.msg_send(void, item, "setAction:", .{objc.sel(selector)});
    } else {
        ensure_menu_delegate_class();
        const delegate = get_shared_menu_delegate();

        objc.msg_send(void, item, "setAction:", .{objc.sel("menuItemClicked:")});
        objc.msg_send(void, item, "setTarget:", .{delegate});
    }

    objc.msg_send(void, item, "setTag:", .{@as(objc.NSInteger, @intCast(tag))});

    return item;
}

fn get_os_action_selector(os_action: OsAction) [:0]const u8 {
    return switch (os_action) {
        .cut => "cut:",
        .copy => "copy:",
        .paste => "paste:",
        .select_all => "selectAll:",
        .undo => "undo:",
        .redo => "redo:",
    };
}

var menu_delegate_class: ?Class = null;
var shared_menu_delegate: ?Id = null;

fn ensure_menu_delegate_class() void {
    if (menu_delegate_class != null) return;

    const ns_object = objc.get_class("NSObject") orelse return;
    const new_class = objc.objc_allocateClassPair(ns_object, "ZigUIMenuDelegate", 0) orelse return;

    const method_impl: *const fn (Id, Sel, Id) callconv(.c) void = &menu_item_clicked_imp;
    const clicked_sel = objc.sel("menuItemClicked:");
    _ = objc.class_addMethod(new_class, clicked_sel, @ptrCast(method_impl), "v@:@");

    objc.objc_registerClassPair(new_class);
    menu_delegate_class = new_class;
}

fn get_shared_menu_delegate() Id {
    if (shared_menu_delegate) |d| return d;

    const cls = menu_delegate_class orelse unreachable;
    const obj = objc.alloc(cls);
    shared_menu_delegate = objc.msg_send(Id, obj, "init", .{});
    return shared_menu_delegate.?;
}

fn menu_item_clicked_imp(_: Id, _: Sel, sender: Id) callconv(.c) void {
    const tag = objc.msg_send(objc.NSInteger, sender, "tag", .{});
    const index: usize = @intCast(tag);

    if (index < stored_actions.items.len) {
        const stored = stored_actions.items[index];
        if (app_ptr) |app| {
            stored.menu_action.dispatch_fn(stored.menu_action.action_ptr, app);
        }
    }
}

fn create_ns_string(str: []const u8) Id {
    const ns_string_class = objc.get_class("NSString") orelse unreachable;
    // str is not NUL-terminated; copy into a stack buffer and terminate so AppKit
    // does not over-read past the slice (menu labels/shortcuts are short).
    var buf: [512]u8 = undefined;
    std.debug.assert(str.len < buf.len);
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

pub fn deinit() void {
    if (allocator_ref) |alloc| {
        stored_actions.deinit(alloc);
        stored_actions = .empty;
    }
    allocator_ref = null;
    app_ptr = null;
}
