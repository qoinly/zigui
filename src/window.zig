const builtin = @import("builtin");

const impl = switch (builtin.os.tag) {
    .macos => @import("platform/macos/window.zig"),
    .windows => @import("platform/windows/window.zig"),
    .linux => @import("platform/linux/window.zig"),
    else => @compileError("zigui: unsupported OS for window"),
};

// os.tag facade; separate file avoids the window.zig <-> window/paint.zig cycle.
const custom_impl = @import("custom_shell.zig");

const types = @import("window/types.zig");
pub const NativeShellOptions = types.NativeShellOptions;
pub const ShellOptions = types.ShellOptions;
pub const ChromeKind = types.ChromeKind;
pub const Feel = types.Feel;
pub const Theme = types.Theme;
pub const Variant = types.Variant;
pub const Size = types.Size;
pub const ToolbarSeparator = types.ToolbarSeparator;
pub const SidebarKind = types.SidebarKind;
pub const SidebarEntry = types.SidebarEntry;
pub const SidebarSelectFn = types.SidebarSelectFn;
pub const SidebarReorderFn = types.SidebarReorderFn;
pub const ToolbarItemKind = types.ToolbarItemKind;
pub const ToolbarEntry = types.ToolbarEntry;
pub const ToolbarSubItem = types.ToolbarSubItem;
pub const ToolbarMenuItem = types.ToolbarMenuItem;
pub const ToolbarSelectFn = types.ToolbarSelectFn;
pub const ToolbarSearchFn = types.ToolbarSearchFn;
pub const ScrollEvent = types.ScrollEvent;
pub const ScrollFn = types.ScrollFn;
pub const AlertStyle = types.AlertStyle;
pub const AlertOptions = types.AlertOptions;
pub const AlertFn = types.AlertFn;
pub const FilePickerOptions = types.FilePickerOptions;
pub const FilePickerFn = types.FilePickerFn;
pub const run_alert = impl.run_alert;
pub const native_image_named = impl.native_image_named;
pub const open_file = impl.open_file;
pub const save_file = impl.save_file;

pub const Handle = impl.Handle;
pub const SimpleOptions = impl.SimpleOptions;
pub const MetalHandle = impl.MetalHandle;
pub const MetalOptions = impl.MetalOptions;
pub const PanelHandle = impl.PanelHandle;
pub const PanelOptions = impl.PanelOptions;
pub const PanelMaterial = impl.PanelMaterial;
pub const NativeShellHandle = impl.NativeShellHandle;
pub const Error = impl.Error;
pub const open_simple = impl.open_simple;
pub const open_metal = impl.open_metal;
pub const open_panel = impl.open_panel;
pub const open_native_shell = impl.open_native_shell;

pub const CustomShellHandle = custom_impl.CustomShellHandle;
pub const open_custom_shell = custom_impl.open;
pub const show_text_field = custom_impl.show_text_field;
pub const hide_text_field = custom_impl.hide_text_field;
pub const text_field_value = custom_impl.text_field_value;
pub const pasteboard_read_into = custom_impl.pasteboard_read_into;
pub const pasteboard_write_string = custom_impl.pasteboard_write_string;
pub const KeyEvent = custom_impl.KeyEvent;
pub const KeyCode = custom_impl.KeyCode;
pub const KeyMods = custom_impl.KeyMods;

const custom_paint = @import("window/paint.zig");
pub const PaintContext = custom_paint.PaintContext;
pub const Frame = custom_paint.Frame;
pub const PaintCallback = custom_paint.PaintCallback;
pub const start_paint_loop = custom_paint.start_paint_loop;
pub const set_sidebar_items = impl.set_sidebar_items;
pub const set_sidebar_on_select = impl.set_sidebar_on_select;
pub const set_sidebar_on_reorder = impl.set_sidebar_on_reorder;
pub const set_sidebar_selection = impl.set_sidebar_selection;
pub const set_native_shell_title = impl.set_native_shell_title;
pub const set_native_shell_on_scroll = impl.set_native_shell_on_scroll;
pub const BodyMouseEvent = impl.BodyMouseEvent;
pub const BodyMouseFn = impl.BodyMouseFn;
pub const BodyExitFn = impl.BodyExitFn;
pub const set_native_shell_on_body_move = impl.set_native_shell_on_body_move;
pub const set_native_shell_on_body_click = impl.set_native_shell_on_body_click;
pub const set_native_shell_on_body_exit = impl.set_native_shell_on_body_exit;
pub const set_toolbar_items = impl.set_toolbar_items;
pub const set_toolbar_on_select = impl.set_toolbar_on_select;
pub const set_toolbar_on_search = impl.set_toolbar_on_search;
