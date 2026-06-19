// Interactive terminal prompts (select / multiselect / text / confirm), the way a
// framework scaffolder asks its questions. POSIX raw mode + ANSI redraw; ASCII only,
// no box-drawing. The caller checks is_tty first and falls back to flags when piped.

const std = @import("std");
const builtin = @import("builtin");
const cli = @import("main.zig");

const is_windows = builtin.os.tag == .windows;
const esc = "\x1b";
const fd_in = std.posix.STDIN_FILENO;

pub const Error = error{Aborted}; // the user pressed Ctrl-C

// Terminal in raw mode for the lifetime of one prompt; restores on leave(). The
// Windows arms are unreachable (is_tty gates entry) but must still compile, so the
// comptime branch keeps the POSIX termios calls out of the Windows build.
const Raw = struct {
    saved: if (is_windows) void else std.posix.termios,

    fn enter() !Raw {
        if (is_windows) {
            return .{ .saved = {} };
        } else {
            const saved = try std.posix.tcgetattr(fd_in);
            var raw = saved;
            raw.lflag.ECHO = false; // no key echo - we render the selection ourselves
            raw.lflag.ICANON = false; // byte at a time, not line at a time
            raw.lflag.ISIG = false; // Ctrl-C is a byte we handle, not a signal that skips cleanup
            raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
            raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
            try std.posix.tcsetattr(fd_in, .FLUSH, raw);
            return .{ .saved = saved };
        }
    }

    fn leave(self: Raw) void {
        if (is_windows) return;
        std.posix.tcsetattr(fd_in, .FLUSH, self.saved) catch {};
    }
};

const Key = union(enum) { up, down, enter, space, backspace, ctrl_c, char: u8, other };

fn read_byte() !?u8 {
    if (is_windows) {
        return null;
    } else {
        var b: [1]u8 = undefined;
        const n = try std.posix.read(fd_in, &b);
        return if (n == 0) null else b[0];
    }
}

fn read_key() !Key {
    const b = (try read_byte()) orelse return .ctrl_c; // EOF behaves like an abort
    switch (b) {
        3 => return .ctrl_c,
        13, 10 => return .enter,
        32 => return .space,
        127, 8 => return .backspace,
        'k' => return .up, // vi keys, alongside the arrows
        'j' => return .down,
        esc[0] => {
            if ((try read_byte()) orelse 0 != '[') return .other;
            return switch ((try read_byte()) orelse 0) {
                'A' => .up,
                'B' => .down,
                else => .other,
            };
        },
        else => return if (b >= 0x20 and b < 0x7f) .{ .char = b } else .other,
    }
}

// One choice from a list. Arrows / j / k move, Enter selects. Returns the index.
pub fn select(ctx: cli.Ctx, title: []const u8, items: []const []const u8) !usize {
    std.debug.assert(items.len > 0);
    std.debug.assert(title.len > 0);
    const raw = try Raw.enter();
    defer raw.leave();

    var cursor: usize = 0;
    try ctx.out.print("{s} " ++ esc ++ "[2m(arrows, enter)" ++ esc ++ "[0m\n", .{title});
    try draw_select(ctx, items, cursor, false);

    while (true) {
        switch (try read_key()) {
            .up => cursor = if (cursor == 0) items.len - 1 else cursor - 1,
            .down => cursor = (cursor + 1) % items.len,
            .enter => break,
            .ctrl_c => return abort(ctx),
            else => continue,
        }
        try draw_select(ctx, items, cursor, true);
    }
    try draw_select(ctx, items, cursor, true); // final repaint, cursor shown by caller's next line
    return cursor;
}

fn draw_select(ctx: cli.Ctx, items: []const []const u8, cursor: usize, repaint: bool) !void {
    if (repaint) try ctx.out.print(esc ++ "[{d}A", .{items.len}); // back to the list top
    for (items, 0..) |item, i| {
        const on = i == cursor;
        const dot = if (on) esc ++ "[36m>" else " ";
        const reset = esc ++ "[0m";
        try ctx.out.print(esc ++ "[2K{s} {s}{s}\n", .{ dot, item, reset });
    }
    try ctx.out.flush();
}

// Many choices. Space toggles, Enter confirms. Fills `chosen` (len == items.len).
pub fn multiselect(
    ctx: cli.Ctx,
    title: []const u8,
    items: []const []const u8,
    chosen: []bool,
) !void {
    std.debug.assert(items.len > 0);
    std.debug.assert(chosen.len == items.len);
    const raw = try Raw.enter();
    defer raw.leave();

    var cursor: usize = 0;
    try ctx.out.print(
        "{s} " ++ esc ++ "[2m(space toggles, enter confirms)" ++ esc ++ "[0m\n",
        .{title},
    );
    try draw_multi(ctx, items, chosen, cursor, false);

    while (true) {
        switch (try read_key()) {
            .up => cursor = if (cursor == 0) items.len - 1 else cursor - 1,
            .down => cursor = (cursor + 1) % items.len,
            .space => chosen[cursor] = !chosen[cursor],
            .enter => break,
            .ctrl_c => return abort(ctx),
            else => continue,
        }
        try draw_multi(ctx, items, chosen, cursor, true);
    }
}

fn draw_multi(
    ctx: cli.Ctx,
    items: []const []const u8,
    chosen: []const bool,
    cursor: usize,
    repaint: bool,
) !void {
    if (repaint) try ctx.out.print(esc ++ "[{d}A", .{items.len});
    for (items, 0..) |item, i| {
        const point = if (i == cursor) ">" else " ";
        const box = if (chosen[i]) esc ++ "[36m[x]" else "[ ]";
        try ctx.out.print(esc ++ "[2K{s} {s} {s}" ++ esc ++ "[0m\n", .{ point, box, item });
    }
    try ctx.out.flush();
}

// A line of text. Backspace edits; Enter accepts (empty -> default). Arena-owned.
pub fn text(ctx: cli.Ctx, title: []const u8, default: []const u8) ![]const u8 {
    std.debug.assert(title.len > 0);
    const raw = try Raw.enter();
    defer raw.leave();

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    try ctx.out.print("{s} " ++ esc ++ "[2m({s})" ++ esc ++ "[0m\n", .{ title, default });
    try draw_text(ctx, buf.items, false);

    while (true) {
        switch (try read_key()) {
            .enter => break,
            .backspace => {
                if (buf.items.len > 0) buf.items.len -= 1;
                try draw_text(ctx, buf.items, true);
            },
            .ctrl_c => return abort(ctx),
            .char => |c| {
                try buf.append(ctx.gpa, c);
                try draw_text(ctx, buf.items, true);
            },
            else => continue,
        }
    }
    return if (buf.items.len == 0) default else buf.items;
}

fn draw_text(ctx: cli.Ctx, value: []const u8, repaint: bool) !void {
    if (repaint) try ctx.out.print(esc ++ "[1A", .{});
    try ctx.out.print(esc ++ "[2K" ++ esc ++ "[36m> " ++ esc ++ "[0m{s}\n", .{value});
    try ctx.out.flush();
}

// A yes/no. Enter takes the default.
pub fn confirm(ctx: cli.Ctx, title: []const u8, default_yes: bool) !bool {
    std.debug.assert(title.len > 0);
    const raw = try Raw.enter();
    defer raw.leave();

    const hint = if (default_yes) "(Y/n)" else "(y/N)";
    try ctx.out.print("{s} {s} ", .{ title, hint });
    try ctx.out.flush();
    while (true) {
        switch (try read_key()) {
            .enter => break,
            .ctrl_c => return abort(ctx),
            .char => |c| {
                if (c == 'y' or c == 'Y') {
                    try ctx.out.print("yes\n", .{});
                    try ctx.out.flush();
                    return true;
                }
                if (c == 'n' or c == 'N') {
                    try ctx.out.print("no\n", .{});
                    try ctx.out.flush();
                    return false;
                }
            },
            else => continue,
        }
    }
    try ctx.out.print("{s}\n", .{if (default_yes) "yes" else "no"});
    try ctx.out.flush();
    return default_yes;
}

fn abort(ctx: cli.Ctx) Error {
    ctx.out.print("\n" ++ esc ++ "[31maborted" ++ esc ++ "[0m\n", .{}) catch {};
    ctx.out.flush() catch {};
    return Error.Aborted;
}

pub fn is_tty(ctx: cli.Ctx) bool {
    if (is_windows) return false; // no POSIX raw mode here: drive create through flags
    return std.Io.File.stdin().isTty(ctx.io) catch false;
}
