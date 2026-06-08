const std = @import("std");
const objc = @import("objc.zig");

pub const Error = error{NoNSApplicationClass};

pub const ActivationPolicy = enum(i64) {
    regular = 0,
    accessory = 1,
    prohibited = 2,
};

pub const App = struct {
    handle: objc.Id,
    pool: ?*anyopaque,

    pub fn init() Error!App {
        const pool = objc.autorelease_pool_push();
        const NSApplication = objc.get_class("NSApplication") orelse {
            objc.autorelease_pool_pop(pool);
            return Error.NoNSApplicationClass;
        };
        const handle = objc.msg_send(objc.Id, NSApplication, "sharedApplication", .{});
        return .{ .handle = handle, .pool = pool };
    }

    pub fn deinit(self: *App) void {
        objc.autorelease_pool_pop(self.pool);
        self.pool = null;
    }

    pub fn set_activation_policy(self: App, policy: ActivationPolicy) void {
        objc.msg_send(void, self.handle, "setActivationPolicy:", .{@as(i64, @intFromEnum(policy))});
    }

    pub fn activate(self: App, ignore_others: bool) void {
        objc.msg_send(void, self.handle, "activateIgnoringOtherApps:", .{
            if (ignore_others) objc.YES else objc.NO,
        });
    }

    pub fn run_forever(self: App) void {
        objc.msg_send(void, self.handle, "run", .{});
    }

    pub fn quit(self: App) void {
        objc.msg_send(void, self.handle, "terminate:", .{@as(?objc.Id, null)});
    }

    // Without a delegate answering this, AppKit keeps the app alive in the Dock
    // after the close button - wrong for a single-window utility. Idempotent;
    // call before run_forever.
    pub fn quit_on_last_window_closed(self: App) void {
        std.debug.assert(@intFromPtr(self.handle) != 0);
        const NSObject = objc.get_class("NSObject") orelse return;
        const cls = g_app_delegate_class orelse blk: {
            const c = objc.objc_allocateClassPair(NSObject, "ZigUIAppDelegate", 0) orelse return;
            _ = objc.class_addMethod(
                c,
                objc.sel("applicationShouldTerminateAfterLastWindowClosed:"),
                @ptrCast(&should_terminate_after_last_window_imp),
                "B@:@",
            );
            objc.objc_registerClassPair(c);
            g_app_delegate_class = c;
            break :blk c;
        };
        const d = g_app_delegate orelse blk: {
            const obj = objc.msg_send(objc.Id, objc.alloc(cls), "init", .{});
            g_app_delegate = obj;
            break :blk obj;
        };
        objc.msg_send(void, self.handle, "setDelegate:", .{d});
    }

    // Edit items carry the standard selectors + key equivalents so Cmd+A/C/V/X/Z
    // route down the responder chain to the focused control. Without this,
    // text-editing shortcuts are dead in a custom-chrome app.
    pub fn install_edit_menu(self: App) void {
        const NSMenu = objc.get_class("NSMenu") orelse return;
        const NSMenuItem = objc.get_class("NSMenuItem") orelse return;
        const NSString = objc.get_class("NSString") orelse return;

        const main_menu = objc.msg_send(objc.Id, objc.alloc(NSMenu), "init", .{});

        const app_holder = objc.msg_send(objc.Id, objc.alloc(NSMenuItem), "init", .{});
        const app_menu = objc.msg_send(objc.Id, objc.alloc(NSMenu), "init", .{});
        menu_add(app_menu, NSMenuItem, NSString, "Quit", "terminate:", "q");
        objc.msg_send(void, app_holder, "setSubmenu:", .{app_menu});
        objc.msg_send(void, main_menu, "addItem:", .{app_holder});

        const edit_holder = objc.msg_send(objc.Id, objc.alloc(NSMenuItem), "init", .{});
        const edit_title = objc.msg_send(
            objc.Id,
            NSString,
            "stringWithUTF8String:",
            .{@as([*:0]const u8, "Edit")},
        );
        const edit_menu = objc.msg_send(
            objc.Id,
            objc.alloc(NSMenu),
            "initWithTitle:",
            .{edit_title},
        );
        menu_add(edit_menu, NSMenuItem, NSString, "Undo", "undo:", "z");
        menu_separator(edit_menu, NSMenuItem);
        menu_add(edit_menu, NSMenuItem, NSString, "Cut", "cut:", "x");
        menu_add(edit_menu, NSMenuItem, NSString, "Copy", "copy:", "c");
        menu_add(edit_menu, NSMenuItem, NSString, "Paste", "paste:", "v");
        menu_add(edit_menu, NSMenuItem, NSString, "Select All", "selectAll:", "a");
        objc.msg_send(void, edit_holder, "setSubmenu:", .{edit_menu});
        objc.msg_send(void, main_menu, "addItem:", .{edit_holder});

        objc.msg_send(void, self.handle, "setMainMenu:", .{main_menu});
    }
};

var g_app_delegate_class: ?objc.Class = null;
var g_app_delegate: ?objc.Id = null;

fn should_terminate_after_last_window_imp(_: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) bool {
    return true;
}

fn menu_add(
    menu: objc.Id,
    NSMenuItem: objc.Class,
    NSString: objc.Class,
    title: [*:0]const u8,
    action: [:0]const u8,
    key: [*:0]const u8,
) void {
    const t = objc.msg_send(objc.Id, NSString, "stringWithUTF8String:", .{title});
    const k = objc.msg_send(objc.Id, NSString, "stringWithUTF8String:", .{key});
    const item = objc.msg_send(
        objc.Id,
        objc.alloc(NSMenuItem),
        "initWithTitle:action:keyEquivalent:",
        .{ t, objc.sel(action), k },
    );
    objc.msg_send(void, menu, "addItem:", .{item});
}

fn menu_separator(menu: objc.Id, NSMenuItem: objc.Class) void {
    const sep = objc.msg_send(objc.Id, NSMenuItem, "separatorItem", .{});
    objc.msg_send(void, menu, "addItem:", .{sep});
}
