// The typed query DSL. A predicate is a comptime-composed value with a
// `match(comptime T, rec)` method; the field name is comptime (compile-checked against
// T), the operand is a runtime value whose type must match the field. Because the whole
// predicate tree is comptime, `match` monomorphizes to straight-line inlined comparisons
// - no SQL string, no parser, no runtime predicate interpreter. A leaf that names a
// field T lacks, or an operand whose type the field can't compare to, is a compile error.
//
//   q.all(.{ q.gte("age", 18), q.any(.{ q.eq("country", "ID"), q.eq("country", "MY") }) })
//
// Execution (the lazy iterator) lives in the collection; this file is just the predicate
// values and their match.

const std = @import("std");

const Op = enum { eq, ne, lt, lte, gt, gte, in, between, contains, starts_with };

// --- leaf comparisons (field <op> operand) ---

pub fn eq(comptime field: []const u8, operand: anytype) Cmp(field, .eq, @TypeOf(operand)) {
    return .{ .operand = operand };
}
pub fn ne(comptime field: []const u8, operand: anytype) Cmp(field, .ne, @TypeOf(operand)) {
    return .{ .operand = operand };
}
pub fn lt(comptime field: []const u8, operand: anytype) Cmp(field, .lt, @TypeOf(operand)) {
    return .{ .operand = operand };
}
pub fn lte(comptime field: []const u8, operand: anytype) Cmp(field, .lte, @TypeOf(operand)) {
    return .{ .operand = operand };
}
pub fn gt(comptime field: []const u8, operand: anytype) Cmp(field, .gt, @TypeOf(operand)) {
    return .{ .operand = operand };
}
pub fn gte(comptime field: []const u8, operand: anytype) Cmp(field, .gte, @TypeOf(operand)) {
    return .{ .operand = operand };
}
// field value is one of `operand` (a slice/array of the field type).
pub fn in(comptime field: []const u8, operand: anytype) Cmp(field, .in, @TypeOf(operand)) {
    return .{ .operand = operand };
}
// lo <= field <= hi.
pub fn between(
    comptime field: []const u8,
    lo: anytype,
    hi: anytype,
) Cmp(field, .between, Range(@TypeOf(lo))) {
    return .{ .operand = .{ .lo = lo, .hi = hi } };
}
// []const u8 field contains / starts with the operand bytes.
pub fn contains(comptime field: []const u8, operand: []const u8) Cmp(field, .contains, []const u8) {
    return .{ .operand = operand };
}
pub fn starts_with(
    comptime field: []const u8,
    operand: []const u8,
) Cmp(field, .starts_with, []const u8) {
    return .{ .operand = operand };
}

pub fn Range(comptime V: type) type {
    return struct { lo: V, hi: V };
}

fn Cmp(comptime field: []const u8, comptime op: Op, comptime Operand: type) type {
    return struct {
        operand: Operand,
        // Planner markers: a collection inspects these at comptime to seed from an index.
        pub const qodb_field: []const u8 = field;
        pub const qodb_op: Op = op;
        pub fn match(self: @This(), comptime T: type, rec: T) bool {
            return apply(op, @field(rec, field), self.operand);
        }
    };
}

// --- combinators ---

// True when every predicate in the tuple matches (AND).
pub fn all(preds: anytype) Junction(@TypeOf(preds), .all) {
    return .{ .preds = preds };
}
// True when any predicate in the tuple matches (OR).
pub fn any(preds: anytype) Junction(@TypeOf(preds), .any) {
    return .{ .preds = preds };
}
pub fn not(pred: anytype) Not(@TypeOf(pred)) {
    return .{ .pred = pred };
}

fn Junction(comptime Preds: type, comptime kind: enum { all, any }) type {
    return struct {
        preds: Preds,
        // Planner markers: a top-level `all` lets a collection seed from an indexed member.
        pub const qodb_kind = kind;
        pub const qodb_preds = Preds;
        pub fn match(self: @This(), comptime T: type, rec: T) bool {
            inline for (self.preds) |p| {
                const m = p.match(T, rec);
                if (kind == .all and !m) return false;
                if (kind == .any and m) return true;
            }
            return kind == .all; // all: none failed -> true; any: none matched -> false
        }
    };
}

fn Not(comptime P: type) type {
    return struct {
        pred: P,
        pub fn match(self: @This(), comptime T: type, rec: T) bool {
            return !self.pred.match(T, rec);
        }
    };
}

// --- comparison primitives (comptime-dispatched on the field type) ---

fn apply(comptime op: Op, field_value: anytype, operand: anytype) bool {
    return switch (op) {
        .eq => equal(field_value, operand),
        .ne => !equal(field_value, operand),
        .lt => less(field_value, operand),
        .lte => !less(operand, field_value),
        .gt => less(operand, field_value),
        .gte => !less(field_value, operand),
        .in => blk: {
            for (operand) |o| if (equal(field_value, o)) break :blk true;
            break :blk false;
        },
        .between => !less(field_value, operand.lo) and !less(operand.hi, field_value),
        .contains => std.mem.indexOf(u8, field_value, operand) != null,
        .starts_with => std.mem.startsWith(u8, field_value, operand),
    };
}

fn equal(a: anytype, b: anytype) bool {
    if (comptime is_byte_slice(@TypeOf(a))) return std.mem.eql(u8, a, b);
    return a == b;
}

fn less(a: anytype, b: anytype) bool {
    if (comptime is_byte_slice(@TypeOf(a))) return std.mem.order(u8, a, b) == .lt;
    return a < b; // ints / floats; an unordered field type (enum/bool) is a compile error
}

fn is_byte_slice(comptime T: type) bool {
    const info = @typeInfo(T);
    return info == .pointer and info.pointer.size == .slice and info.pointer.child == u8;
}

test "leaf comparisons over a struct" {
    const Role = enum { user, admin };
    const User = struct { age: u16, name: []const u8, role: Role, score: f32 };
    const u = User{ .age = 21, .name = "ada", .role = .admin, .score = 9.5 };

    try std.testing.expect(eq("age", @as(u16, 21)).match(User, u));
    try std.testing.expect(!eq("age", @as(u16, 22)).match(User, u));
    try std.testing.expect(gte("age", @as(u16, 18)).match(User, u));
    try std.testing.expect(lt("age", @as(u16, 30)).match(User, u));
    try std.testing.expect(eq("name", "ada").match(User, u));
    try std.testing.expect(starts_with("name", "ad").match(User, u));
    try std.testing.expect(contains("name", "d").match(User, u));
    try std.testing.expect(eq("role", Role.admin).match(User, u));
    try std.testing.expect(gt("score", @as(f32, 9.0)).match(User, u));
    try std.testing.expect(between("age", @as(u16, 18), @as(u16, 25)).match(User, u));
    try std.testing.expect(in("age", &[_]u16{ 10, 21, 30 }).match(User, u));
    try std.testing.expect(!in("age", &[_]u16{ 10, 30 }).match(User, u));
}

test "combinators compose" {
    const User = struct { age: u16, country: []const u8 };
    const u = User{ .age = 21, .country = "ID" };

    const pred = all(.{
        gte("age", @as(u16, 18)),
        any(.{ eq("country", "ID"), eq("country", "MY") }),
    });
    try std.testing.expect(pred.match(User, u));

    try std.testing.expect(not(eq("country", "US")).match(User, u));
    try std.testing.expect(!all(.{ gte("age", @as(u16, 18)), eq("country", "US") }).match(User, u));
    try std.testing.expect(any(.{ eq("country", "US"), gte("age", @as(u16, 18)) }).match(User, u));
}
