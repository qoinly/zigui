// qodb microbenchmarks: throughput of the core operations and the live memory footprint.
// Build with -Doptimize=ReleaseFast for representative numbers. Not part of the shipped
// package (excluded from build.zig.zon paths).

const std = @import("std");
const qodb = @import("qodb");

// An allocator that forwards to a backing one while tracking live and peak bytes, so the
// benchmark can report the actual memory a populated store holds.
const Counting = struct {
    backing: std.mem.Allocator,
    live: usize = 0,
    peak: usize = 0,

    fn allocator(self: *Counting) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn bump(self: *Counting, add: usize, sub: usize) void {
        self.live = self.live + add - sub;
        if (self.live > self.peak) self.peak = self.live;
    }
    fn alloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        const p = self.backing.vtable.alloc(self.backing.ptr, len, a, ra) orelse return null;
        self.bump(len, 0);
        return p;
    }
    fn resize(ctx: *anyopaque, mem: []u8, a: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        if (!self.backing.vtable.resize(self.backing.ptr, mem, a, new_len, ra)) return false;
        self.bump(new_len, mem.len);
        return true;
    }
    fn remap(ctx: *anyopaque, mem: []u8, a: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        const p = self.backing.vtable.remap(self.backing.ptr, mem, a, new_len, ra) orelse return null;
        self.bump(new_len, mem.len);
        return p;
    }
    fn free(ctx: *anyopaque, mem: []u8, a: std.mem.Alignment, ra: usize) void {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        self.backing.vtable.free(self.backing.ptr, mem, a, ra);
        self.live -= mem.len;
    }
};

const User = struct {
    id: u64,
    age: u16,
    name: []const u8,
    email: []const u8,
    country: []const u8,
};

const countries = [_][]const u8{ "ID", "MY", "SG", "US", "JP", "DE", "BR", "IN" };

fn nowns(io: std.Io) i96 {
    return std.Io.Timestamp.now(io, .awake).nanoseconds;
}
fn since(io: std.Io, t0: i96) u64 {
    return @intCast(nowns(io) - t0);
}

fn row(label: []const u8, ops: usize, ns: u64) void {
    const per = @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(ops));
    const mops = @as(f64, @floatFromInt(ops)) / (@as(f64, @floatFromInt(ns)) / 1e9) / 1e6;
    std.debug.print("{s:<26} {d:>10} ops  {d:>8.1} ns/op  {d:>7.2} M/s  ({d:.1} ms)\n", .{
        label, ops, per, mops, @as(f64, @floatFromInt(ns)) / 1e6,
    });
}

pub fn main() !void {
    const N: usize = 200_000;

    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    var counting = Counting{ .backing = gpa_state.allocator() };
    const gpa = counting.allocator();

    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var prng = std.Random.DefaultPrng.init(0x9e3779b97f4a7c15);
    const rng = prng.random();
    var t0: i96 = 0;
    var sink: u64 = 0;

    std.debug.print("qodb benchmark - {d} records, mode {s}\n\n", .{ N, @tagName(@import("builtin").mode) });

    const Users = qodb.Collection(User, .{ .key = "id", .indexes = &.{"country"} });
    var users = Users.init(gpa);
    defer users.deinit();

    // upsert
    try users.ensure_capacity(N); // pre-size: the count is known up front
    var name_buf: [32]u8 = undefined;
    var email_buf: [32]u8 = undefined;
    t0 = nowns(io);
    for (0..N) |i| {
        const name = std.fmt.bufPrint(&name_buf, "user-{d}", .{i}) catch unreachable;
        const email = std.fmt.bufPrint(&email_buf, "u{d}@example.io", .{i}) catch unreachable;
        try users.upsert(.{
            .id = i,
            .age = @intCast(rng.intRangeAtMost(u8, 0, 99)),
            .name = name,
            .email = email,
            .country = countries[rng.intRangeLessThan(usize, 0, countries.len)],
        });
    }
    row("upsert (insert)", N, since(io, t0));
    const peak_after_insert = counting.peak;

    // get by primary key (random)
    t0 = nowns(io);
    for (0..N) |_| {
        const id = rng.intRangeLessThan(u64, 0, N);
        if (users.get(id)) |u| sink +%= u.age;
    }
    row("get (point lookup)", N, since(io, t0));

    // find_by an indexed field
    var matched: usize = 0;
    t0 = nowns(io);
    for (0..1000) |_| {
        const c = countries[rng.intRangeLessThan(usize, 0, countries.len)];
        var it = users.find_by("country", c);
        while (it.next()) |u| {
            sink +%= u.id;
            matched += 1;
        }
    }
    row("find_by (indexed, 1k runs)", matched, since(io, t0));

    // full scan predicate
    var scanned: usize = 0;
    t0 = nowns(io);
    for (0..10) |_| {
        var it = users.query(qodb.query.gte("age", @as(u16, 50)));
        while (it.next()) |u| {
            sink +%= u.id;
            scanned += 1;
        }
    }
    row("query scan (10 runs)", scanned, since(io, t0));

    // index-seeded predicate
    var seeded: usize = 0;
    t0 = nowns(io);
    for (0..1000) |_| {
        const c = countries[rng.intRangeLessThan(usize, 0, countries.len)];
        var it = users.query(qodb.query.all(.{
            qodb.query.eq("country", c),
            qodb.query.gte("age", @as(u16, 18)),
        }));
        while (it.next()) |u| {
            sink +%= u.id;
            seeded += 1;
        }
    }
    row("query seeded (indexed eq)", seeded, since(io, t0));

    // serialize the whole snapshot
    t0 = nowns(io);
    const image = try users.serialize();
    const ser_ns = since(io, t0);
    defer gpa.free(image);
    row("serialize snapshot", N, ser_ns);

    // save to disk + load back
    const path = "qodb_bench.tmp";
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    t0 = nowns(io);
    try users.save(io, path);
    row("save to disk", N, since(io, t0));

    {
        var loaded = Users.init(gpa);
        defer loaded.deinit();
        t0 = nowns(io);
        try loaded.load(io, path);
        row("load from disk (+ reindex)", N, since(io, t0));
        sink +%= loaded.count();
    }

    // encryption: AES-256-GCM seal/open of the snapshot (envelope, software KEK)
    const SoftKek = struct {
        master: [32]u8,
        io: std.Io,
        fn wrap(ctx: *anyopaque, dek: *const [32]u8, out: []u8) qodb.secure.Error!usize {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            var iv: [12]u8 = undefined;
            try self.io.randomSecure(&iv);
            @memcpy(out[0..12], &iv);
            std.crypto.aead.aes_gcm.Aes256Gcm.encrypt(out[12..][0..32], out[44..][0..16], dek, "", iv, self.master);
            return 60;
        }
        fn unwrap(ctx: *anyopaque, w: []const u8, dek: *[32]u8) qodb.secure.Error!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            const tag = w[44..][0..16].*;
            std.crypto.aead.aes_gcm.Aes256Gcm.decrypt(dek, w[12..][0..32], tag, "", w[0..12].*, self.master) catch return error.BadKey;
        }
        fn nope(_: *anyopaque, _: std.mem.Allocator, _: []const u8) qodb.secure.Error![]u8 {
            return error.Corrupt;
        }
        fn provider(self: *@This()) qodb.secure.KeyProvider {
            return .{ .ctx = self, .vtable = &.{ .wrap = wrap, .unwrap = unwrap, .seal = nope, .open = nope } };
        }
    };
    var kek = SoftKek{ .master = @splat(7), .io = io };
    const env = qodb.secure.Security{ .envelope = kek.provider() };
    t0 = nowns(io);
    const sealed = try qodb.secure.seal(gpa, io, image, env);
    row("encrypt snapshot (envelope)", N, since(io, t0));
    defer gpa.free(sealed);
    t0 = nowns(io);
    const opened = try qodb.secure.open(gpa, sealed, env);
    row("decrypt snapshot (envelope)", N, since(io, t0));
    defer gpa.free(opened);

    // password mode: the Argon2id derivation cost (once per session)
    var salt: [qodb.secure.salt_len]u8 = undefined;
    try io.randomSecure(&salt);
    t0 = nowns(io);
    const key = try qodb.secure.derive(gpa, io, "a-strong-passphrase", salt, .{});
    std.debug.print("{s:<26} {d:>8.1} ms  (once per open, default params)\n", .{
        "argon2id derive", @as(f64, @floatFromInt(since(io, t0))) / 1e6,
    });
    sink +%= key[0];

    std.debug.print("\nsnapshot size: {d:.2} MB ({d} bytes/record)\n", .{
        @as(f64, @floatFromInt(image.len)) / (1 << 20), image.len / N,
    });
    std.debug.print("live memory:   {d:.2} MB peak ({d} bytes/record)\n", .{
        @as(f64, @floatFromInt(peak_after_insert)) / (1 << 20), peak_after_insert / N,
    });
    std.debug.print("(sink {d})\n", .{sink});
}
