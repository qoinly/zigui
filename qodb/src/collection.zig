// A typed collection: an in-memory set of struct T keyed by one field, with CRUD and
// the typed query iterator. Each record's variable bytes (its []const u8 fields) live in
// a per-record blob the collection owns (the codec encoding), so a record is self-
// contained and freed precisely on replace/remove - no arena that only grows. A record
// returned by get/query borrows that storage: it is valid until the next mutation.

const std = @import("std");
const codec = @import("codec.zig");

pub const Config = struct {
    key: []const u8, // the primary-key field name (unique per record)
    indexes: []const []const u8 = &.{}, // secondary-index field names (value -> positions)
};

pub const Error = error{ Corrupt, SchemaMismatch } || std.mem.Allocator.Error;

pub fn Collection(comptime T: type, comptime config: Config) type {
    const KeyType = @FieldType(T, config.key);
    const KeyMap = if (is_byte_slice(KeyType))
        std.StringHashMapUnmanaged(usize)
    else
        std.AutoHashMapUnmanaged(KeyType, usize);

    const IndexSet = blk: {
        var types: [config.indexes.len]type = undefined;
        for (config.indexes, 0..) |fname, i| types[i] = FieldIndex(T, fname);
        break :blk std.meta.Tuple(&types);
    };

    // The migration chain (a tuple of `fn(OldShape) NewShape`), declared on the record
    // type as `pub const qodb_migrations`. Oldest first; the last returns the current T.
    // The engine validates the chain links and ends at T (compile error otherwise); a
    // collection with none simply rejects a changed layout on load.
    const migrations = if (@hasDecl(T, "qodb_migrations")) T.qodb_migrations else .{};
    comptime validate_migrations(T, migrations);

    return struct {
        const Self = @This();
        pub const Record = T; // the struct this collection stores (for schema introspection)
        pub const key_field = config.key;

        gpa: std.mem.Allocator,
        records: std.ArrayListUnmanaged(T) = .empty, // slices point into the matching blob
        blobs: std.ArrayListUnmanaged([]u8) = .empty, // blobs[i] backs records[i]
        by_key: KeyMap = .empty, // key -> index in records
        indexes: IndexSet = undefined, // one FieldIndex per config.indexes; set in init
        revision: u64 = 0, // bumped on each mutation; a database derives dirtiness from it

        pub fn init(gpa: std.mem.Allocator) Self {
            var self: Self = .{ .gpa = gpa };
            inline for (0..config.indexes.len) |k| self.indexes[k] = .{};
            return self;
        }

        pub fn deinit(self: *Self) void {
            for (self.blobs.items) |b| self.gpa.free(b);
            self.records.deinit(self.gpa);
            self.blobs.deinit(self.gpa);
            self.by_key.deinit(self.gpa);
            inline for (0..config.indexes.len) |k| self.indexes[k].deinit(self.gpa);
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
            self.revision +%= 1;
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
            // Unindex while the blob is alive (a []const u8 value is read from it).
            const rec_i = self.records.items[i];
            inline for (config.indexes, 0..) |fname, k| {
                self.indexes[k].drop(self.gpa, @field(rec_i, fname), i);
            }
            _ = self.by_key.remove(key); // before the free: a string key is stored by reference
            self.gpa.free(self.blobs.items[i]);
            const last = self.records.items.len - 1;
            if (i != last) {
                const moved = self.records.items[last];
                self.records.items[i] = moved;
                self.blobs.items[i] = self.blobs.items[last];
                // The moved key is already mapped (to `last`); updating it allocates nothing.
                self.by_key.putAssumeCapacity(key_of(moved), i);
                // The moved record's index postings pointed at `last`; repoint them to `i`.
                inline for (config.indexes, 0..) |fname, k| {
                    self.indexes[k].repoint(@field(moved, fname), last, i);
                }
            }
            _ = self.records.pop();
            _ = self.blobs.pop();
            std.debug.assert(self.records.items.len == self.blobs.items.len);
            self.revision +%= 1;
            return true;
        }

        // A lazy iterator over the records a predicate matches (a query.* predicate). If the
        // predicate carries an `eq` on an indexed field - as the whole predicate or a direct
        // member of a top-level `all` - the iterator is SEEDED from that index and visits
        // only those candidates, each still filtered by the full monomorphized match; with no
        // usable index it scans. The match is inlined, so a point lookup should use get. The
        // iterator borrows the records slice: do not mutate the collection while it is live.
        pub fn query(self: *const Self, pred: anytype) Iterator(@TypeOf(pred)) {
            const seed = comptime find_seed(@TypeOf(pred));
            const positions: ?[]const usize = if (comptime seed) |s| pos: {
                const slot = comptime index_slot(s.field);
                const value = if (comptime s.child) |j| pred.preds[j].operand else pred.operand;
                break :pos self.indexes[slot].seek(value);
            } else null;
            return .{ .recs = self.records.items, .pred = pred, .positions = positions };
        }

        pub fn Iterator(comptime P: type) type {
            return struct {
                recs: []const T,
                pred: P,
                positions: ?[]const usize, // seeded candidate positions, or null to scan all
                i: usize = 0,

                pub fn next(it: *@This()) ?T {
                    if (it.positions) |ps| {
                        while (it.i < ps.len) {
                            const p = ps[it.i];
                            it.i += 1;
                            std.debug.assert(p < it.recs.len); // a posting never outruns records
                            if (it.pred.match(T, it.recs[p])) return it.recs[p];
                        }
                        return null;
                    }
                    while (it.i < it.recs.len) {
                        const rec = it.recs[it.i];
                        it.i += 1;
                        if (it.pred.match(T, rec)) return rec;
                    }
                    return null;
                }
            };
        }

        // The comptime plan: an `eq` on an indexed field to seed from, if the predicate
        // exposes one directly or as a member of a top-level `all`. null -> full scan.
        const Seed = struct { field: []const u8, child: ?usize };
        fn find_seed(comptime P: type) ?Seed {
            if (leaf_eq_indexed(P)) |fld| return .{ .field = fld, .child = null };
            if (@hasDecl(P, "qodb_kind") and P.qodb_kind == .all) {
                inline for (std.meta.fields(P.qodb_preds), 0..) |f, j| {
                    if (leaf_eq_indexed(f.type)) |fld| return .{ .field = fld, .child = j };
                }
            }
            return null;
        }
        fn leaf_eq_indexed(comptime P: type) ?[]const u8 {
            if (@hasDecl(P, "qodb_op") and P.qodb_op == .eq and is_indexed(P.qodb_field)) {
                return P.qodb_field;
            }
            return null;
        }
        fn is_indexed(comptime field: []const u8) bool {
            inline for (config.indexes) |n| {
                if (std.mem.eql(u8, n, field)) return true;
            }
            return false;
        }

        // All records whose indexed field `fname` equals `value`, via the secondary index
        // (no scan). The iterator borrows index + record storage: valid until the next
        // mutation. `fname` must be one of config.indexes, else a compile error.
        pub fn find_by(
            self: *const Self,
            comptime fname: []const u8,
            value: @FieldType(T, fname),
        ) FindIterator {
            const k = comptime index_slot(fname);
            return .{ .recs = self.records.items, .positions = self.indexes[k].seek(value) };
        }

        pub const FindIterator = struct {
            recs: []const T,
            positions: []const usize,
            i: usize = 0,

            pub fn next(it: *FindIterator) ?T {
                if (it.i >= it.positions.len) return null;
                const pos = it.positions[it.i];
                it.i += 1;
                std.debug.assert(pos < it.recs.len); // a posting never outruns records
                return it.recs[pos];
            }
        };

        // The slot of `fname` in config.indexes, or a compile error if it is not indexed.
        fn index_slot(comptime fname: []const u8) usize {
            inline for (config.indexes, 0..) |n, i| {
                if (std.mem.eql(u8, n, fname)) return i;
            }
            @compileError("qodb: '" ++ fname ++ "' is not a secondary-index field");
        }

        // Takes ownership of `blob` (an encoded record); decodes + indexes it. `key`
        // points into the new blob; on a replace the old map entry (whose key points
        // into the old blob) is removed BEFORE the old blob is freed, then re-inserted
        // against the new blob's bytes - a string key must never dangle into a freed blob.
        fn insert_blob(self: *Self, blob: []u8) Error!void {
            const rec = codec.decode(T, blob) catch return error.Corrupt;
            const key = key_of(rec);
            std.debug.assert(self.records.items.len == self.blobs.items.len); // parallel arrays
            if (self.by_key.get(key)) |i| {
                const old_rec = self.records.items[i];
                // Add the new index values (fallible, rolled back on error) BEFORE dropping
                // the old ones; an unchanged field keeps its posting. Everything that reads
                // the old record (index drop, the by_key key bytes) runs while the old blob
                // is still alive - only then is it freed and the record committed.
                try self.index_add(old_rec, rec, i);
                self.index_drop(old_rec, rec, i);
                std.debug.assert(self.by_key.remove(key)); // old key bytes back the old blob
                self.gpa.free(self.blobs.items[i]);
                self.records.items[i] = rec;
                self.blobs.items[i] = blob;
                self.by_key.putAssumeCapacity(key, i); // re-point key to the new blob
                return;
            }
            try self.records.append(self.gpa, rec);
            errdefer _ = self.records.pop();
            try self.blobs.append(self.gpa, blob);
            errdefer _ = self.blobs.pop();
            const pos = self.records.items.len - 1;
            try self.by_key.put(self.gpa, key, pos);
            errdefer std.debug.assert(self.by_key.remove(key));
            inline for (config.indexes, 0..) |fname, k| {
                try self.indexes[k].add(self.gpa, @field(rec, fname), pos);
                errdefer self.indexes[k].drop(self.gpa, @field(rec, fname), pos);
            }
            std.debug.assert(self.records.items.len == self.blobs.items.len);
        }

        // Add the new record's changed index values at `pos`; an error rolls back what was
        // added so far. Paired with index_drop on the commit path.
        fn index_add(self: *Self, old_rec: T, new_rec: T, pos: usize) Error!void {
            inline for (config.indexes, 0..) |fname, k| {
                const nv = @field(new_rec, fname);
                if (!value_eq(@field(old_rec, fname), nv)) {
                    try self.indexes[k].add(self.gpa, nv, pos);
                    errdefer self.indexes[k].drop(self.gpa, nv, pos);
                }
            }
        }

        // Drop the old record's changed index values at `pos` (infallible). Read while the
        // old blob is still alive, so a []const u8 value still resolves.
        fn index_drop(self: *Self, old_rec: T, new_rec: T, pos: usize) void {
            inline for (config.indexes, 0..) |fname, k| {
                const ov = @field(old_rec, fname);
                if (!value_eq(ov, @field(new_rec, fname))) self.indexes[k].drop(self.gpa, ov, pos);
            }
        }

        fn key_of(rec: T) KeyType {
            return @field(rec, config.key);
        }

        // Encode the whole collection to one caller-freed buffer: a u32 count then each
        // record's blob length-prefixed. The snapshot that save writes (and encrypted
        // persistence seals); deserialize is its inverse.
        pub fn serialize(self: *const Self) std.mem.Allocator.Error![]u8 {
            var total: usize = @sizeOf(u32);
            for (self.blobs.items) |b| total += @sizeOf(u32) + b.len;
            const buf = try self.gpa.alloc(u8, total);
            errdefer self.gpa.free(buf);

            var n: usize = 0;
            write_u32(buf, &n, @intCast(self.records.items.len));
            for (self.blobs.items) |b| {
                write_u32(buf, &n, @intCast(b.len));
                @memcpy(buf[n..][0..b.len], b);
                n += b.len;
            }
            std.debug.assert(n == total);
            return buf;
        }

        // Populate an empty collection from a serialize() snapshot. Each record's blob is
        // copied into collection-owned memory, so `data` need not outlive the call.
        pub fn deserialize(self: *Self, data: []const u8) Error!void {
            std.debug.assert(self.count() == 0);
            var n: usize = 0;
            const records = try read_u32(data, &n);
            var k: usize = 0;
            while (k < records) : (k += 1) {
                const len = try read_u32(data, &n);
                if (len > data.len - n) return error.Corrupt; // subtract: `n + len` could overflow
                const blob = try self.gpa.dupe(u8, data[n..][0..len]);
                errdefer self.gpa.free(blob);
                n += len;
                try self.insert_blob(blob); // takes ownership on success; we free on error
            }
        }

        // Like deserialize, but `stored_hash` (the record layout the snapshot was written
        // with) selects the path: the current shape decodes directly; a shape named by a
        // migration step decodes as that old type and folds up the chain to the current T;
        // any other hash is a SchemaMismatch (an unregistered change, a newer version, or
        // corruption). The database calls this; a bare collection has no stored hash.
        pub fn deserialize_versioned(self: *Self, data: []const u8, stored_hash: u64) Error!void {
            if (stored_hash == comptime codec.layout_hash(T)) return self.deserialize(data);
            inline for (0..migrations.len) |i| {
                const S = migration_input(@TypeOf(migrations[i]));
                if (stored_hash == comptime codec.layout_hash(S)) {
                    return self.load_migrated(i, S, data);
                }
            }
            return error.SchemaMismatch;
        }

        // Decode each record as the old shape `S` (a step-`i` input), fold it forward to the
        // current T, and upsert it (re-encoding in the current layout). The next save writes
        // the migrated shape.
        fn load_migrated(
            self: *Self,
            comptime i: usize,
            comptime S: type,
            data: []const u8,
        ) Error!void {
            std.debug.assert(self.count() == 0);
            var n: usize = 0;
            const records = try read_u32(data, &n);
            var k: usize = 0;
            while (k < records) : (k += 1) {
                const len = try read_u32(data, &n);
                if (len > data.len - n) return error.Corrupt; // subtract: `n + len` could overflow
                const old = codec.decode(S, data[n..][0..len]) catch return error.Corrupt;
                n += len;
                try self.upsert(fold_migrations(i, old));
            }
        }

        // Apply migration steps i, i+1, ... to `value`, yielding the current T. Each step's
        // output type is the next step's input; the last yields T (validated at comptime).
        fn fold_migrations(comptime i: usize, value: anytype) T {
            if (comptime i == migrations.len) return value;
            return fold_migrations(i + 1, migrations[i](value));
        }

        // Persist the whole collection to `path` (relative to cwd). Written to a temp file
        // and renamed over `path`, so a crash mid-write never leaves a torn file (the
        // snapshot is all-or-nothing).
        pub fn save(self: *const Self, io: std.Io, path: []const u8) !void {
            const buf = try self.serialize();
            defer self.gpa.free(buf);
            try write_atomic(io, self.gpa, path, buf);
        }

        // Load the collection from `path` into an empty collection. A missing file is an
        // empty store (no error).
        pub fn load(self: *Self, io: std.Io, path: []const u8) !void {
            std.debug.assert(self.count() == 0);
            const data = std.Io.Dir.cwd().readFileAlloc(io, path, self.gpa, .unlimited) catch |e| {
                if (e == error.FileNotFound) return;
                return e;
            };
            defer self.gpa.free(data);
            try self.deserialize(data);
        }
    };
}

// Write `data` to `path` crash-safely: a sibling temp file, then an atomic rename over
// `path`. A torn write leaves the stale temp, never a half-written `path`.
pub fn write_atomic(io: std.Io, gpa: std.mem.Allocator, path: []const u8, data: []const u8) !void {
    const tmp = try std.fmt.allocPrint(gpa, "{s}.tmp", .{path});
    defer gpa.free(tmp);
    const dir = std.Io.Dir.cwd();
    try dir.writeFile(io, .{ .sub_path = tmp, .data = data });
    try std.Io.Dir.rename(dir, tmp, dir, path, io);
}

fn write_u32(buf: []u8, n: *usize, v: u32) void {
    @memcpy(buf[n.*..][0..4], std.mem.asBytes(&v));
    n.* += 4;
}

fn read_u32(data: []const u8, n: *usize) error{Corrupt}!u32 {
    std.debug.assert(n.* <= data.len); // the cursor never passes the end
    if (4 > data.len - n.*) return error.Corrupt; // subtract: `n + 4` could overflow
    var v: u32 = undefined;
    @memcpy(std.mem.asBytes(&v), data[n.*..][0..4]);
    n.* += 4;
    return v;
}

fn is_byte_slice(comptime T: type) bool {
    const info = @typeInfo(T);
    return info == .pointer and info.pointer.size == .slice and info.pointer.child == u8;
}

fn value_eq(a: anytype, b: @TypeOf(a)) bool {
    if (comptime is_byte_slice(@TypeOf(a))) return std.mem.eql(u8, a, b);
    return a == b;
}

// The input (old-shape) type of a migration step `fn(OldShape) NewShape`.
fn migration_input(comptime F: type) type {
    return @typeInfo(F).@"fn".params[0].type.?;
}

// Compile-error unless every migration is a one-argument fn, each step's output type is
// the next step's input, and the last step returns the current record type T.
fn validate_migrations(comptime T: type, comptime migs: anytype) void {
    const n = migs.len;
    if (n == 0) return;
    inline for (0..n) |i| {
        const F = @TypeOf(migs[i]);
        const info = @typeInfo(F);
        if (info != .@"fn" or info.@"fn".params.len != 1) {
            @compileError("qodb: each migration must be a fn(OldShape) NewShape");
        }
        const out = info.@"fn".return_type.?;
        if (i + 1 < n) {
            if (out != migration_input(@TypeOf(migs[i + 1]))) {
                @compileError("qodb: migration steps must chain (a step output == the next input)");
            }
        } else if (out != T) {
            @compileError("qodb: the final migration must return the current record type");
        }
    }
}

// One secondary index over field `fname` of T: value -> the record positions holding it (a
// value need not be unique). For a []const u8 field the index owns a copy of the value bytes
// (the map key), so an entry never dangles into a freed record blob when one of several
// records sharing that value is removed; a scalar value is stored inline.
fn FieldIndex(comptime T: type, comptime fname: []const u8) type {
    const V = @FieldType(T, fname);
    const owns_key = is_byte_slice(V);
    const PostingList = std.ArrayListUnmanaged(usize); // record positions holding a value
    const Map = if (owns_key)
        std.StringHashMapUnmanaged(PostingList)
    else
        std.AutoHashMapUnmanaged(V, PostingList);

    return struct {
        const Self = @This();
        map: Map = .empty,

        fn deinit(fi: *Self, gpa: std.mem.Allocator) void {
            var it = fi.map.iterator();
            while (it.next()) |e| {
                e.value_ptr.deinit(gpa);
                if (owns_key) gpa.free(e.key_ptr.*);
            }
            fi.map.deinit(gpa);
        }

        fn add(fi: *Self, gpa: std.mem.Allocator, value: V, pos: usize) !void {
            const gop = try fi.map.getOrPut(gpa, value);
            const created = !gop.found_existing;
            if (created) {
                gop.value_ptr.* = .empty;
                if (owns_key) gop.key_ptr.* = gpa.dupe(u8, value) catch |e| {
                    std.debug.assert(fi.map.remove(value));
                    return e;
                };
            }
            gop.value_ptr.append(gpa, pos) catch |e| {
                if (created) discard(fi, gpa, gop.value_ptr, value);
                return e;
            };
            std.debug.assert(gop.value_ptr.items.len != 0); // a posting holds at least its add
        }

        fn drop(fi: *Self, gpa: std.mem.Allocator, value: V, pos: usize) void {
            const e = fi.map.getEntry(value) orelse unreachable; // the value was always indexed
            var removed = false;
            for (e.value_ptr.items, 0..) |p, j| {
                if (p == pos) {
                    _ = e.value_ptr.swapRemove(j);
                    removed = true;
                    break;
                }
            }
            std.debug.assert(removed); // the position lived in this value's posting
            if (e.value_ptr.items.len != 0) return;
            discard(fi, gpa, e.value_ptr, value);
        }

        // Remove the (now empty) entry for `value`, freeing its posting and, for a string
        // field, the owned key bytes (read before the map mutation that invalidates them).
        fn discard(fi: *Self, gpa: std.mem.Allocator, posting: *PostingList, value: V) void {
            std.debug.assert(posting.items.len == 0); // only an empty posting is discarded
            posting.deinit(gpa);
            if (owns_key) {
                const owned = fi.map.getKeyPtr(value).?.*;
                std.debug.assert(fi.map.remove(value));
                gpa.free(owned);
            } else {
                std.debug.assert(fi.map.remove(value));
            }
        }

        fn repoint(fi: *Self, value: V, old_pos: usize, new_pos: usize) void {
            const e = fi.map.getEntry(value) orelse unreachable; // the moved record was indexed
            var found = false;
            for (e.value_ptr.items) |*p| if (p.* == old_pos) {
                p.* = new_pos;
                found = true;
                break;
            };
            std.debug.assert(found); // exactly the moved record's posting was repointed
        }

        fn seek(fi: *const Self, value: V) []const usize {
            const e = fi.map.getEntry(value) orelse return &.{};
            std.debug.assert(e.value_ptr.items.len != 0); // an empty posting is never kept
            return e.value_ptr.items;
        }
    };
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

fn count_find(it: anytype) usize {
    var n: usize = 0;
    while (it.next()) |_| n += 1;
    return n;
}

test "secondary index: find_by, non-unique values, replace and remove" {
    const User = struct { id: u64, country: []const u8, age: u16 };
    const C = Collection(User, .{ .key = "id", .indexes = &.{ "country", "age" } });
    var c = C.init(std.testing.allocator);
    defer c.deinit();

    try c.upsert(.{ .id = 1, .country = "ID", .age = 20 });
    try c.upsert(.{ .id = 2, .country = "ID", .age = 30 });
    try c.upsert(.{ .id = 3, .country = "US", .age = 20 });

    { // two records share "ID"
        var it = c.find_by("country", "ID");
        try std.testing.expectEqual(@as(usize, 2), count_find(&it));
    }
    { // a scalar index works too
        var it = c.find_by("age", @as(u16, 20));
        try std.testing.expectEqual(@as(usize, 2), count_find(&it));
    }
    { // an absent value yields nothing
        var it = c.find_by("country", "ZZ");
        try std.testing.expectEqual(@as(usize, 0), count_find(&it));
    }

    // Replace id=2 ID->MY: "ID" drops to one, "MY" appears.
    try c.upsert(.{ .id = 2, .country = "MY", .age = 30 });
    {
        var id = c.find_by("country", "ID");
        try std.testing.expectEqual(@as(usize, 1), count_find(&id));
        var my = c.find_by("country", "MY");
        try std.testing.expectEqual(@as(u64, 2), my.next().?.id);
    }

    // Remove id=1 (a swap-remove moves id=3 into its slot); the index must still resolve.
    try std.testing.expect(c.remove(1));
    {
        var id = c.find_by("country", "ID");
        try std.testing.expectEqual(@as(usize, 0), count_find(&id));
        var us = c.find_by("country", "US");
        try std.testing.expectEqual(@as(u64, 3), us.next().?.id);
        var twenty = c.find_by("age", @as(u16, 20));
        try std.testing.expectEqual(@as(u64, 3), twenty.next().?.id);
    }
}

test "query seeds from an index and still filters; scans when it cannot" {
    const User = struct { id: u64, country: []const u8, age: u16 };
    const C = Collection(User, .{ .key = "id", .indexes = &.{"country"} });
    var c = C.init(std.testing.allocator);
    defer c.deinit();
    try c.upsert(.{ .id = 1, .country = "ID", .age = 17 });
    try c.upsert(.{ .id = 2, .country = "ID", .age = 25 });
    try c.upsert(.{ .id = 3, .country = "US", .age = 40 });

    // Seeded from `country` (a top-level `all` member), then filtered by age: only id=2.
    var it = c.query(q.all(.{ q.eq("country", "ID"), q.gte("age", @as(u16, 18)) }));
    try std.testing.expectEqual(@as(u64, 2), it.next().?.id);
    try std.testing.expectEqual(@as(?User, null), it.next());

    // A bare eq on the indexed field seeds directly: both ID records.
    var bare = c.query(q.eq("country", "ID"));
    try std.testing.expectEqual(@as(usize, 2), count_find(&bare));

    // eq on a non-indexed field falls back to a scan and is still correct.
    var scan = c.query(q.eq("age", @as(u16, 40)));
    try std.testing.expectEqual(@as(u64, 3), scan.next().?.id);

    // `any` cannot seed from one index; it scans and stays correct.
    var either = c.query(q.any(.{ q.eq("country", "US"), q.gte("age", @as(u16, 20)) }));
    try std.testing.expectEqual(@as(usize, 2), count_find(&either));
}

test "secondary index is rebuilt on load" {
    const User = struct { id: u64, email: []const u8 };
    const C = Collection(User, .{ .key = "id", .indexes = &.{"email"} });
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const path = "qodb_index_load.bin";
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    {
        var c = C.init(std.testing.allocator);
        defer c.deinit();
        try c.upsert(.{ .id = 1, .email = "a@x.io" });
        try c.upsert(.{ .id = 2, .email = "a@x.io" });
        try c.save(io, path);
    }
    {
        var c = C.init(std.testing.allocator);
        defer c.deinit();
        try c.load(io, path);
        var it = c.find_by("email", "a@x.io"); // resolves only if the index was rebuilt
        try std.testing.expectEqual(@as(usize, 2), count_find(&it));
    }
}
