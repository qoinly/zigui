// The singleton text-field editing engine shared by the Wayland and X11
// arms: neither has a native text widget to overlay, so the platform owns
// the editing STATE (buffer, caret, selection, key handling - the windows
// EDIT child's job) and the kit draws it (gated on text_field_native_paint).
// The owning window is erased to *anyopaque so the engine stays arm-neutral.

const std = @import("std");
const shell_types = @import("shell_types.zig");

const KeyEvent = shell_types.KeyEvent;

pub const FIELD_BUF_MAX: usize = 256; // matches the kit TextField buffer

// The arms' clipboard entry points, kept as a vtable so the engine never
// imports either arm.
pub const Clipboard = struct {
    read_into: *const fn (buf: []u8) []const u8,
    write_string: *const fn (text: []const u8) void,
};

var g_visible: bool = false;
var g_win: ?*anyopaque = null;
var g_id: u32 = 0;
var g_secure: bool = false;
var g_numeric: bool = false;
var g_buf: [FIELD_BUF_MAX]u8 = undefined;
var g_len: usize = 0;
var g_caret: usize = 0; // byte offset, always a codepoint boundary
var g_anchor: usize = 0; // selection anchor; == caret means no selection
var g_special: ?shell_types.FieldKey = null; // Enter/Shift+Enter/Escape seen this frame

// Enter/Shift+Enter/Escape the focused field saw but does not act on; the app polls it once.
pub fn take_special() ?shell_types.FieldKey {
    defer g_special = null;
    return g_special;
}

pub fn show(win: *anyopaque, initial: []const u8, is_secure: bool, numeric: bool, id: u32) void {
    std.debug.assert(id != 0);
    const reseed = !g_visible or g_id != id or g_win != win or g_secure != is_secure;
    if (reseed) {
        g_len = @min(initial.len, FIELD_BUF_MAX);
        @memcpy(g_buf[0..g_len], initial[0..g_len]);
        // Select-all on seed, the windows EM_SETSEL behavior: typing replaces.
        g_anchor = 0;
        g_caret = g_len;
    }
    g_visible = true;
    g_win = win;
    g_id = id;
    g_secure = is_secure;
    g_numeric = numeric;
    std.debug.assert(g_len <= FIELD_BUF_MAX);
    std.debug.assert(g_caret <= g_len);
}

pub fn hide(win: *anyopaque) void {
    if (g_win != win) return;
    g_visible = false;
    g_win = null;
    g_id = 0;
}

// Called when a window slab slot is recycled; a stale owner pointer would
// route the next window's keys into a dead editor.
pub fn forget_window(win: *anyopaque) void {
    hide(win);
}

pub fn consumes_key(keyboard_focus: ?*anyopaque) bool {
    return g_visible and g_win != null and g_win == keyboard_focus;
}

pub fn value(buf: []u8) []const u8 {
    std.debug.assert(g_len <= FIELD_BUF_MAX);
    const n = @min(g_len, buf.len);
    @memcpy(buf[0..n], g_buf[0..n]);
    return buf[0..n];
}

// Caret and selection in byte offsets into the polled value, for the kit's
// overlay drawing. Selection is half-open [a, b); a == b means none.
pub fn caret() usize {
    std.debug.assert(g_caret <= g_len);
    return g_caret;
}

pub fn selection() [2]usize {
    const a = @min(g_anchor, g_caret);
    const b = @max(g_anchor, g_caret);
    std.debug.assert(b <= g_len);
    return .{ a, b };
}

pub fn secure() bool {
    return g_secure;
}

fn sel_range() ?[2]usize {
    if (g_anchor == g_caret) return null;
    return selection();
}

fn prev_boundary(at: usize) usize {
    std.debug.assert(at <= g_len);
    if (at == 0) return 0;
    var i = at - 1;
    // UTF-8 continuation bytes are 0b10xxxxxx; step back to the lead byte.
    while (i > 0 and g_buf[i] & 0xC0 == 0x80) i -= 1;
    return i;
}

fn next_boundary(at: usize) usize {
    std.debug.assert(at <= g_len);
    if (at >= g_len) return g_len;
    var i = at + 1;
    while (i < g_len and g_buf[i] & 0xC0 == 0x80) i += 1;
    return i;
}

fn delete_range(a: usize, b: usize) void {
    std.debug.assert(a <= b);
    std.debug.assert(b <= g_len);
    std.mem.copyForwards(u8, g_buf[a .. g_len - (b - a)], g_buf[b..g_len]);
    g_len -= b - a;
    g_caret = a;
    g_anchor = a;
}

fn insert(bytes: []const u8) void {
    std.debug.assert(g_caret <= g_len);
    std.debug.assert(g_len <= FIELD_BUF_MAX);
    if (sel_range()) |sel| delete_range(sel[0], sel[1]);
    if (g_len + bytes.len > FIELD_BUF_MAX) return; // full: drop, the EDIT limit model
    const at = g_caret;
    std.mem.copyBackwards(
        u8,
        g_buf[at + bytes.len .. g_len + bytes.len],
        g_buf[at..g_len],
    );
    @memcpy(g_buf[at .. at + bytes.len], bytes);
    g_len += bytes.len;
    g_caret = at + bytes.len;
    g_anchor = g_caret;
}

pub fn apply_key(event: KeyEvent, clipboard: Clipboard) void {
    std.debug.assert(g_visible);
    if (event.mods.cmd) {
        // A held primary modifier still forwards Enter/Escape as a field-special so app shortcuts
        // (Cmd/Ctrl+Enter to send) fire; other cmd-combos are the field's own edit shortcuts.
        switch (event.code) {
            .enter => g_special = if (event.mods.shift) .shift_enter else .enter,
            .escape => {
                g_anchor = g_caret;
                g_special = .escape;
            },
            else => apply_shortcut(event.ch, clipboard),
        }
        return;
    }
    switch (event.code) {
        .char => apply_char(event.ch),
        .backspace => if (sel_range()) |sel|
            delete_range(sel[0], sel[1])
        else
            delete_range(prev_boundary(g_caret), g_caret),
        .delete_fwd => if (sel_range()) |sel|
            delete_range(sel[0], sel[1])
        else
            delete_range(g_caret, next_boundary(g_caret)),
        .left => {
            g_caret = prev_boundary(g_caret);
            if (!event.mods.shift) g_anchor = g_caret;
        },
        .right => {
            g_caret = next_boundary(g_caret);
            if (!event.mods.shift) g_anchor = g_caret;
        },
        .home => {
            g_caret = 0;
            if (!event.mods.shift) g_anchor = 0;
        },
        .end => {
            g_caret = g_len;
            if (!event.mods.shift) g_anchor = g_caret;
        },
        .escape => {
            g_anchor = g_caret;
            g_special = .escape;
        },
        .enter => g_special = if (event.mods.shift) .shift_enter else .enter,
        // Consumed but inert in a single-line field, the EDIT child model.
        .tab, .up, .down, .page_up, .page_down => {},
    }
}

fn apply_char(ch: u21) void {
    if (ch == 0) return;
    if (g_numeric and !(ch >= '0' and ch <= '9') and ch != '.' and ch != '-') return;
    var utf8: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(ch, &utf8) catch return;
    std.debug.assert(n >= 1);
    std.debug.assert(n <= utf8.len);
    insert(utf8[0..n]);
}

fn apply_shortcut(ch: u21, clipboard: Clipboard) void {
    switch (ch) {
        'a', 'A' => {
            g_anchor = 0;
            g_caret = g_len;
        },
        'c', 'C' => copy_selection(clipboard),
        'x', 'X' => {
            copy_selection(clipboard);
            if (sel_range()) |sel| delete_range(sel[0], sel[1]);
        },
        'v', 'V' => {
            var tmp: [FIELD_BUF_MAX]u8 = undefined;
            const pasted = clipboard.read_into(&tmp);
            if (paste_ok(pasted)) insert(pasted);
        },
        else => {},
    }
}

// A clipboard blob is foreign input: a truncated transfer could park the
// caret mid-codepoint, and a numeric field must filter paste like typing
// (the windows ES_NUMBER behavior).
fn paste_ok(pasted: []const u8) bool {
    if (pasted.len == 0) return false;
    if (!std.unicode.utf8ValidateSlice(pasted)) return false;
    if (!g_numeric) return true;
    for (pasted) |byte| {
        if (!(byte >= '0' and byte <= '9') and byte != '.' and byte != '-') return false;
    }
    return true;
}

fn copy_selection(clipboard: Clipboard) void {
    if (g_secure) return; // never leak a password through the clipboard
    const sel = sel_range() orelse return;
    clipboard.write_string(g_buf[sel[0]..sel[1]]);
}
