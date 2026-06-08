const builtin = @import("builtin");
const menu = @import("menu.zig");

pub const MenuItem = menu.MenuItem;
pub const Modifiers = menu.Modifiers;

pub const StatusItemConfig = struct {
    title: ?[]const u8 = null,
    symbol_name: ?[]const u8 = null,
    menu_items: []const MenuItem = &.{},
    tooltip: ?[]const u8 = null,
    visible: bool = true,
};

const impl = switch (builtin.os.tag) {
    .macos => @import("platform/macos/status_bar.zig"),
    else => @compileError("zigui: unsupported OS for status_bar"),
};

pub const ScreenRect = impl.ScreenRect;

pub const init = impl.init;
pub const create_status_item = impl.create_status_item;
pub const set_title = impl.set_title;
pub const set_symbol = impl.set_symbol;
pub const Segment = impl.Segment;
pub const SegmentKind = impl.SegmentKind;
pub const set_attributed_title = impl.set_attributed_title;
pub const set_visible = impl.set_visible;
pub const set_button_action = impl.set_button_action;
pub const set_right_click_menu = impl.set_right_click_menu;
pub const get_button_screen_rect = impl.get_button_screen_rect;
pub const remove_status_item = impl.remove_status_item;
pub const deinit = impl.deinit;
