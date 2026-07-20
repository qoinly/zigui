const color = @import("../color.zig");
const icon_set = @import("../icon.zig");

pub const Rgba = color.Rgba;

// A colored byte-range over a text field's value, for native-painted single-line
// editors that colorize their text themselves (see custom_shell.color_text_field).
// Offsets are UTF-8 byte offsets into the value (converted per platform). A flat
// struct here (not kit.textarea.TextSpan) keeps the platform layer free of a kit
// import, which would cycle through custom_shell.
pub const FieldSpan = struct { start: u32, end: u32, color: Rgba };

pub const ChromeKind = enum { native, custom };

pub const Feel = enum { flat, liquid_glass, transparent };

pub const Variant = enum { default, secondary, destructive, outline, ghost, link };

pub const Size = enum { sm, default, lg, icon, icon_sm };

pub const Theme = struct {
    background: Rgba,
    foreground: Rgba,
    card: Rgba,
    card_foreground: Rgba,
    popover: Rgba,
    popover_foreground: Rgba,
    primary: Rgba,
    primary_foreground: Rgba,
    secondary: Rgba,
    secondary_foreground: Rgba,
    muted: Rgba,
    muted_foreground: Rgba,
    accent: Rgba,
    accent_foreground: Rgba,
    destructive: Rgba,
    destructive_foreground: Rgba,
    success: Rgba,
    success_foreground: Rgba,
    border: Rgba,
    input: Rgba,
    ring: Rgba,
    radius: f32 = 8,
    font_family: []const u8 = "",
    font_size: f32 = 14,

    pub fn default_dark() Theme {
        return .{
            .background = hex(0x0A0A0AFF),
            .foreground = hex(0xFAFAFAFF),
            .card = hex(0x0A0A0AFF),
            .card_foreground = hex(0xFAFAFAFF),
            .popover = hex(0x0A0A0AFF),
            .popover_foreground = hex(0xFAFAFAFF),
            .primary = hex(0xFAFAFAFF),
            .primary_foreground = hex(0x18181BFF),
            .secondary = hex(0x27272AFF),
            .secondary_foreground = hex(0xFAFAFAFF),
            .muted = hex(0x27272AFF),
            .muted_foreground = hex(0xA1A1AAFF),
            .accent = hex(0x27272AFF),
            .accent_foreground = hex(0xFAFAFAFF),
            .destructive = hex(0x7F1D1DFF),
            .destructive_foreground = hex(0xFAFAFAFF),
            .success = hex(0x22C55EFF),
            .success_foreground = hex(0x052E16FF),
            .border = hex(0x27272AFF),
            .input = hex(0x27272AFF),
            .ring = hex(0xD4D4D8FF),
        };
    }

    pub fn default_light() Theme {
        return .{
            .background = hex(0xFFFFFFFF),
            .foreground = hex(0x0A0A0AFF),
            .card = hex(0xFFFFFFFF),
            .card_foreground = hex(0x0A0A0AFF),
            .popover = hex(0xFFFFFFFF),
            .popover_foreground = hex(0x0A0A0AFF),
            .primary = hex(0x18181BFF),
            .primary_foreground = hex(0xFAFAFAFF),
            .secondary = hex(0xF4F4F5FF),
            .secondary_foreground = hex(0x18181BFF),
            .muted = hex(0xF4F4F5FF),
            .muted_foreground = hex(0x71717AFF),
            .accent = hex(0xF4F4F5FF),
            .accent_foreground = hex(0x18181BFF),
            .destructive = hex(0xEF4444FF),
            .destructive_foreground = hex(0xFAFAFAFF),
            .success = hex(0x16A34AFF),
            .success_foreground = hex(0xFAFAFAFF),
            .border = hex(0xE4E4E7FF),
            .input = hex(0xE4E4E7FF),
            .ring = hex(0x18181BFF),
        };
    }
};

fn hex(h: u32) Rgba {
    return .{
        .r = @as(f32, @floatFromInt((h >> 24) & 0xFF)) / 255.0,
        .g = @as(f32, @floatFromInt((h >> 16) & 0xFF)) / 255.0,
        .b = @as(f32, @floatFromInt((h >> 8) & 0xFF)) / 255.0,
        .a = @as(f32, @floatFromInt(h & 0xFF)) / 255.0,
    };
}

pub const ToolbarSeparator = enum(i64) {
    automatic = 0,
    none = 1,
    line = 2,
    shadow = 3,
};

// Library paints this band every frame by default (no consumer code): bg +
// separator, traffic lights recentered on it, body inset below. enabled=false
// removes all three for backward-compat.
pub const TitlebarOptions = struct {
    enabled: bool = true,
    height: f64 = 37,
    separator: bool = true,
    title: []const u8 = "", // optional text drawn past the traffic-light cluster
    content_left: f64 = 16, // body content-left pad; the close button aligns here
};

pub const NativeShellOptions = struct {
    title: []const u8,
    width: f64 = 1100,
    height: f64 = 720,
    min_width: f64 = 720,
    min_height: f64 = 480,
    sidebar_width: f64 = 260,
    sidebar_min_width: f64 = 220,
    sidebar_max_width: f64 = 320,
    resizable: bool = true,
    toolbar_separator: ToolbarSeparator = .none,
    sidebar_search: bool = false, // search field filters items by label substring
    chrome: ChromeKind = .native,
    feel: Feel = .flat,
    theme: ?Theme = null, // honored only when chrome = .custom
    titlebar: TitlebarOptions = .{},
    // 0 = derive from titlebar (y = height/2, x = content_left); non-zero overrides.
    traffic_light_y: f64 = 0,
    traffic_light_x: f64 = 0,
};

pub const ShellOptions = NativeShellOptions;

pub const SidebarKind = enum { group, item };

pub const SidebarEntry = struct {
    kind: SidebarKind,
    id: []const u8 = "",
    label: []const u8,
    icon: ?icon_set.Icon = null,
    // caller-owned native image (NSImage* on macOS); overrides icon when set
    icon_image: ?*anyopaque = null,
    color: ?Rgba = null, // non-null = colored backplate behind white icon
    badge: []const u8 = "", // count pill at right edge of row
    action_icon: ?icon_set.Icon = null, // hover-revealed secondary action at row's right edge
    // Children collapse when expanded = false. A parent (children.len > 0) shows
    // a chevron and toggles instead of selecting.
    children: []const SidebarEntry = &.{},
    // .group only: when true the group label toggles its items; false = static heading.
    collapsible: bool = false,
    expanded: bool = true, // initial state when collapsible / has children
};

pub const SidebarSelectFn = *const fn (ctx: *anyopaque, id: []const u8) void;
pub const SidebarReorderFn = *const fn (ctx: *anyopaque, from_idx: usize, to_idx: usize) void;

pub const ToolbarItemKind = enum {
    sidebar_toggle,
    tracking_separator,
    flexible_space,
    button,
    segmented_group,
    search_field,
    menu,
    custom_view,
};

pub const ToolbarSubItem = struct {
    id: []const u8,
    label: []const u8 = "",
    icon: ?icon_set.Icon = null,
    tooltip: []const u8 = "",
};

pub const ToolbarMenuItem = struct {
    id: []const u8,
    label: []const u8,
    icon: ?icon_set.Icon = null,
};

pub const ToolbarEntry = struct {
    kind: ToolbarItemKind,
    id: []const u8 = "",
    label: []const u8 = "",
    icon: ?icon_set.Icon = null,
    tooltip: []const u8 = "",
    sub_items: []const ToolbarSubItem = &.{},
    menu_items: []const ToolbarMenuItem = &.{},
    custom_view: ?*anyopaque = null, // caller-owned native view, .custom_view kind only
    min_width: f32 = 0,
    max_width: f32 = 0,
    enabled: bool = true,
};

pub const ToolbarSelectFn = *const fn (ctx: *anyopaque, id: []const u8) void;
pub const ToolbarSearchFn = *const fn (ctx: *anyopaque, id: []const u8, text: []const u8) void;

pub const ScrollEvent = struct {
    delta_x: f32,
    delta_y: f32,
};

pub const ScrollFn = *const fn (ctx: *anyopaque, event: ScrollEvent) void;

pub const BodyMouseEvent = struct {
    x: f32,
    y: f32,
};

pub const BodyMouseFn = *const fn (ctx: *anyopaque, event: BodyMouseEvent) void;
pub const BodyExitFn = *const fn (ctx: *anyopaque) void;

pub const HitBox = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    on_click: ?*const fn (ctx: ?*anyopaque) void = null,
    // Receives the click point; takes priority over on_click.
    on_point: ?*const fn (ctx: ?*anyopaque, x: f32, y: f32) void = null,
    // Fires once on release if this hitbox captured the drag (had on_point), so a
    // draggable item can finalize a drop / distinguish click.
    on_drag_end: ?*const fn (ctx: ?*anyopaque) void = null,
    on_context: ?*const fn (ctx: ?*anyopaque, x: f32, y: f32) void = null,
    // Middle-button press (e.g. middle-click a tab to close it).
    on_middle: ?*const fn (ctx: ?*anyopaque) void = null,
    // A stable id recorded as hovered while the pointer is over this box (a view
    // reads the topmost via the frame to reveal-on-hover, no callback / stale ctx).
    hover_id: []const u8 = "",
    ctx: ?*anyopaque = null,
};

pub const AlertStyle = enum(i64) {
    warning = 0,
    informational = 1,
    critical = 2,
};

pub const AlertOptions = struct {
    title: []const u8,
    message: []const u8 = "",
    buttons: []const []const u8 = &.{"OK"}, // first = default; up to ~3
    style: AlertStyle = .informational,
};

// clicked = index of the button (0 = first / default).
pub const AlertFn = *const fn (ctx: *anyopaque, clicked: usize) void;

pub const FilePickerOptions = struct {
    title: []const u8 = "",
    message: []const u8 = "",
    button_label: []const u8 = "", // "Choose" / "Save" / etc. Empty = system default.
    default_filename: []const u8 = "", // save panel suggests this filename
    allowed_extensions: []const []const u8 = &.{}, // e.g. &.{"png","jpg"}. Empty = any.
    allow_directories: bool = false,
    allow_files: bool = true,
    allow_multiple: bool = false,
};

// path = single absolute path; multi-select fires once per path. Cancel = "".
pub const FilePickerFn = *const fn (ctx: *anyopaque, path: []const u8) void;
