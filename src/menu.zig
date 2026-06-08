const std = @import("std");
const builtin = @import("builtin");

pub const OsAction = enum { cut, copy, paste, select_all, undo, redo };

pub const MenuAction = struct {
    action_ptr: *const anyopaque,
    dispatch_fn: *const fn (action_ptr: *const anyopaque, ctx: *anyopaque) void,
};

pub const Modifiers = struct {
    cmd: bool = false,
    shift: bool = false,
    alt: bool = false,
    ctrl: bool = false,
};

pub const MenuItem = union(enum) {
    separator,
    submenu: struct {
        name: []const u8,
        items: []const MenuItem,
    },
    action: ActionItem,

    pub const ActionItem = struct {
        name: []const u8,
        menu_action: MenuAction,
        os_action: ?OsAction = null,
        key: ?u21 = null,
        modifiers: Modifiers = .{},
    };

    pub fn sep() MenuItem {
        return .separator;
    }

    pub fn sub(name: []const u8, items: []const MenuItem) MenuItem {
        return .{ .submenu = .{ .name = name, .items = items } };
    }
};

pub const Menu = struct {
    name: []const u8,
    items: []const MenuItem,
};

const impl = switch (builtin.os.tag) {
    .macos => @import("platform/macos/menu.zig"),
    else => @compileError("zigui: unsupported OS for menu"),
};

pub const set_app_ptr = impl.set_app_ptr;
pub const set_app_menus = impl.set_app_menus;
pub const deinit = impl.deinit;
