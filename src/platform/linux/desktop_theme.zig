// Resolves the desktop accent color the way each desktop's own chrome does:
// GTK-family desktops (Cinnamon/GNOME/MATE/XFCE) name a theme whose css
// defines theme_selected_bg_color - changing the accent in Settings swaps
// that variant; KDE stores the accent directly in kdeglobals. Every source
// that fails falls through, ending at null (the app theme stands in), so an
// unknown desktop degrades, never breaks. Read once per process at first use.

const std = @import("std");
const color = @import("../../color.zig");

extern "c" fn popen(command: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern "c" fn pclose(stream: *anyopaque) c_int;
extern "c" fn fgets(buf: [*]u8, size: c_int, stream: *anyopaque) ?[*]u8;
extern "c" fn open(path: [*:0]const u8, flags: c_int) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, count: usize) isize;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
const O_RDONLY: c_int = 0;

const THEME_NAME_MAX = 128;
// define-color lines sit at the top of every theme css; cap the scan there.
const CSS_SCAN_MAX = 256 * 1024;
const CHUNK = 4096;

const ACCENT_KEYS = [_][]const u8{
    "@define-color theme_selected_bg_color #",
    "@define-color accent_bg_color #",
};

// One desktop session per process; the resolved accent never changes mid-run.
var g_resolved = false;
var g_accent: ?color.Rgba = null;

pub fn accent_color() ?color.Rgba {
    if (g_resolved) return g_accent;
    g_resolved = true;
    var name_buf: [THEME_NAME_MAX]u8 = undefined;
    if (read_theme_name(&name_buf)) |name| {
        std.debug.assert(name.len >= 1);
        std.debug.assert(name.len < THEME_NAME_MAX);
        g_accent = accent_from_theme(name);
    }
    if (g_accent == null) g_accent = accent_from_kdeglobals();
    return g_accent;
}

// KDE keeps the accent as decimal "r,g,b" under [General] in kdeglobals; the
// key is absent when the user runs the stock Breeze accent.
fn accent_from_kdeglobals() ?color.Rgba {
    const home = getenv("HOME") orelse return null;
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrintZ(
        &path_buf,
        "{s}/.config/kdeglobals",
        .{std.mem.sliceTo(home, 0)},
    ) catch return null;
    var contents: [CHUNK]u8 = undefined;
    const len = read_file_prefix(path, &contents) orelse return null;
    const text = contents[0..len];
    const key = "AccentColor=";
    const start = (std.mem.indexOf(u8, text, key) orelse return null) + key.len;
    const end = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
    return parse_decimal_rgb(text[start..end]);
}

fn parse_decimal_rgb(text: []const u8) ?color.Rgba {
    std.debug.assert(text.len <= CHUNK);
    var it = std.mem.splitScalar(u8, std.mem.trim(u8, text, " \t\r"), ',');
    var channels: [3]u8 = undefined;
    for (&channels) |*channel| {
        const part = it.next() orelse return null;
        channel.* = std.fmt.parseInt(u8, std.mem.trim(u8, part, " "), 10) catch return null;
    }
    if (it.next() != null) return null;
    return color.Rgba.from_u8(channels[0], channels[1], channels[2], 255);
}

// The theme name source mirrors each desktop's own mechanism: gsettings
// schemas (cinnamon, gnome, mate), xfconf (xfce), then the static
// settings.ini some environments write. A missing tool just yields EOF.
fn read_theme_name(buf: *[THEME_NAME_MAX]u8) ?[]const u8 {
    const commands = [_][*:0]const u8{
        "gsettings get org.cinnamon.desktop.interface gtk-theme 2>/dev/null",
        "gsettings get org.gnome.desktop.interface gtk-theme 2>/dev/null",
        "gsettings get org.mate.interface gtk-theme 2>/dev/null",
        "xfconf-query -c xsettings -p /Net/ThemeName 2>/dev/null",
    };
    for (commands) |command| {
        if (theme_from_command(command, buf)) |name| return name;
    }
    return theme_from_settings_ini(buf);
}

fn theme_from_command(command: [*:0]const u8, buf: *[THEME_NAME_MAX]u8) ?[]const u8 {
    std.debug.assert(command[0] != 0);
    const stream = popen(command, "r") orelse return null;
    const line = fgets(buf, THEME_NAME_MAX, stream);
    _ = pclose(stream);
    if (line == null) return null;
    const raw = std.mem.sliceTo(buf, 0);
    // gsettings prints 'Name' quoted with a trailing newline.
    const trimmed = std.mem.trim(u8, raw, "'\n\r \t");
    if (trimmed.len == 0) return null;
    std.debug.assert(trimmed.len < THEME_NAME_MAX);
    return trimmed;
}

fn theme_from_settings_ini(buf: *[THEME_NAME_MAX]u8) ?[]const u8 {
    const home = getenv("HOME") orelse return null;
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrintZ(
        &path_buf,
        "{s}/.config/gtk-3.0/settings.ini",
        .{std.mem.sliceTo(home, 0)},
    ) catch return null;
    var contents: [CHUNK]u8 = undefined;
    const len = read_file_prefix(path, &contents) orelse return null;
    const text = contents[0..len];
    const key = "gtk-theme-name=";
    const start = (std.mem.indexOf(u8, text, key) orelse return null) + key.len;
    const end = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
    const name = std.mem.trim(u8, text[start..end], " \t\r");
    if (name.len == 0 or name.len >= THEME_NAME_MAX) return null;
    @memcpy(buf[0..name.len], name);
    return buf[0..name.len];
}

fn read_file_prefix(path: [*:0]const u8, buf: *[CHUNK]u8) ?usize {
    std.debug.assert(path[0] != 0);
    const fd = open(path, O_RDONLY);
    if (fd < 0) return null;
    defer _ = close(fd);
    const got = read(fd, buf, CHUNK);
    if (got <= 0) return null;
    std.debug.assert(got <= CHUNK);
    return @intCast(got);
}

fn accent_from_theme(name: []const u8) ?color.Rgba {
    std.debug.assert(name.len >= 1);
    const home = getenv("HOME");
    var path_buf: [512]u8 = undefined;
    if (home) |h| {
        const user_path = std.fmt.bufPrintZ(
            &path_buf,
            "{s}/.themes/{s}/gtk-3.0/gtk.css",
            .{ std.mem.sliceTo(h, 0), name },
        ) catch return null;
        if (scan_css_for_accent(user_path)) |rgba| return rgba;
    }
    const sys_path = std.fmt.bufPrintZ(
        &path_buf,
        "/usr/share/themes/{s}/gtk-3.0/gtk.css",
        .{name},
    ) catch return null;
    return scan_css_for_accent(sys_path);
}

// Streams the css in chunks with a key-sized overlap so a define-color split
// across a chunk boundary still matches.
fn scan_css_for_accent(path: [*:0]const u8) ?color.Rgba {
    std.debug.assert(path[0] != 0);
    const fd = open(path, O_RDONLY);
    if (fd < 0) return null;
    defer _ = close(fd);

    var buf: [CHUNK + 64]u8 = undefined;
    var carry: usize = 0;
    var scanned: usize = 0;
    while (scanned < CSS_SCAN_MAX) {
        const got = read(fd, buf[carry..].ptr, CHUNK);
        if (got <= 0) return null;
        const text = buf[0 .. carry + @as(usize, @intCast(got))];
        for (ACCENT_KEYS) |key| {
            if (std.mem.indexOf(u8, text, key)) |at| {
                const hex_start = at + key.len;
                if (hex_start + 6 <= text.len) return parse_hex_rgb(text[hex_start..][0..6]);
            }
        }
        carry = @min(text.len, 64);
        std.mem.copyForwards(u8, buf[0..carry], text[text.len - carry ..]);
        scanned += @intCast(got);
    }
    return null;
}

fn parse_hex_rgb(hex: *const [6]u8) ?color.Rgba {
    const value = std.fmt.parseInt(u24, hex, 16) catch return null;
    return color.Rgba.from_hex((@as(u32, value) << 8) | 0xFF);
}
