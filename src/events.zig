const std = @import("std");

pub const Key = union(enum) {
    char: u21,

    escape,
    enter,
    tab,
    backspace,
    delete,
    space,

    up,
    down,
    left,
    right,

    home,
    end,
    page_up,
    page_down,

    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,

    shift,
    control,
    alt,
    command,

    unknown: u16,

    pub fn eql(self: Key, other: Key) bool {
        const self_tag = std.meta.activeTag(self);
        const other_tag = std.meta.activeTag(other);
        if (self_tag != other_tag) return false;
        return switch (self) {
            .char => |c| c == other.char,
            .unknown => |code| code == other.unknown,
            else => true,
        };
    }
};

pub const Keystroke = struct {
    key: Key,
    modifiers: Modifiers,
    key_char: ?u21 = null,

    pub fn has_modifiers(self: Keystroke) bool {
        return self.modifiers.shift or
            self.modifiers.control or
            self.modifiers.alt or
            self.modifiers.command;
    }

    pub fn is_printable(self: Keystroke) bool {
        return self.key_char != null and
            !self.modifiers.control and
            !self.modifiers.command;
    }
};

pub const MouseButton = enum {
    left,
    right,
    middle,
    other,
};

pub const Modifiers = struct {
    shift: bool = false,
    control: bool = false,
    alt: bool = false,
    command: bool = false,

    pub const none = Modifiers{};

    pub fn any(self: Modifiers) bool {
        return self.shift or self.control or self.alt or self.command;
    }
};

pub const KeyDownEvent = struct {
    keystroke: Keystroke,
    is_held: bool = false,
};

pub const KeyUpEvent = struct {
    keystroke: Keystroke,
};

pub const ModifiersChangedEvent = struct {
    modifiers: Modifiers,
};

pub const MouseDownEvent = struct {
    button: MouseButton,
    position: [2]f32,
    modifiers: Modifiers,
    click_count: u32,
};

pub const MouseUpEvent = struct {
    button: MouseButton,
    position: [2]f32,
    modifiers: Modifiers,
    click_count: u32,
};

pub const MouseMoveEvent = struct {
    position: [2]f32,
    pressed_button: ?MouseButton,
    modifiers: Modifiers,

    pub fn dragging(self: MouseMoveEvent) bool {
        return self.pressed_button == .left;
    }
};

pub const MouseExitEvent = struct {
    position: [2]f32,
    pressed_button: ?MouseButton,
    modifiers: Modifiers,
};

pub const ScrollWheelEvent = struct {
    position: [2]f32,
    delta_x: f32,
    delta_y: f32,
    modifiers: Modifiers,
};

pub const Event = union(enum) {
    key_down: KeyDownEvent,
    key_up: KeyUpEvent,
    modifiers_changed: ModifiersChangedEvent,

    mouse_down: MouseDownEvent,
    mouse_up: MouseUpEvent,
    mouse_move: MouseMoveEvent,
    mouse_exit: MouseExitEvent,
    scroll_wheel: ScrollWheelEvent,

    pub fn get_position(self: Event) ?[2]f32 {
        return switch (self) {
            .key_down, .key_up, .modifiers_changed => null,
            .mouse_down => |e| e.position,
            .mouse_up => |e| e.position,
            .mouse_move => |e| e.position,
            .mouse_exit => |e| e.position,
            .scroll_wheel => |e| e.position,
        };
    }

    pub fn get_modifiers(self: Event) Modifiers {
        return switch (self) {
            .key_down => |e| e.keystroke.modifiers,
            .key_up => |e| e.keystroke.modifiers,
            .modifiers_changed => |e| e.modifiers,
            .mouse_down => |e| e.modifiers,
            .mouse_up => |e| e.modifiers,
            .mouse_move => |e| e.modifiers,
            .mouse_exit => |e| e.modifiers,
            .scroll_wheel => |e| e.modifiers,
        };
    }
};

pub const EventCallback = *const fn (event: Event) void;

test "Key.eql discriminates char and unknown" {
    try std.testing.expect((Key{ .char = 'a' }).eql(.{ .char = 'a' }));
    try std.testing.expect(!(Key{ .char = 'a' }).eql(.{ .char = 'b' }));
    try std.testing.expect(!(Key{ .char = 'a' }).eql(.escape));
    try std.testing.expect((Key{ .unknown = 7 }).eql(.{ .unknown = 7 }));
}

test "Keystroke isPrintable" {
    const ks = Keystroke{ .key = .{ .char = 'a' }, .modifiers = .{}, .key_char = 'a' };
    try std.testing.expect(ks.is_printable());

    const ks_cmd = Keystroke{
        .key = .{ .char = 'a' },
        .modifiers = .{ .command = true },
        .key_char = 'a',
    };
    try std.testing.expect(!ks_cmd.is_printable());
}
