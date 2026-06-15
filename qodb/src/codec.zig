// The comptime binary codec: encode/decode any supported Zig value to a compact byte
// blob and back. Monomorphized per type (no runtime reflection), so a call compiles to
// straight-line field reads/writes - blazing fast without an interpreter.
//
// The wire layout is field-by-field in DECLARATION order (not the struct's in-memory
// layout, which the compiler may reorder/pad): a scalar is its native bytes, a slice is
// a u32 length then its bytes, an optional is a present-byte then the value, a union is
// its tag then the active field. Declaration order keeps the format stable across
// compiler layout changes, which a persistent store needs.
//
// Native scalar width + native endianness: qodb is a local, per-device store, so a
// value is always read back on the arch that wrote it - no byte-swapping. Decode is
// zero-copy for []const u8: the returned slice borrows the input blob, so the blob must
// outlive the decoded value (a borrowed view, not a copy).

const std = @import("std");
const assert = std.debug.assert;

pub const Error = error{ NoSpace, Corrupt };

// The exact encoded size of `value`, so a caller can size the output buffer.
pub fn size_of(value: anytype) usize {
    return size_of_value(@TypeOf(value), value);
}

// Encode `value` into `out`, returning the byte count. NoSpace if `out` is too small
// (size it with size_of first).
pub fn encode(value: anytype, out: []u8) Error!usize {
    var n: usize = 0;
    try encode_value(@TypeOf(value), value, out, &n);
    assert(n == size_of(value)); // the walk wrote exactly what size_of predicted
    return n;
}

// Decode a T from `bytes`. The result's []const u8 fields point into `bytes` (zero
// copy), so `bytes` must outlive the result. Corrupt if `bytes` is short or malformed.
pub fn decode(comptime T: type, bytes: []const u8) Error!T {
    var n: usize = 0;
    const v = try decode_value(T, bytes, &n);
    assert(n <= bytes.len);
    return v;
}

fn size_of_value(comptime T: type, value: T) usize {
    return switch (@typeInfo(T)) {
        .void => 0,
        .bool => 1,
        .int, .float => @sizeOf(T),
        .@"enum" => |e| @sizeOf(e.tag_type),
        .array => |a| blk: {
            var n: usize = 0;
            for (value) |elem| n += size_of_value(a.child, elem);
            break :blk n;
        },
        .@"struct" => |s| blk: {
            var n: usize = 0;
            inline for (s.fields) |f| n += size_of_value(f.type, @field(value, f.name));
            break :blk n;
        },
        .optional => |o| if (value) |v| 1 + size_of_value(o.child, v) else 1,
        .pointer => byte_slice(T, value).len + @sizeOf(u32),
        .@"union" => union_size(T, value),
        else => unsupported(T),
    };
}

fn union_size(comptime T: type, value: T) usize {
    const u = @typeInfo(T).@"union";
    const Tag = u.tag_type orelse unsupported(T);
    var n: usize = @sizeOf(Tag);
    switch (value) {
        inline else => |payload| n += size_of_value(@TypeOf(payload), payload),
    }
    return n;
}

fn encode_value(comptime T: type, value: T, out: []u8, n: *usize) Error!void {
    switch (@typeInfo(T)) {
        .void => {},
        .bool => try put(out, n, &[_]u8{@intFromBool(value)}),
        .int, .float => try put(out, n, std.mem.asBytes(&value)),
        .@"enum" => |e| try encode_value(e.tag_type, @intFromEnum(value), out, n),
        .array => |a| for (value) |elem| try encode_value(a.child, elem, out, n),
        .@"struct" => |s| inline for (s.fields) |f| {
            try encode_value(f.type, @field(value, f.name), out, n);
        },
        .optional => |o| {
            if (value) |v| {
                try put(out, n, &[_]u8{1});
                try encode_value(o.child, v, out, n);
            } else try put(out, n, &[_]u8{0});
        },
        .pointer => {
            const bytes = byte_slice(T, value);
            assert(bytes.len <= std.math.maxInt(u32)); // length is a u32 on the wire
            try encode_value(u32, @intCast(bytes.len), out, n);
            try put(out, n, bytes);
        },
        .@"union" => try encode_union(T, value, out, n),
        else => unsupported(T),
    }
}

fn encode_union(comptime T: type, value: T, out: []u8, n: *usize) Error!void {
    const u = @typeInfo(T).@"union";
    const Tag = u.tag_type orelse unsupported(T);
    try encode_value(Tag, std.meta.activeTag(value), out, n);
    switch (value) {
        inline else => |payload| try encode_value(@TypeOf(payload), payload, out, n),
    }
}

fn decode_value(comptime T: type, bytes: []const u8, n: *usize) Error!T {
    switch (@typeInfo(T)) {
        .void => return {},
        .bool => return (try take(bytes, n, 1))[0] != 0,
        .int, .float => {
            var v: T = undefined;
            @memcpy(std.mem.asBytes(&v), try take(bytes, n, @sizeOf(T)));
            return v;
        },
        .@"enum" => |e| {
            const tag = try decode_value(e.tag_type, bytes, n);
            if (!e.is_exhaustive) return @enumFromInt(tag);
            inline for (e.fields) |f| {
                if (tag == f.value) return @enumFromInt(tag);
            }
            return error.Corrupt; // a tag no named value matches (corrupt blob)
        },
        .array => |a| {
            var out: T = undefined;
            for (&out) |*elem| elem.* = try decode_value(a.child, bytes, n);
            return out;
        },
        .@"struct" => |s| {
            var v: T = undefined;
            inline for (s.fields) |f| @field(v, f.name) = try decode_value(f.type, bytes, n);
            return v;
        },
        .optional => |o| {
            if ((try take(bytes, n, 1))[0] == 0) return null;
            return try decode_value(o.child, bytes, n);
        },
        .pointer => {
            check_byte_slice(T); // []const u8 only - a decoded slice borrows the const blob
            const len = try decode_value(u32, bytes, n);
            return try take(bytes, n, len);
        },
        .@"union" => return decode_union(T, bytes, n),
        else => unsupported(T),
    }
}

fn decode_union(comptime T: type, bytes: []const u8, n: *usize) Error!T {
    const u = @typeInfo(T).@"union";
    const Tag = u.tag_type orelse unsupported(T);
    const tag = try decode_value(Tag, bytes, n);
    inline for (u.fields) |f| {
        if (tag == @field(Tag, f.name)) {
            return @unionInit(T, f.name, try decode_value(f.type, bytes, n));
        }
    }
    return error.Corrupt;
}

// Only []const u8 slices serialize (a length-prefixed byte run); other pointers do not
// serialize meaningfully, and a mutable []u8 cannot be decoded zero-copy from a const
// blob. A non-conforming pointer is a compile error with a clear message.
fn check_byte_slice(comptime T: type) void {
    const p = @typeInfo(T).pointer;
    if (p.size != .slice or p.child != u8 or !p.is_const) unsupported(T);
}

fn byte_slice(comptime T: type, value: T) []const u8 {
    check_byte_slice(T);
    return value;
}

fn unsupported(comptime T: type) noreturn {
    @compileError("qodb codec: unsupported type " ++ @typeName(T) ++
        " (supported: ints, floats, bools, enums, arrays, structs, optionals, tagged " ++
        "unions, and []const u8)");
}

fn put(out: []u8, n: *usize, bytes: []const u8) Error!void {
    if (n.* + bytes.len > out.len) return error.NoSpace;
    @memcpy(out[n.*..][0..bytes.len], bytes);
    n.* += bytes.len;
    assert(n.* <= out.len);
}

fn take(bytes: []const u8, n: *usize, len: usize) Error![]const u8 {
    if (n.* + len > bytes.len) return error.Corrupt;
    defer n.* += len;
    assert(n.* + len <= bytes.len);
    return bytes[n.*..][0..len];
}

test "roundtrip a mixed struct" {
    const Role = enum(u8) { user, admin };
    const Account = struct {
        id: u64,
        age: u16,
        active: bool,
        role: Role,
        name: []const u8,
        nickname: ?[]const u8,
        scores: [3]i32,
    };
    const a = Account{
        .id = 42,
        .age = 21,
        .active = true,
        .role = .admin,
        .name = "ada",
        .nickname = null,
        .scores = .{ -1, 0, 7 },
    };

    var buf: [256]u8 = undefined;
    const len = try encode(a, &buf);
    try std.testing.expectEqual(size_of(a), len);

    const b = try decode(Account, buf[0..len]);
    try std.testing.expectEqual(a.id, b.id);
    try std.testing.expectEqual(a.age, b.age);
    try std.testing.expectEqual(a.active, b.active);
    try std.testing.expectEqual(a.role, b.role);
    try std.testing.expectEqualStrings(a.name, b.name);
    try std.testing.expectEqual(@as(?[]const u8, null), b.nickname);
    try std.testing.expectEqualSlices(i32, &a.scores, &b.scores);
}

test "declaration-order layout is layout-independent" {
    // Fields the compiler would reorder in memory; the wire stays declaration order.
    const Reorder = struct { a: u32, b: u8, c: u8, d: u16 };
    const r = Reorder{ .a = 0x11223344, .b = 0xAB, .c = 0xCD, .d = 0xBEEF };
    var buf: [16]u8 = undefined;
    const len = try encode(r, &buf);
    try std.testing.expectEqual(@as(usize, 8), len);
    // a (4) then b (1) then c (1) then d (2), in declaration order.
    const want = [_]u8{ 0x44, 0x33, 0x22, 0x11, 0xAB, 0xCD, 0xEF, 0xBE };
    try std.testing.expectEqualSlices(u8, &want, buf[0..len]);
    try std.testing.expectEqual(r, try decode(Reorder, buf[0..len]));
}

test "void union arm, optional, and short-buffer errors" {
    const Event = union(enum) { tick, value: struct { w: u16, h: u16 } };
    const Wrap = struct { tag: ?u8, ev: Event };

    var buf: [64]u8 = undefined;
    inline for (.{
        Wrap{ .tag = 9, .ev = .{ .value = .{ .w = 4, .h = 5 } } },
        Wrap{ .tag = null, .ev = .tick }, // the void arm encodes the tag only
    }) |w| {
        const len = try encode(w, &buf);
        const got = try decode(Wrap, buf[0..len]);
        try std.testing.expectEqual(w.tag, got.tag);
        try std.testing.expectEqual(std.meta.activeTag(w.ev), std.meta.activeTag(got.ev));
    }

    var tiny: [1]u8 = undefined;
    try std.testing.expectError(error.NoSpace, encode(Wrap{ .tag = 1, .ev = .tick }, &tiny));
    try std.testing.expectError(error.Corrupt, decode(Wrap, &.{}));
}
