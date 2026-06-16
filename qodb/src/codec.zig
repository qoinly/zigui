// The comptime binary codec: encode/decode any supported Zig value to a compact byte
// blob and back. Monomorphized per type (no runtime reflection), so a call compiles to
// straight-line field reads/writes - blazing fast without an interpreter.
//
// The wire layout is field-by-field in CANONICAL order - struct fields sorted by name,
// independent of both the declaration order and the compiler's in-memory layout: a scalar
// is its native bytes, a slice is a u32 length then its bytes, an optional is a present-
// byte then the value, a union is its tag then the active field. Sorting by name means
// reordering a struct's fields in source does not change the format (no migration needed);
// only adding, removing, renaming, or retyping a field does.
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

// Encode `value` into `out` AND return a copy of it whose []const u8 fields point into
// `out` instead of the caller's buffers - the result the collection stores after a write.
// One structural walk does both, replacing an encode followed by a decode of the same
// blob. `out` must be sized with size_of (NoSpace otherwise) and must outlive the result.
pub fn encode_inplace(comptime T: type, value: T, out: []u8) Error!T {
    var n: usize = 0;
    const v = try encode_inplace_value(T, value, out, &n);
    assert(n == size_of(value)); // the walk wrote exactly what size_of predicted
    return v;
}

// The encode walk, returning a re-pointed value. A scalar/bool/enum passes through; a
// slice is written and its stored view (a window into `out`) returned; structs, optionals,
// arrays, and unions rebuild from their re-pointed parts. Mirrors encode_value exactly so
// the bytes are identical - only the returned value differs (it borrows `out`).
fn encode_inplace_value(comptime T: type, value: T, out: []u8, n: *usize) Error!T {
    switch (@typeInfo(T)) {
        .void, .bool, .int, .float, .@"enum" => {
            try encode_value(T, value, out, n);
            return value;
        },
        .pointer => {
            const bytes = byte_slice(T, value);
            assert(bytes.len <= std.math.maxInt(u32)); // length is a u32 on the wire
            try encode_value(u32, @intCast(bytes.len), out, n);
            const at = n.*;
            try put(out, n, bytes);
            return out[at..][0..bytes.len]; // the stored slice borrows `out`
        },
        .optional => |o| {
            if (value) |inner| {
                try put(out, n, &[_]u8{1});
                return try encode_inplace_value(o.child, inner, out, n);
            }
            try put(out, n, &[_]u8{0});
            return null;
        },
        .array => |a| {
            var stored: T = undefined;
            for (value, &stored) |elem, *slot| {
                slot.* = try encode_inplace_value(a.child, elem, out, n);
            }
            return stored;
        },
        .@"struct" => |s| {
            var stored: T = value; // scalars copy through; slice fields get re-pointed below
            inline for (comptime field_order(T)) |fi| {
                const f = s.fields[fi];
                @field(stored, f.name) =
                    try encode_inplace_value(f.type, @field(value, f.name), out, n);
            }
            return stored;
        },
        .@"union" => return try encode_inplace_union(T, value, out, n),
        else => unsupported(T),
    }
}

// Encode a tagged union and return it with its active payload re-pointed into `out`, so a
// slice inside a union arm borrows the blob like every other field.
fn encode_inplace_union(comptime T: type, value: T, out: []u8, n: *usize) Error!T {
    const u = @typeInfo(T).@"union";
    const Tag = u.tag_type orelse unsupported(T);
    try encode_value(Tag, std.meta.activeTag(value), out, n);
    switch (value) {
        inline else => |payload, tag| {
            const stored = try encode_inplace_value(@TypeOf(payload), payload, out, n);
            return @unionInit(T, @tagName(tag), stored);
        },
    }
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
            inline for (comptime field_order(T)) |fi| {
                const f = s.fields[fi];
                n += size_of_value(f.type, @field(value, f.name));
            }
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
        .@"struct" => |s| inline for (comptime field_order(T)) |fi| {
            const f = s.fields[fi];
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
            inline for (comptime field_order(T)) |fi| {
                const f = s.fields[fi];
                @field(v, f.name) = try decode_value(f.type, bytes, n);
            }
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

// Field indices of T's struct in canonical (name-sorted) order - the wire order, so a
// source reordering leaves the format (and layout_hash) unchanged. Indices, not
// StructFields, since a StructField is comptime-only and cannot be returned by value.
fn field_order(comptime T: type) [@typeInfo(T).@"struct".fields.len]usize {
    return name_order(@typeInfo(T).@"struct".fields);
}

// Indices of `fields` (any field list carrying `.name`) sorted by name. Runs at comptime.
fn name_order(comptime fields: anytype) [fields.len]usize {
    var idx: [fields.len]usize = undefined;
    for (&idx, 0..) |*p, i| p.* = i;
    for (1..idx.len) |i| { // insertion sort, ascending by name
        const cur = idx[i];
        var j = i;
        while (j > 0 and std.mem.lessThan(u8, fields[cur].name, fields[idx[j - 1]].name)) {
            idx[j] = idx[j - 1];
            j -= 1;
        }
        idx[j] = cur;
    }
    return idx;
}

// Indices of enum `fields` sorted by tag value - the value is what the codec writes, so
// hashing in value order makes an enum arm reorder (with stable values) invisible, exactly
// as the wire is. Runs at comptime.
fn value_order(comptime fields: anytype) [fields.len]usize {
    var idx: [fields.len]usize = undefined;
    for (&idx, 0..) |*p, i| p.* = i;
    for (1..idx.len) |i| {
        const cur = idx[i];
        var j = i;
        while (j > 0 and fields[cur].value < fields[idx[j - 1]].value) : (j -= 1) {
            idx[j] = idx[j - 1];
        }
        idx[j] = cur;
    }
    return idx;
}

// A hash of T's wire shape: it changes exactly when the encoded format changes. It mirrors
// the codec's own order-independence - struct fields folded in name order, enum/union arms
// in tag-value order - so any pure source reorder leaves it unmoved; an added/removed/
// renamed/retyped field, or a changed enum/union arm value, moves it. A persisted record
// carries this, so a real shape change is caught on load rather than silently mis-decoded.
pub fn layout_hash(comptime T: type) u64 {
    return hash_shape(0xcbf29ce484222325, T);
}

fn hash_shape(acc: u64, comptime T: type) u64 {
    return switch (@typeInfo(T)) {
        .void => mix(acc, "v"),
        .bool => mix(acc, "b"),
        .int, .float => mix(acc, @typeName(T)),
        .pointer => mix(acc, "p"), // []const u8
        .@"enum" => |e| blk: {
            var h = mix(acc, "e");
            h = mix(h, @typeName(e.tag_type));
            inline for (comptime value_order(e.fields)) |fi| { // value order: reorder-invariant
                h = mix_int(mix(h, e.fields[fi].name), e.fields[fi].value);
            }
            break :blk h;
        },
        .@"struct" => |s| blk: {
            var h = mix(acc, "s");
            inline for (comptime field_order(T)) |fi| {
                const f = s.fields[fi];
                h = hash_shape(mix(h, f.name), f.type);
            }
            break :blk h;
        },
        .optional => |o| hash_shape(mix(acc, "o"), o.child),
        .array => |a| hash_shape(mix_int(mix(acc, "a"), a.len), a.child),
        .@"union" => |u| blk: {
            var h = mix(acc, "u");
            const tag = @typeInfo(u.tag_type orelse unsupported(T)).@"enum";
            inline for (comptime value_order(tag.fields)) |fi| { // tag value: what the wire holds
                h = mix_int(mix(h, tag.fields[fi].name), tag.fields[fi].value);
            }
            inline for (comptime name_order(u.fields)) |fi| { // payload decoded by name
                h = hash_shape(mix(h, u.fields[fi].name), u.fields[fi].type);
            }
            break :blk h;
        },
        else => unsupported(T),
    };
}

fn mix(acc: u64, comptime s: []const u8) u64 {
    var h = acc;
    for (s) |b| {
        h ^= b;
        h *%= 0x100000001b3;
    }
    return h;
}

fn mix_int(acc: u64, comptime v: i128) u64 {
    var h = acc;
    const u: u128 = @bitCast(v);
    inline for (0..16) |i| h = mix(h, &[_]u8{@truncate(u >> (i * 8))});
    return h;
}

fn unsupported(comptime T: type) noreturn {
    @compileError("qodb codec: unsupported type " ++ @typeName(T) ++
        " (supported: ints, floats, bools, enums, arrays, structs, optionals, tagged " ++
        "unions, and []const u8)");
}

fn put(out: []u8, n: *usize, bytes: []const u8) Error!void {
    assert(n.* <= out.len); // the cursor never passes the end
    if (bytes.len > out.len - n.*) return error.NoSpace; // subtract: `n + len` could overflow
    @memcpy(out[n.*..][0..bytes.len], bytes);
    n.* += bytes.len;
    assert(n.* <= out.len);
}

fn take(bytes: []const u8, n: *usize, len: usize) Error![]const u8 {
    assert(n.* <= bytes.len); // the cursor never passes the end
    if (len > bytes.len - n.*) return error.Corrupt; // subtract: `n + len` could overflow
    defer n.* += len;
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

test "wire order is canonical (by name), not declaration order" {
    // Same fields, different declaration order -> identical wire and identical layout_hash.
    const Abc = struct { a: u32, b: u8, c: u16 };
    const Cba = struct { c: u16, a: u32, b: u8 };
    var ba: [16]u8 = undefined;
    var bb: [16]u8 = undefined;
    const la = try encode(Abc{ .a = 0x11223344, .b = 0xAB, .c = 0xBEEF }, &ba);
    const lb = try encode(Cba{ .a = 0x11223344, .b = 0xAB, .c = 0xBEEF }, &bb);
    try std.testing.expectEqualSlices(u8, ba[0..la], bb[0..lb]);
    // Canonical order a,b,c: a (4) then b (1) then c (2).
    const want = [_]u8{ 0x44, 0x33, 0x22, 0x11, 0xAB, 0xEF, 0xBE };
    try std.testing.expectEqualSlices(u8, &want, ba[0..la]);
    try std.testing.expectEqual(layout_hash(Abc), layout_hash(Cba));
}

test "layout_hash changes on a real shape change, not on a reorder" {
    const V1 = struct { id: u64, name: []const u8 };
    const Reordered = struct { name: []const u8, id: u64 };
    const Added = struct { id: u64, name: []const u8, age: u16 };
    const Retyped = struct { id: u32, name: []const u8 };
    try std.testing.expectEqual(layout_hash(V1), layout_hash(Reordered)); // reorder: same
    try std.testing.expect(layout_hash(V1) != layout_hash(Added)); // add field: differs
    try std.testing.expect(layout_hash(V1) != layout_hash(Retyped)); // retype: differs

    // An enum arm reorder with stable values is invisible (the wire holds the value); a
    // changed arm value is not.
    const Same = struct { r: enum(u8) { a = 1, b = 2 } };
    const ArmReorder = struct { r: enum(u8) { b = 2, a = 1 } };
    const ArmRevalue = struct { r: enum(u8) { a = 9, b = 2 } };
    try std.testing.expectEqual(layout_hash(Same), layout_hash(ArmReorder));
    try std.testing.expect(layout_hash(Same) != layout_hash(ArmRevalue));
}

test "encode_inplace writes identical bytes and re-points slices into out" {
    const Tag = union(enum) { none, label: []const u8 };
    const Rec = struct {
        id: u64,
        name: []const u8,
        nick: ?[]const u8,
        tag: Tag,
    };
    var src_name = [_]u8{ 'a', 'd', 'a' };
    var src_nick = [_]u8{ 'x', 'y' };
    var src_label = [_]u8{ 'h', 'i' };
    const r = Rec{
        .id = 7,
        .name = &src_name,
        .nick = &src_nick,
        .tag = .{ .label = &src_label },
    };

    var plain: [64]u8 = undefined;
    var inplace: [64]u8 = undefined;
    const lp = try encode(r, &plain);
    const stored = try encode_inplace(Rec, r, &inplace); // also fills `inplace`
    try std.testing.expectEqualSlices(u8, plain[0..lp], inplace[0..lp]);

    // The stored value equals the input by content but borrows `inplace`, not the sources.
    try std.testing.expectEqual(@as(u64, 7), stored.id);
    try std.testing.expectEqualStrings("ada", stored.name);
    try std.testing.expectEqualStrings("xy", stored.nick.?);
    try std.testing.expectEqualStrings("hi", stored.tag.label);
    const base = @intFromPtr(&inplace);
    const end = base + inplace.len;
    inline for (.{ stored.name.ptr, stored.nick.?.ptr, stored.tag.label.ptr }) |p| {
        const a = @intFromPtr(p);
        try std.testing.expect(a >= base and a < end); // points into `out`, not the sources
    }
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
