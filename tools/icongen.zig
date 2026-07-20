// Build-time converter: Lucide SVG -> embedded path data for the bundled icon
// provider. Parses the SVG `d` attribute (+ <circle>/<line>/<rect>/<polyline>)
// and NORMALISES every command to move/line/cubic/close, so the runtime
// rasterizer (src/icon_bundled.zig) stays minimal. Run offline; the generated
// Zig file is committed.
//
//   zig run tools/icongen.zig -- <name>=<file.svg> ...  > src/icon_lucide_data.zig
//   zig test tools/icongen.zig                          (parser tests)
const std = @import("std");

pub const Cmd = union(enum) {
    move: [2]f32,
    line: [2]f32,
    cubic: [6]f32,
    close,
};

const Parser = struct {
    s: []const u8,
    i: usize = 0,
    // current point, subpath start, last cubic control (S) + last quad control (T)
    cx: f32 = 0,
    cy: f32 = 0,
    sx: f32 = 0,
    sy: f32 = 0,
    pcx: f32 = 0,
    pcy: f32 = 0,
    qcx: f32 = 0,
    qcy: f32 = 0,
    had_cubic: bool = false,
    had_quad: bool = false,
    alloc: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(Cmd),

    fn is_sep(c: u8) bool {
        return c == ' ' or c == ',' or c == '\t' or c == '\n' or c == '\r';
    }

    fn skip_sep(p: *Parser) void {
        while (p.i < p.s.len and is_sep(p.s[p.i])) p.i += 1;
    }

    // SVG number scan: a '-'/'+' or (a second) '.' delimits the next number, so
    // "6-6" is two numbers and "1.5.5" is "1.5" then ".5".
    fn number(p: *Parser) f32 {
        std.debug.assert(p.i <= p.s.len);
        p.skip_sep();
        const start = p.i;
        var seen_dot = false;
        if (p.i < p.s.len and (p.s[p.i] == '-' or p.s[p.i] == '+')) p.i += 1;
        while (p.i < p.s.len) {
            const c = p.s[p.i];
            if (c >= '0' and c <= '9') {
                p.i += 1;
            } else if (c == '.' and !seen_dot) {
                seen_dot = true;
                p.i += 1;
            } else if (c == 'e' or c == 'E') {
                p.i += 1;
                if (p.i < p.s.len and (p.s[p.i] == '-' or p.s[p.i] == '+')) p.i += 1;
            } else break;
        }
        std.debug.assert(p.i >= start);
        return std.fmt.parseFloat(f32, p.s[start..p.i]) catch 0;
    }

    fn flag(p: *Parser) f32 {
        std.debug.assert(p.i <= p.s.len);
        p.skip_sep();
        if (p.i < p.s.len and (p.s[p.i] == '0' or p.s[p.i] == '1')) {
            const v: f32 = if (p.s[p.i] == '1') 1 else 0;
            p.i += 1;
            return v;
        }
        return p.number();
    }

    fn moveTo(p: *Parser, x: f32, y: f32) !void {
        std.debug.assert(!std.math.isNan(x) and !std.math.isNan(y));
        p.cx = x;
        p.cy = y;
        p.sx = x;
        p.sy = y;
        p.had_cubic = false;
        p.had_quad = false;
        try p.out.append(p.alloc, .{ .move = .{ x, y } });
    }
    fn lineTo(p: *Parser, x: f32, y: f32) !void {
        std.debug.assert(!std.math.isNan(x) and !std.math.isNan(y));
        p.cx = x;
        p.cy = y;
        p.had_cubic = false;
        p.had_quad = false;
        try p.out.append(p.alloc, .{ .line = .{ x, y } });
    }
    fn cubicTo(p: *Parser, x1: f32, y1: f32, x2: f32, y2: f32, x: f32, y: f32) !void {
        std.debug.assert(!std.math.isNan(x1) and !std.math.isNan(y1));
        std.debug.assert(!std.math.isNan(x) and !std.math.isNan(y));
        try p.out.append(p.alloc, .{ .cubic = .{ x1, y1, x2, y2, x, y } });
        p.pcx = x2;
        p.pcy = y2;
        p.had_cubic = true;
        p.had_quad = false;
        p.cx = x;
        p.cy = y;
    }

    // Quadratic -> cubic (degree elevation), remembering the quad control so a
    // following smooth-quad (T) can reflect it.
    fn quadTo(p: *Parser, qx: f32, qy: f32, x: f32, y: f32) !void {
        const x1 = p.cx + 2.0 / 3.0 * (qx - p.cx);
        const y1 = p.cy + 2.0 / 3.0 * (qy - p.cy);
        const x2 = x + 2.0 / 3.0 * (qx - x);
        const y2 = y + 2.0 / 3.0 * (qy - y);
        try p.cubicTo(x1, y1, x2, y2, x, y);
        p.qcx = qx;
        p.qcy = qy;
        p.had_quad = true;
    }

    fn is_num_start(c: u8) bool {
        return c == '-' or c == '+' or c == '.' or (c >= '0' and c <= '9');
    }

    fn run(p: *Parser) !void {
        var cmd: u8 = 0;
        var guard: usize = 0;
        // Each iteration consumes >= 1 byte (a command letter, a number, or a
        // break), so the input length bounds the loop - a junk byte where a
        // coordinate is due breaks instead of spinning in place.
        while (p.i < p.s.len) : (guard += 1) {
            std.debug.assert(guard <= p.s.len);
            p.skip_sep();
            if (p.i >= p.s.len) break;
            const ch = p.s[p.i];
            if (std.ascii.isAlphabetic(ch)) {
                cmd = ch;
                p.i += 1;
            } else if (cmd == 0 or !is_num_start(ch)) {
                break;
            }
            const rel = std.ascii.isLower(cmd);
            const ox = if (rel) p.cx else 0;
            const oy = if (rel) p.cy else 0;
            switch (std.ascii.toUpper(cmd)) {
                'M' => {
                    const x = p.number() + ox;
                    const y = p.number() + oy;
                    try p.moveTo(x, y);
                    cmd = if (rel) 'l' else 'L'; // implicit subsequent pairs are lineto
                },
                'L' => {
                    const x = p.number() + (if (rel) p.cx else 0);
                    const y = p.number() + (if (rel) p.cy else 0);
                    try p.lineTo(x, y);
                },
                'H' => try p.lineTo(p.number() + (if (rel) p.cx else 0), p.cy),
                'V' => try p.lineTo(p.cx, p.number() + (if (rel) p.cy else 0)),
                'C' => {
                    const x1 = p.number() + ox;
                    const y1 = p.number() + oy;
                    const x2 = p.number() + ox;
                    const y2 = p.number() + oy;
                    const x = p.number() + ox;
                    const y = p.number() + oy;
                    try p.cubicTo(x1, y1, x2, y2, x, y);
                },
                'S' => {
                    const x2 = p.number() + ox;
                    const y2 = p.number() + oy;
                    const x = p.number() + ox;
                    const y = p.number() + oy;
                    const x1 = if (p.had_cubic) 2 * p.cx - p.pcx else p.cx;
                    const y1 = if (p.had_cubic) 2 * p.cy - p.pcy else p.cy;
                    try p.cubicTo(x1, y1, x2, y2, x, y);
                },
                'Q' => {
                    const qx = p.number() + ox;
                    const qy = p.number() + oy;
                    const x = p.number() + ox;
                    const y = p.number() + oy;
                    try p.quadTo(qx, qy, x, y);
                },
                'T' => {
                    const x = p.number() + ox;
                    const y = p.number() + oy;
                    const qx = if (p.had_quad) 2 * p.cx - p.qcx else p.cx;
                    const qy = if (p.had_quad) 2 * p.cy - p.qcy else p.cy;
                    try p.quadTo(qx, qy, x, y);
                },
                'A' => {
                    const rx = p.number();
                    const ry = p.number();
                    const rot = p.number();
                    const large = p.flag();
                    const sweep = p.flag();
                    const x = p.number() + ox;
                    const y = p.number() + oy;
                    try p.arc(rx, ry, rot, large != 0, sweep != 0, x, y);
                },
                'Z' => {
                    try p.out.append(p.alloc, .close);
                    p.cx = p.sx;
                    p.cy = p.sy;
                },
                else => break,
            }
            // implicit repeat (same command, more coord pairs) is handled by the
            // loop: a non-letter at the top re-enters the switch with cmd intact.
        }
    }

    // Endpoint arc -> center parameterisation -> cubic segments (<=90deg each).
    fn arc(p: *Parser, rx_in: f32, ry_in: f32, rot_deg: f32, large: bool, sweep: bool, ex: f32, ey: f32) !void {
        const x1 = p.cx;
        const y1 = p.cy;
        if (rx_in == 0 or ry_in == 0) {
            try p.lineTo(ex, ey);
            return;
        }
        var rx = @abs(rx_in);
        var ry = @abs(ry_in);
        std.debug.assert(rx > 0 and ry > 0);
        const phi = rot_deg * std.math.pi / 180.0;
        const cosp = @cos(phi);
        const sinp = @sin(phi);
        const dx2 = (x1 - ex) / 2.0;
        const dy2 = (y1 - ey) / 2.0;
        const x1p = cosp * dx2 + sinp * dy2;
        const y1p = -sinp * dx2 + cosp * dy2;
        var lam = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry);
        if (lam > 1) {
            const s = @sqrt(lam);
            rx *= s;
            ry *= s;
            lam = 1;
        }
        const sign: f32 = if (large != sweep) 1 else -1;
        var num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p;
        if (num < 0) num = 0;
        const den = rx * rx * y1p * y1p + ry * ry * x1p * x1p;
        const co = sign * @sqrt(num / @max(den, 1e-9));
        const cxp = co * (rx * y1p) / ry;
        const cyp = co * -(ry * x1p) / rx;
        const cx = cosp * cxp - sinp * cyp + (x1 + ex) / 2.0;
        const cy = sinp * cxp + cosp * cyp + (y1 + ey) / 2.0;
        const ang = struct {
            fn f(ux: f32, uy: f32, vx: f32, vy: f32) f32 {
                const dot = ux * vx + uy * vy;
                const len = @sqrt((ux * ux + uy * uy) * (vx * vx + vy * vy));
                var a = std.math.acos(std.math.clamp(dot / @max(len, 1e-9), -1, 1));
                if (ux * vy - uy * vx < 0) a = -a;
                return a;
            }
        }.f;
        const theta1 = ang(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry);
        var dtheta = ang((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry);
        if (!sweep and dtheta > 0) dtheta -= 2 * std.math.pi;
        if (sweep and dtheta < 0) dtheta += 2 * std.math.pi;
        const segs: usize = @intFromFloat(@ceil(@abs(dtheta) / (std.math.pi / 2.0)));
        std.debug.assert(segs <= 4); // <=90deg per segment, <=360deg total arc
        const dt = dtheta / @as(f32, @floatFromInt(@max(segs, 1)));
        const alpha = 4.0 / 3.0 * @tan(dt / 4.0);
        var t = theta1;
        var k: usize = 0;
        while (k < segs) : (k += 1) {
            const t2 = t + dt;
            const cosT1 = @cos(t);
            const sinT1 = @sin(t);
            const cosT2 = @cos(t2);
            const sinT2 = @sin(t2);
            const e1x = cx + rx * cosp * cosT1 - ry * sinp * sinT1;
            const e1y = cy + rx * sinp * cosT1 + ry * cosp * sinT1;
            const e2x = cx + rx * cosp * cosT2 - ry * sinp * sinT2;
            const e2y = cy + rx * sinp * cosT2 + ry * cosp * sinT2;
            const d1x = -rx * cosp * sinT1 - ry * sinp * cosT1;
            const d1y = -rx * sinp * sinT1 + ry * cosp * cosT1;
            const d2x = -rx * cosp * sinT2 - ry * sinp * cosT2;
            const d2y = -rx * sinp * sinT2 + ry * cosp * cosT2;
            try p.cubicTo(e1x + alpha * d1x, e1y + alpha * d1y, e2x - alpha * d2x, e2y - alpha * d2y, e2x, e2y);
            t = t2;
        }
        p.cx = ex;
        p.cy = ey;
    }
};

pub fn parse_path(alloc: std.mem.Allocator, d: []const u8) ![]Cmd {
    var out: std.ArrayListUnmanaged(Cmd) = .empty;
    var p = Parser{ .s = d, .out = &out, .alloc = alloc };
    try p.run();
    return out.toOwnedSlice(alloc);
}

// --- SVG element extraction -------------------------------------------------
// Lucide draws with <path>, <circle>, <line>, <rect>, <polyline>, <polygon>,
// <ellipse>. Each non-path element is turned into an equivalent `d` string and
// fed through the same parser, so the normaliser has one code path.

fn tag_attr(tag: []const u8, name: []const u8) ?f32 {
    var it = std.mem.tokenizeAny(u8, tag, " \t\n\r/<>");
    while (it.next()) |tok| {
        if (std.mem.startsWith(u8, tok, name) and tok.len > name.len and tok[name.len] == '=') {
            const q1 = std.mem.indexOfScalar(u8, tok, '"') orelse continue;
            const rest = tok[q1 + 1 ..];
            const q2 = std.mem.indexOfScalar(u8, rest, '"') orelse rest.len;
            return std.fmt.parseFloat(f32, rest[0..q2]) catch null;
        }
    }
    return null;
}

fn quoted_value(src: []const u8, key: []const u8) ?[]const u8 {
    const k = std.mem.indexOf(u8, src, key) orelse return null;
    const start = k + key.len;
    const end = std.mem.indexOfScalarPos(u8, src, start, '"') orelse return null;
    return src[start..end];
}

fn append_parsed(alloc: std.mem.Allocator, list: *std.ArrayListUnmanaged(Cmd), d: []const u8) !void {
    const cmds = try parse_path(alloc, d);
    defer alloc.free(cmds);
    try list.appendSlice(alloc, cmds);
}

// Each <element ...> tag, for one element name, in document order.
fn each_tag(src: []const u8, comptime name: []const u8, alloc: std.mem.Allocator, list: *std.ArrayListUnmanaged(Cmd)) !void {
    const open = "<" ++ name;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, src, i, open)) |s| {
        // The element name must end at a boundary, else "<line" would also match
        // "<linearGradient" (no such element in Lucide, but keep it honest).
        const after = if (s + open.len < src.len) src[s + open.len] else '>';
        if (after != ' ' and after != '\t' and after != '\n' and after != '\r' and after != '>' and after != '/') {
            i = s + open.len;
            continue;
        }
        const e = std.mem.indexOfScalarPos(u8, src, s, '>') orelse break;
        const tag = src[s .. e + 1];
        i = e + 1;
        var buf: [512]u8 = undefined;
        if (std.mem.eql(u8, name, "circle")) {
            const cx = tag_attr(tag, "cx") orelse continue;
            const cy = tag_attr(tag, "cy") orelse continue;
            const r = tag_attr(tag, "r") orelse continue;
            const d = try std.fmt.bufPrint(&buf, "M{d} {d}a{d} {d} 0 1 0 {d} 0a{d} {d} 0 1 0 {d} 0", .{ cx - r, cy, r, r, 2 * r, r, r, -2 * r });
            try append_parsed(alloc, list, d);
        } else if (std.mem.eql(u8, name, "ellipse")) {
            const cx = tag_attr(tag, "cx") orelse continue;
            const cy = tag_attr(tag, "cy") orelse continue;
            const rx = tag_attr(tag, "rx") orelse continue;
            const ry = tag_attr(tag, "ry") orelse continue;
            const d = try std.fmt.bufPrint(&buf, "M{d} {d}a{d} {d} 0 1 0 {d} 0a{d} {d} 0 1 0 {d} 0", .{ cx - rx, cy, rx, ry, 2 * rx, rx, ry, -2 * rx });
            try append_parsed(alloc, list, d);
        } else if (std.mem.eql(u8, name, "line")) {
            const x1 = tag_attr(tag, "x1") orelse continue;
            const y1 = tag_attr(tag, "y1") orelse continue;
            const x2 = tag_attr(tag, "x2") orelse continue;
            const y2 = tag_attr(tag, "y2") orelse continue;
            const d = try std.fmt.bufPrint(&buf, "M{d} {d}L{d} {d}", .{ x1, y1, x2, y2 });
            try append_parsed(alloc, list, d);
        } else if (std.mem.eql(u8, name, "rect")) {
            const x = tag_attr(tag, "x") orelse 0;
            const y = tag_attr(tag, "y") orelse 0;
            const w = tag_attr(tag, "width") orelse continue;
            const h = tag_attr(tag, "height") orelse continue;
            const d = try std.fmt.bufPrint(&buf, "M{d} {d}h{d}v{d}h{d}Z", .{ x, y, w, h, -w });
            try append_parsed(alloc, list, d);
        } else if (std.mem.eql(u8, name, "polyline") or std.mem.eql(u8, name, "polygon")) {
            const pts = quoted_value(tag, "points=\"") orelse continue;
            const d = try std.fmt.bufPrint(&buf, "M{s}{s}", .{ pts, if (std.mem.eql(u8, name, "polygon")) "Z" else "" });
            try append_parsed(alloc, list, d);
        }
    }
}

fn extract_svg(alloc: std.mem.Allocator, src: []const u8) ![]Cmd {
    var list: std.ArrayListUnmanaged(Cmd) = .empty;
    errdefer list.deinit(alloc);
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, src, i, "d=\"")) |s| {
        const start = s + 3;
        const end = std.mem.indexOfScalarPos(u8, src, start, '"') orelse break;
        try append_parsed(alloc, &list, src[start..end]);
        i = end + 1;
    }
    try each_tag(src, "circle", alloc, &list);
    try each_tag(src, "ellipse", alloc, &list);
    try each_tag(src, "line", alloc, &list);
    try each_tag(src, "rect", alloc, &list);
    try each_tag(src, "polyline", alloc, &list);
    try each_tag(src, "polygon", alloc, &list);
    return list.toOwnedSlice(alloc);
}

// --- codegen ----------------------------------------------------------------

const Map = struct { icon: []const u8, lucide: []const u8 };

// Icon enum member -> Lucide icon name. Empty lucide = no clean Lucide match
// (Lucide is stroke-only, so the *_fill members stay native-only).
const MAP = [_]Map{
    .{ .icon = "close", .lucide = "x" },
    .{ .icon = "close_circle", .lucide = "circle-x" },
    .{ .icon = "close_circle_fill", .lucide = "" },
    .{ .icon = "check", .lucide = "check" },
    .{ .icon = "check_circle", .lucide = "circle-check" },
    .{ .icon = "check_circle_fill", .lucide = "" },
    .{ .icon = "plus", .lucide = "plus" },
    .{ .icon = "plus_square", .lucide = "square-plus" },
    .{ .icon = "minus", .lucide = "minus" },
    .{ .icon = "chevron_up", .lucide = "chevron-up" },
    .{ .icon = "chevron_down", .lucide = "chevron-down" },
    .{ .icon = "chevron_left", .lucide = "chevron-left" },
    .{ .icon = "chevron_right", .lucide = "chevron-right" },
    .{ .icon = "chevron_up_down", .lucide = "chevrons-up-down" },
    .{ .icon = "arrow_right", .lucide = "arrow-right" },
    .{ .icon = "arrow_clockwise", .lucide = "rotate-cw" },
    .{ .icon = "arrow_down_circle", .lucide = "circle-arrow-down" },
    .{ .icon = "arrow_down_to_line", .lucide = "arrow-down-to-line" },
    .{ .icon = "search", .lucide = "search" },
    .{ .icon = "sidebar", .lucide = "panel-left" },
    .{ .icon = "gear", .lucide = "settings" },
    .{ .icon = "gear_fill", .lucide = "" },
    .{ .icon = "info", .lucide = "info" },
    .{ .icon = "warning", .lucide = "triangle-alert" },
    .{ .icon = "bold", .lucide = "bold" },
    .{ .icon = "italic", .lucide = "italic" },
    .{ .icon = "underline", .lucide = "underline" },
    .{ .icon = "align_left", .lucide = "text-align-start" },
    .{ .icon = "align_center", .lucide = "text-align-center" },
    .{ .icon = "align_right", .lucide = "text-align-end" },
    .{ .icon = "share", .lucide = "share" },
    .{ .icon = "save", .lucide = "save" },
    .{ .icon = "copy", .lucide = "copy" },
    .{ .icon = "grid", .lucide = "grid-3x3" },
    .{ .icon = "layout_grid", .lucide = "layout-grid" },
    .{ .icon = "bell", .lucide = "bell" },
    .{ .icon = "bell_badge", .lucide = "bell-dot" },
    .{ .icon = "pin", .lucide = "pin" },
    .{ .icon = "eye", .lucide = "eye" },
    .{ .icon = "eye_slash", .lucide = "eye-off" },
    .{ .icon = "calendar", .lucide = "calendar" },
    .{ .icon = "lock", .lucide = "lock" },
    .{ .icon = "layers", .lucide = "layers" },
    .{ .icon = "square_terminal", .lucide = "square-terminal" },
    .{ .icon = "folder_dot", .lucide = "folder-dot" },
    .{ .icon = "folder_open_dot", .lucide = "folder-open-dot" },
    .{ .icon = "folder_open", .lucide = "folder-open" },
    .{ .icon = "folder", .lucide = "folder" },
    .{ .icon = "trash", .lucide = "trash-2" },
    .{ .icon = "doc", .lucide = "file-text" },
    .{ .icon = "envelope", .lucide = "mail" },
    .{ .icon = "message", .lucide = "message-square" },
    .{ .icon = "person", .lucide = "user" },
    .{ .icon = "people", .lucide = "users" },
    .{ .icon = "people_fill", .lucide = "" },
    .{ .icon = "creditcard", .lucide = "credit-card" },
    .{ .icon = "creditcard_fill", .lucide = "" },
    .{ .icon = "heart", .lucide = "heart" },
    .{ .icon = "moon", .lucide = "moon" },
    .{ .icon = "sun", .lucide = "sun" },
    .{ .icon = "chart_bar", .lucide = "chart-bar" },
    .{ .icon = "dollar_sign", .lucide = "dollar-sign" },
    .{ .icon = "bolt", .lucide = "zap" },
    .{ .icon = "archive", .lucide = "archive" },
    .{ .icon = "battery", .lucide = "battery" },
    .{ .icon = "cpu", .lucide = "cpu" },
    .{ .icon = "wifi", .lucide = "wifi" },
    .{ .icon = "hard_drive", .lucide = "hard-drive" },
    .{ .icon = "package", .lucide = "package" },
    .{ .icon = "wrench", .lucide = "wrench" },
    .{ .icon = "ellipsis", .lucide = "ellipsis" },
    .{ .icon = "pencil", .lucide = "pencil" },
    .{ .icon = "star", .lucide = "star" },
    .{ .icon = "corner_down_left", .lucide = "corner-down-left" },
    .{ .icon = "braces", .lucide = "braces" },
    .{ .icon = "code", .lucide = "code" },
    .{ .icon = "file_code", .lucide = "file-code" },
    .{ .icon = "markdown", .lucide = "markdown" }, // not in Lucide; source: tools/extra-icons/markdown.svg
    .{ .icon = "image", .lucide = "image" },
    .{ .icon = "network", .lucide = "network" },
    .{ .icon = "toy_brick", .lucide = "toy-brick" },
    .{ .icon = "keyboard", .lucide = "keyboard" },
    .{ .icon = "laptop", .lucide = "laptop" },
    .{ .icon = "download", .lucide = "download" },
    .{ .icon = "database", .lucide = "database" },
    .{ .icon = "folder_plus", .lucide = "folder-plus" },
    .{ .icon = "file_plus", .lucide = "file-plus" },
    .{ .icon = "file_up", .lucide = "file-up" },
    .{ .icon = "eclipse", .lucide = "eclipse" },
    .{ .icon = "dog", .lucide = "dog" },
    .{ .icon = "telescope", .lucide = "telescope" },
    .{ .icon = "loader_pinwheel", .lucide = "loader-pinwheel" },
    .{ .icon = "git_branch", .lucide = "git-branch" },
    .{ .icon = "cloud", .lucide = "cloud" },
};

const Entry = struct { name: []const u8, cmds: []Cmd };

fn entry_lt(_: void, a: Entry, b: Entry) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

fn has_name(entries: []const Entry, want: []const u8) bool {
    for (entries) |e| if (std.mem.eql(u8, e.name, want)) return true;
    return false;
}

fn emit_cmds(alloc: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), cmds: []const Cmd) !void {
    for (cmds) |c| {
        const piece = switch (c) {
            .move => |p| try std.fmt.allocPrint(alloc, ".{{ .move = .{{ {d}, {d} }} }}, ", .{ p[0], p[1] }),
            .line => |p| try std.fmt.allocPrint(alloc, ".{{ .line = .{{ {d}, {d} }} }}, ", .{ p[0], p[1] }),
            .cubic => |p| try std.fmt.allocPrint(alloc, ".{{ .cubic = .{{ {d}, {d}, {d}, {d}, {d}, {d} }} }}, ", .{ p[0], p[1], p[2], p[3], p[4], p[5] }),
            .close => try alloc.dupe(u8, ".close, "),
        };
        defer alloc.free(piece);
        try out.appendSlice(alloc, piece);
    }
}

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;

    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    if (argv.len < 3) return error.Usage; // icongen <svg_dir> <out.zig>
    const svg_dir = argv[1];
    const out_path = argv[2];

    var dir = try std.Io.Dir.cwd().openDir(io, svg_dir, .{});
    defer dir.close(io);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(alloc);
    try out.appendSlice(alloc,
        \\// GENERATED by tools/icongen.zig - do not edit by hand.
        \\// Source: Lucide (https://lucide.dev), ISC license. Run:
        \\//   zig run tools/icongen.zig -- <svg_dir> src/icon_lucide_data.zig
        \\const std = @import("std");
        \\const Cmd = @import("icon_bundled.zig").Cmd;
        \\const Icon = @import("icon.zig").Icon;
        \\
        \\
    );

    // MAP-driven: read exactly the Lucide SVGs the Icon enum names - the enum is
    // the only key, so the generated file carries those icons and nothing more
    // (no by_name table). Sorted by name so the output is deterministic across
    // hosts regardless of MAP order.
    var entries: std.ArrayListUnmanaged(Entry) = .empty;
    defer {
        for (entries.items) |e| alloc.free(e.cmds);
        entries.deinit(alloc);
    }
    const arena = init.arena.allocator();

    var miss: usize = 0;
    for (MAP) |m| {
        if (m.lucide.len == 0) continue; // *_fill etc.: native-only, no bundled glyph
        if (has_name(entries.items, m.lucide)) continue; // two enum members share one source
        var name_buf: [256]u8 = undefined;
        const fname = try std.fmt.bufPrint(&name_buf, "{s}.svg", .{m.lucide});
        const src = dir.readFileAlloc(io, fname, alloc, .limited(1 << 16)) catch {
            std.debug.print("MISS {s} (no {s})\n", .{ m.icon, fname });
            miss += 1;
            continue;
        };
        defer alloc.free(src);
        const cmds = try extract_svg(alloc, src);
        if (cmds.len == 0) {
            alloc.free(cmds);
            std.debug.print("MISS {s} ({s} has no drawable path)\n", .{ m.icon, fname });
            miss += 1;
            continue;
        }
        try entries.append(alloc, .{ .name = try arena.dupe(u8, m.lucide), .cmds = cmds });
    }
    std.mem.sort(Entry, entries.items, {}, entry_lt);

    // One Cmd const per icon, keyed by the raw Lucide name via @"..." (sidesteps
    // dashes + Zig keywords like `type`).
    for (entries.items) |e| {
        const head = try std.fmt.allocPrint(alloc, "const @\"{s}\" = [_]Cmd{{ ", .{e.name});
        defer alloc.free(head);
        try out.appendSlice(alloc, head);
        try emit_cmds(alloc, &out, e.cmds);
        try out.appendSlice(alloc, "};\n");
    }

    try out.appendSlice(alloc, "\npub fn for_icon(ic: Icon) ?[]const Cmd {\n    return switch (ic) {\n");
    for (MAP) |m| {
        if (m.lucide.len == 0) continue;
        if (!has_name(entries.items, m.lucide)) continue;
        const arm = try std.fmt.allocPrint(alloc, "        .{s} => &@\"{s}\",\n", .{ m.icon, m.lucide });
        defer alloc.free(arm);
        try out.appendSlice(alloc, arm);
    }
    try out.appendSlice(alloc, "        else => null,\n    };\n}\n");

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = out.items });
    std.debug.print("wrote {s} ({d} bytes, {d} icons, {d} miss)\n", .{ out_path, out.items.len, entries.items.len, miss });
}

test "chained relative arcs close the loop (settings)" {
    // 12 alternating-sweep arcs that ring back to the start; a sign/flag slip in
    // the arc math drifts the endpoint and the gear never closes.
    const d = "M9.671 4.136a2.34 2.34 0 0 1 4.659 0 2.34 2.34 0 0 0 3.319 1.915 2.34 2.34 0 0 1 2.33 4.033 2.34 2.34 0 0 0 0 3.831 2.34 2.34 0 0 1-2.33 4.033 2.34 2.34 0 0 0-3.319 1.915 2.34 2.34 0 0 1-4.659 0 2.34 2.34 0 0 0-3.32-1.915 2.34 2.34 0 0 1-2.33-4.033 2.34 2.34 0 0 0 0-3.831A2.34 2.34 0 0 1 6.35 6.051a2.34 2.34 0 0 0 3.319-1.915";
    const cmds = try parse_path(std.testing.allocator, d);
    defer std.testing.allocator.free(cmds);
    try std.testing.expectEqual(@as(usize, 25), cmds.len); // move + 12 arcs * 2 cubics
    const last = cmds[cmds.len - 1].cubic;
    try std.testing.expect(@abs(last[4] - 9.671) < 0.05 and @abs(last[5] - 4.136) < 0.05);
}

test "polyline subset: chevron-down" {
    const cmds = try parse_path(std.testing.allocator, "m6 9 6 6 6-6");
    defer std.testing.allocator.free(cmds);
    try std.testing.expectEqual(@as(usize, 3), cmds.len);
    try std.testing.expectEqual(Cmd{ .move = .{ 6, 9 } }, cmds[0]);
    try std.testing.expectEqual(Cmd{ .line = .{ 12, 15 } }, cmds[1]);
    try std.testing.expectEqual(Cmd{ .line = .{ 18, 9 } }, cmds[2]);
}

test "check: absolute + implicit + relative l" {
    const cmds = try parse_path(std.testing.allocator, "M20 6 9 17l-5-5");
    defer std.testing.allocator.free(cmds);
    try std.testing.expectEqual(Cmd{ .move = .{ 20, 6 } }, cmds[0]);
    try std.testing.expectEqual(Cmd{ .line = .{ 9, 17 } }, cmds[1]);
    try std.testing.expectEqual(Cmd{ .line = .{ 4, 12 } }, cmds[2]);
}

test "plus: H and V" {
    const a = try parse_path(std.testing.allocator, "M5 12h14");
    defer std.testing.allocator.free(a);
    try std.testing.expectEqual(Cmd{ .line = .{ 19, 12 } }, a[1]);
    const b = try parse_path(std.testing.allocator, "M12 5v14");
    defer std.testing.allocator.free(b);
    try std.testing.expectEqual(Cmd{ .line = .{ 12, 19 } }, b[1]);
}

test "arc emits cubics, ends at target" {
    const cmds = try parse_path(std.testing.allocator, "M4 12a8 8 0 1 0 16 0");
    defer std.testing.allocator.free(cmds);
    try std.testing.expect(cmds.len >= 2);
    try std.testing.expectEqual(Cmd.move, std.meta.activeTag(cmds[0]));
    const last = cmds[cmds.len - 1];
    try std.testing.expectEqual(Cmd.cubic, std.meta.activeTag(last));
    // endpoint x = 4 + 16 = 20, y = 12
    try std.testing.expect(@abs(last.cubic[4] - 20) < 0.01 and @abs(last.cubic[5] - 12) < 0.01);
}
