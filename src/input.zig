// Raw input captured while a frame view is grabbed, for a remote-control loop to
// forward over a wire. zigui provides the mechanism (grab, relative motion, raw
// key/button/wheel events); the app decides what to send and how. Scancodes are
// physical (layout-independent), so the remote can map them to its own layout.

pub const Button = enum(u8) {
    left,
    right,
    middle,
    other,
};

// Left/right modifier keys reported apart, the way a remote needs them. macOS keeps
// these in the device-dependent bits of the event's modifier flags.
pub const Mods = packed struct(u16) {
    left_shift: bool = false,
    right_shift: bool = false,
    left_control: bool = false,
    right_control: bool = false,
    left_option: bool = false,
    right_option: bool = false,
    left_command: bool = false,
    right_command: bool = false,
    caps_lock: bool = false,
    _pad: u7 = 0,
};

pub const InputEvent = union(enum) {
    key: Key,
    motion: Motion, // relative deltas, not a position
    button: ButtonPress,
    wheel: Wheel,

    pub const Key = struct {
        scancode: u16,
        down: bool,
        repeat: bool = false,
        mods: Mods = .{},
    };
    pub const Motion = struct { dx: f32, dy: f32 };
    pub const ButtonPress = struct { button: Button, down: bool, mods: Mods = .{} };
    pub const Wheel = struct { dx: f32, dy: f32 };
};
