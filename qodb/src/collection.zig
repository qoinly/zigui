// A typed collection: an in-memory set of struct T keyed by one field, with CRUD and
// the typed query iterator. Each record's variable bytes (its []const u8 fields) live in
// a per-record blob the collection owns (the codec encoding), so a record is self-
// contained and freed precisely on replace/remove - no arena that only grows. A record
// returned by get/query borrows that storage: it is valid until the next mutation.

const std = @import("std");
const codec = @import("codec.zig");

pub const Config = struct {
    key: []const u8, // the primary-key field name (unique per record)
};

pub const Error = error{Corrupt} || std.mem.Allocator.Error;

pub fn Collection(comptime T: type, comptime config: Config) type {
    const KeyType = @FieldType(T, config.key);
    const KeyMap = if (is_byte_slice(KeyType))
        std.StringHashMapUnmanaged(usize)
    else
        std.AutoHashMapUnmanaged(KeyType, usize);

    return struct {
        const Self = @This();

        gpa: std.mem.Allocator,
        records: std.ArrayListUnmanaged(T) = .empty, // slices point into the matching blob
        blobs: std.ArrayListUnmanaged([]u8) = .empty, // blobs[i] backs records[i]
        by_key: KeyMap = .empty, // key -> index in records

        pub fn init(gpa: std.mem.Allocator) Self {
            return .{ .gpa = gpa };
        }

        pub fn deinit(self: *Self) void {
            for (self.blobs.items) |b| self.gpa.free(b);
            self.records.deinit(self.gpa);
            self.blobs.deinit(self.gpa);
            self.by_key.deinit(self.gpa);
        }

        pub fn count(self: *const Self) usize {
            return self.records.items.len;
        }

        // All records, borrowing the collection's storage (valid until the next mutation).
        pub fn items(self: *const Self) []const T {
            return self.records.items;
        }

        // Insert `rec`, or replace the record with the same key. The record's bytes are
        // copied into a collection-owned blob, so `rec`'s own slices need not outlive this.
        pub fn upsert(self: *Self, rec: T) Error!void {
            const blob = try self.gpa.alloc(u8, codec.size_of(rec));
            errdefer self.gpa.free(blob);
            _ = codec.encode(rec, blob) catch unreachable; // sized exactly above
            try self.insert_blob(blob);
        }

        pub fn get(self: *const Self, key: KeyType) ?T {
            const i = self.by_key.get(key) orelse return null;
            std.debug.assert(i < self.records.items.len); // the map index never outruns records
            return self.records.items[i];
        }

        // Remove the record with `key`; returns whether one existed.
        pub fn remove(self: *Self, key: KeyType) bool {
            const i = self.by_key.get(key) orelse return false;
            std.debug.assert(i < self.records.items.len);
            _ = self.by_key.remove(key); // before the free: a string key is stored by reference
            self.gpa.free(self.blobs.items[i]);
            const last = self.records.items.len - 1;
            if (i != last) {
                self.records.items[i] = self.records.items[last];
                self.blobs.items[i] = self.blobs.items[last];
                // The moved key is already mapped (to `last`); updating it allocates nothing.
                self.by_key.putAssumeCapacity(key_of(self.records.items[i]), i);
            }
            _ = self.records.pop();
            _ = self.blobs.pop();
            std.debug.assert(self.records.items.len == self.blobs.items.len);
            return true;
        }

        // A lazy iterator over the records a predicate matches (a query.* predicate). The
        // match is monomorphized + inlined; this scans, so a point lookup should use get.
        // The iterator holds the records slice, so do not mutate the collection while it
        // is live (an upsert/remove can move the backing storage).
        pub fn query(self: *const Self, pred: anytype) Iterator(@TypeOf(pred)) {
            return .{ .recs = self.records.items, .pred = pred };
        }

        pub fn Iterator(comptime P: type) type {
            return struct {
                recs: []const T,
                pred: P,
                i: usize = 0,

                pub fn next(it: *@This()) ?T {
                    while (it.i < it.recs.len) {
                        const rec = it.recs[it.i];
                        it.i += 1;
                        if (it.pred.match(T, rec)) return rec;
                    }
                    return null;
                }
            };
        }

        // Takes ownership of `blob` (an encoded record); decodes + indexes it. `key`
        // points into the new blob; on a replace the old map entry (whose key points
        // into the old blob) is removed BEFORE the old blob is freed, then re-inserted
        // against the new blob's bytes - a string key must never dangle into a freed blob.
        fn insert_blob(self: *Self, blob: []u8) Error!void {
            const rec = codec.decode(T, blob) catch return error.Corrupt;
            const key = key_of(rec);
            std.debug.assert(self.records.items.len == self.blobs.items.len); // parallel arrays
            if (self.by_key.fetchRemove(key)) |old| {
                const i = old.value;
                self.gpa.free(self.blobs.items[i]);
                self.records.items[i] = rec;
                self.blobs.items[i] = blob;
                self.by_key.putAssumeCapacity(key, i); // fetchRemove freed the slot - no alloc
                return;
            }
            try self.records.append(self.gpa, rec);
            errdefer _ = self.records.pop();
            try self.blobs.append(self.gpa, blob);
            errdefer _ = self.blobs.pop();
            try self.by_key.put(self.gpa, key, self.records.items.len - 1);
            std.debug.assert(self.records.items.len == self.blobs.items.len);
        }

        fn key_of(rec: T) KeyType {
            return @field(rec, config.key);
        }

        // Persist the whole collection to `path` (relative to cwd): a u32 count then each
        // record's blob length-prefixed. Written to a temp file and renamed over `path`,
        // so a crash mid-write never leaves a torn file (the snapshot is all-or-nothing).
        pub fn save(self: *const Self, io: std.Io, path: []const u8) !void {
            var total: usize = @sizeOf(u32);
            for (self.blobs.items) |b| total += @sizeOf(u32) + b.len;
            const buf = try self.gpa.alloc(u8, total);
            defer self.gpa.free(buf);

            var n: usize = 0;
            write_u32(buf, &n, @intCast(self.records.items.len));
            for (self.blobs.items) |b| {
                write_u32(buf, &n, @intCast(b.len));
                @memcpy(buf[n..][0..b.len], b);
                n += b.len;
            }
            std.debug.assert(n == total);

            var tmp_buf: [4096]u8 = undefined;
            const tmp = try std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{path});
            const dir = std.Io.Dir.cwd();
            try dir.writeFile(io, .{ .sub_path = tmp, .data = buf });
            try std.Io.Dir.rename(dir, tmp, dir, path, io);
        }

        // Load the collection from `path` into an empty collection. A missing file is an
        // empty store (no error). Each record's blob is copied into collection-owned
        // memory, so the file buffer is freed after.
        pub fn load(self: *Self, io: std.Io, path: []const u8) !void {
            std.debug.assert(self.count() == 0);
            const data = std.Io.Dir.cwd().readFileAlloc(io, path, self.gpa, .unlimited) catch |e| {
                if (e == error.FileNotFound) return;
                return e;
            };
            defer self.gpa.free(data);

            var n: usize = 0;
            const records = try read_u32(data, &n);
            var k: usize = 0;
            while (k < records) : (k += 1) {
                const len = try read_u32(data, &n);
                if (n + len > data.len) return error.Corrupt;
                const blob = try self.gpa.dupe(u8, data[n..][0..len]);
                errdefer self.gpa.free(blob);
                n += len;
                try self.insert_blob(blob); // takes ownership on success; we free on error
            }
        }
    };
}

fn write_u32(buf: []u8, n: *usize, v: u32) void {
    @memcpy(buf[n.*..][0..4], std.mem.asBytes(&v));
    n.* += 4;
}

fn read_u32(data: []const u8, n: *usize) error{Corrupt}!u32 {
    if (n.* + 4 > data.len) return error.Corrupt;
    var v: u32 = undefined;
    @memcpy(std.mem.asBytes(&v), data[n.*..][0..4]);
    n.* += 4;
    return v;
}

fn is_byte_slice(comptime T: type) bool {
    const info = @typeInfo(T);
    return info == .pointer and info.pointer.size == .slice and info.pointer.child == u8;
}

const q = @import("query.zig");

test "crud with an integer key" {
    const User = struct { id: u64, age: u16, name: []const u8 };
    var users = Collection(User, .{ .key = "id" }).init(std.testing.allocator);
    defer users.deinit();

    try users.upsert(.{ .id = 1, .age = 20, .name = "ada" });
    try users.upsert(.{ .id = 2, .age = 30, .name = "bo" });
    try std.testing.expectEqual(@as(usize, 2), users.count());

    try std.testing.expectEqualStrings("ada", users.get(1).?.name);
    try users.upsert(.{ .id = 1, .age = 21, .name = "ada2" }); // replace
    try std.testing.expectEqual(@as(usize, 2), users.count());
    try std.testing.expectEqual(@as(u16, 21), users.get(1).?.age);
    try std.testing.expectEqualStrings("ada2", users.get(1).?.name);

    try std.testing.expect(users.remove(2));
    try std.testing.expect(!users.remove(2));
    try std.testing.expectEqual(@as(usize, 1), users.count());
    try std.testing.expectEqual(@as(?User, null), users.get(2));
}

test "query with a typed predicate" {
    const User = struct { id: u64, age: u16, country: []const u8 };
    var users = Collection(User, .{ .key = "id" }).init(std.testing.allocator);
    defer users.deinit();
    try users.upsert(.{ .id = 1, .age = 17, .country = "ID" });
    try users.upsert(.{ .id = 2, .age = 21, .country = "ID" });
    try users.upsert(.{ .id = 3, .age = 40, .country = "US" });

    var it = users.query(q.all(.{ q.gte("age", @as(u16, 18)), q.eq("country", "ID") }));
    var n: usize = 0;
    while (it.next()) |u| {
        try std.testing.expectEqual(@as(u64, 2), u.id);
        n += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), n);
}

test "string key, with replace and remove" {
    const Kv = struct { key: []const u8, value: i64 };
    var kvs = Collection(Kv, .{ .key = "key" }).init(std.testing.allocator);
    defer kvs.deinit();
    try kvs.upsert(.{ .key = "theme", .value = 1 });
    try kvs.upsert(.{ .key = "volume", .value = 7 });
    try std.testing.expectEqual(@as(i64, 7), kvs.get("volume").?.value);
    try kvs.upsert(.{ .key = "volume", .value = 3 }); // replace re-points the string key
    try std.testing.expectEqual(@as(i64, 3), kvs.get("volume").?.value);
    try std.testing.expectEqual(@as(usize, 2), kvs.count());
    try std.testing.expect(kvs.remove("theme")); // swap-removes; "volume" must still resolve
    try std.testing.expectEqual(@as(i64, 3), kvs.get("volume").?.value);
    try std.testing.expectEqual(@as(?Kv, null), kvs.get("theme"));
}

test "save and load roundtrips" {
    const User = struct { id: u64, age: u16, name: []const u8 };
    const C = Collection(User, .{ .key = "id" });
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const path = "qodb_store_test.bin";
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    {
        var c = C.init(std.testing.allocator);
        defer c.deinit();
        try c.upsert(.{ .id = 1, .age = 20, .name = "ada" });
        try c.upsert(.{ .id = 2, .age = 31, .name = "bjarne" });
        try c.save(io, path);
    }
    {
        var c = C.init(std.testing.allocator);
        defer c.deinit();
        try c.load(io, path);
        try std.testing.expectEqual(@as(usize, 2), c.count());
        try std.testing.expectEqual(@as(u16, 20), c.get(1).?.age);
        try std.testing.expectEqualStrings("bjarne", c.get(2).?.name);
    }
    {
        // A missing file loads as an empty store, not an error.
        var c = C.init(std.testing.allocator);
        defer c.deinit();
        try c.load(io, "qodb_does_not_exist.bin");
        try std.testing.expectEqual(@as(usize, 0), c.count());
    }
}
