// Keysym-to-KeyEvent translation shared by the Wayland and X11 arms. Both
// feed xkbcommon the same way (keycode = evdev + 8, which IS the X11 core
// keycode), so the navigation table and the ctrl-folding rule live once.

const std = @import("std");
const xkb = @import("xkbcommon.zig");
const shell_types = @import("shell_types.zig");

const KeyMods = shell_types.KeyMods;
const KeyCode = shell_types.KeyCode;
const KeyEvent = shell_types.KeyEvent;

pub fn key_event_for(sym: u32, keycode: u32, state: *xkb.State, mods: KeyMods) ?KeyEvent {
    std.debug.assert(keycode >= 8);
    const code: ?KeyCode = switch (sym) {
        0xff51 => .left,
        0xff53 => .right,
        0xff52 => .up,
        0xff54 => .down,
        0xff08 => .backspace,
        0xffff => .delete_fwd,
        0xff0d, 0xff8d => .enter,
        0xff09 => .tab,
        0xff1b => .escape,
        0xff50 => .home,
        0xff57 => .end,
        0xff55 => .page_up,
        0xff56 => .page_down,
        else => null,
    };
    if (code) |c| return .{ .code = c, .mods = mods };
    const ch = xkb.key_utf32(state, keycode);
    if (ch < 0x20 or ch == 0x7f) {
        // Ctrl folds letters into control codes (ctrl+a -> 0x01), but the
        // shortcut consumers key on the letter; the keysym still carries it.
        if (mods.cmd and sym >= 0x20 and sym < 0x7f)
            return .{ .code = .char, .ch = @intCast(sym), .mods = mods };
        return null;
    }
    std.debug.assert(ch <= 0x10FFFF);
    return .{ .code = .char, .ch = @intCast(ch), .mods = mods };
}
