// The shell vocabulary shared by the Wayland and X11 backends and the
// dispatcher that fronts them: callback structs must be ONE type across all
// three or every registration would need a per-call conversion.

const input = @import("../../input.zig");

pub const KeyMods = packed struct {
    cmd: bool = false,
    shift: bool = false,
    alt: bool = false,
    ctrl: bool = false,
};

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
    ch: u21 = 0,
    mods: KeyMods = .{},
};

pub const MouseDispatch = struct {
    on_move: *const fn (ctx: *anyopaque, x: f32, y: f32) void,
    on_exit: *const fn (ctx: *anyopaque) void,
    on_down: *const fn (ctx: *anyopaque, x: f32, y: f32) void,
    on_right_down: *const fn (ctx: *anyopaque, x: f32, y: f32) void,
    on_middle_down: *const fn (ctx: *anyopaque, x: f32, y: f32) void,
    on_file_drop: *const fn (ctx: *anyopaque, data: [*]const u8, len: usize, x: f32, y: f32) void,
    on_drag: *const fn (ctx: *anyopaque, x: f32, y: f32) void,
    on_up: *const fn (ctx: *anyopaque) void,
    on_scroll: *const fn (ctx: *anyopaque, dx: f32, dy: f32) void,
    on_key: *const fn (ctx: *anyopaque, ev: KeyEvent) void,
    ctx: *anyopaque,
};

pub const RawDispatch = struct {
    on_event: *const fn (ctx: *anyopaque, ev: input.InputEvent) void,
    ctx: *anyopaque,
};

pub const CursorKind = enum { default, col_resize, row_resize };

pub const CaptionButton = enum { none, minimize, maximize, close };

pub const CaptionSlots = struct { kinds: [3]CaptionButton, count: u8 };

pub const HitTestFn = *const fn (ctx: *anyopaque, x: f32, y: f32, band_h: f32) bool;
pub const RedrawFn = *const fn (ctx: *anyopaque) void;
pub const WindowCloseFn = *const fn (ctx: *anyopaque, ns_window: ?*anyopaque) void;

// Linux window controls follow the desktop convention, not the full-band
// Win11 strips; the slot width matches the Mint-Y/Adwaita button_width so
// targets feel native. The cluster's extra right margin is the contract the
// paint layer derives its button centres from (margin = CLUSTER_W - 3*BTN_W).
pub const CAPTION_BTN_W: f32 = 32;
pub const CAPTION_CLUSTER_W: f32 = CAPTION_BTN_W * 3 + 6;

// One wheel detent scrolls the windows-parity 40pt on both arms (Wayland
// discrete axis steps, X11 buttons 4-7).
pub const WHEEL_NOTCH_PT: f32 = 40;

pub const Error = error{
    ConnectFailed,
    WindowCreateFailed,
    ShmFailed,
};

pub const ContentSize = extern struct { width: f64, height: f64 };
