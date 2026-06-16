// A database: one file holding many named collections behind one boundary - one store
// with many tables, not a file per collection. The schema is a comptime struct whose
// fields are Collection types; `db.cols.<name>` is the typed collection, resolved at
// comptime with no runtime dispatch.
//
//   const App = qodb.Database(struct {
//       users:  qodb.Collection(User,  .{ .key = "id", .indexes = &.{"email"} }),
//       orders: qodb.Collection(Order, .{ .key = "id" }),
//   });
//   var db = App.init(gpa);
//   defer db.deinit();
//   try db.cols.users.upsert(.{ .id = 1, .email = "a@b.com" });
//   try db.save(io, "app.qodb");
//
// Persistence is a whole-database snapshot: every collection is serialized, framed by
// name, concatenated, and written with an atomic temp+rename (all-or-nothing). Each
// section carries a hash of its record type's layout, so a record-type change is caught
// on load instead of silently mis-decoded.

const std = @import("std");
const collection = @import("collection.zig");
const codec = @import("codec.zig");
const secure = @import("secure.zig");
const assert = std.debug.assert;

pub const Error = error{
    Corrupt, // the file is truncated or malformed
    SchemaMismatch, // a section's record-type layout differs from the schema's
} || std.mem.Allocator.Error;

// When an open() database flushes itself. Both paths are synchronous and lock-free (the
// single-writer contract): a flush serializes and atomically writes only when dirty.
pub const Autosave = struct {
    after_writes: ?u64 = null, // checkpoint() flushes once this many mutations accumulate
    on_close: bool = true, // close() flushes a dirty database
};

// How an open() database is encrypted on disk (null in Options -> plaintext). password is
// pure Zig (Argon2id); envelope/keystore_bound use a host-supplied KeyProvider. The whole
// snapshot is the encrypted unit.
pub const Encryption = union(enum) {
    password: struct { passphrase: []const u8, params: secure.Argon = .{} },
    envelope: secure.KeyProvider,
    keystore_bound: secure.KeyProvider,
};

pub const Options = struct {
    autosave: Autosave = .{},
    encryption: ?Encryption = null,
};

pub fn Database(comptime Schema: type) type {
    comptime validate(Schema);
    const fields = std.meta.fields(Schema);

    return struct {
        const Self = @This();
        pub const Tables = Schema;

        cols: Schema,
        gpa: std.mem.Allocator,
        path: ?[]const u8 = null, // the open() file; null for an in-memory init()
        autosave: Autosave = .{},
        crypto: ?secure.Security = null, // resolved encryption (password holds the session key)
        saved_revision: u64 = 0, // total_revision at the last flush; dirtiness is the delta

        pub fn init(gpa: std.mem.Allocator) Self {
            var self: Self = .{ .cols = undefined, .gpa = gpa };
            inline for (fields) |f| @field(self.cols, f.name) = f.type.init(gpa);
            return self;
        }

        pub fn deinit(self: *Self) void {
            inline for (fields) |f| @field(self.cols, f.name).deinit();
            if (self.crypto) |*c| switch (c.*) {
                .password => |*pw| std.crypto.secureZero(u8, &pw.key), // wipe the session key
                else => {},
            };
            if (self.path) |p| self.gpa.free(p);
        }

        // Open a database backed by `path`: load it (a missing file starts empty), remember
        // the path + autosave + encryption, and mark the loaded state clean. Use flush/
        // checkpoint/close to persist; init/save/load remain for the manual plaintext case.
        pub fn open(gpa: std.mem.Allocator, io: std.Io, path: []const u8, options: Options) !Self {
            std.debug.assert(path.len != 0); // a database needs a real path
            var self = Self.init(gpa);
            errdefer self.deinit();
            self.autosave = options.autosave;
            if (options.encryption) |enc| {
                try self.open_encrypted(io, path, enc);
            } else {
                try self.load(io, path);
            }
            self.path = try gpa.dupe(u8, path);
            self.saved_revision = self.total_revision();
            return self;
        }

        // Resolve the encryption (deriving the password key from the on-disk salt or a fresh
        // one) and decrypt+load an existing file. A missing file starts empty.
        fn open_encrypted(self: *Self, io: std.Io, path: []const u8, enc: Encryption) !void {
            const dir = std.Io.Dir.cwd();
            const existing = dir.readFileAlloc(io, path, self.gpa, .unlimited) catch |e|
                if (e == error.FileNotFound) null else return e;
            defer if (existing) |d| self.gpa.free(d);
            self.crypto = try resolve_crypto(self.gpa, io, enc, existing);
            if (existing) |data| {
                const plain = try secure.open(self.gpa, data, self.crypto.?);
                defer {
                    std.crypto.secureZero(u8, plain);
                    self.gpa.free(plain);
                }
                try self.deserialize(plain);
            }
        }

        // The mutation count across all collections; monotonic, one per upsert/remove.
        fn total_revision(self: *const Self) u64 {
            var total: u64 = 0;
            inline for (fields) |f| total +%= @field(self.cols, f.name).revision;
            return total;
        }

        // Whether there are unflushed mutations since the last flush.
        pub fn dirty(self: *const Self) bool {
            return self.total_revision() != self.saved_revision;
        }

        // Write the database to its open() path if dirty (else a no-op). Synchronous; the
        // atomic temp+rename keeps the file all-or-nothing.
        pub fn flush(self: *Self, io: std.Io) !void {
            std.debug.assert(self.path != null); // flush/checkpoint/close need an open() path
            std.debug.assert(self.path.?.len != 0);
            const current = self.total_revision();
            if (current == self.saved_revision) return;
            const buf = try self.serialize();
            defer {
                if (self.crypto != null) std.crypto.secureZero(u8, buf); // cleartext snapshot
                self.gpa.free(buf);
            }
            if (self.crypto) |sec| {
                const file = try secure.seal(self.gpa, io, buf, sec);
                defer self.gpa.free(file);
                try collection.write_atomic(io, self.gpa, self.path.?, file);
            } else {
                try collection.write_atomic(io, self.gpa, self.path.?, buf);
            }
            self.saved_revision = current;
            std.debug.assert(!self.dirty()); // a successful flush leaves the database clean
        }

        // Flush only if the autosave policy says so (enough mutations since the last flush).
        // Cheap to call often - e.g. once per event-loop turn - flushing only when due.
        pub fn checkpoint(self: *Self, io: std.Io) !void {
            const n = self.autosave.after_writes orelse return;
            std.debug.assert(n != 0); // a zero threshold would flush on every call
            if (self.total_revision() -% self.saved_revision >= n) try self.flush(io);
        }

        // Flush a dirty database (when on_close) and release it. The database is consumed.
        pub fn close(self: *Self, io: std.Io) !void {
            std.debug.assert(self.path != null); // close pairs with open
            defer self.deinit();
            if (self.autosave.on_close) try self.flush(io);
        }

        // Encode the whole database to one caller-freed buffer: a u32 section count then,
        // per collection, its name, record-layout hash, and serialized blob. The unit the
        // secure layer encrypts and that save writes.
        pub fn serialize(self: *const Self) std.mem.Allocator.Error![]u8 {
            var blobs: [fields.len][]u8 = undefined;
            var built: usize = 0;
            defer for (blobs[0..built]) |b| self.gpa.free(b);
            inline for (fields, 0..) |f, i| {
                blobs[i] = try @field(self.cols, f.name).serialize();
                built += 1;
            }

            var total: usize = @sizeOf(u32);
            inline for (fields, 0..) |f, i| {
                total += 2 * @sizeOf(u32) + @sizeOf(u64) + f.name.len + blobs[i].len;
            }
            const buf = try self.gpa.alloc(u8, total);
            errdefer self.gpa.free(buf);

            assert(built == fields.len); // every collection serialized before framing
            var n: usize = 0;
            put_u32(buf, &n, fields.len);
            inline for (fields, 0..) |f, i| {
                put_u32(buf, &n, @intCast(f.name.len));
                put_bytes(buf, &n, f.name);
                put_u64(buf, &n, comptime codec.layout_hash(f.type.Record));
                put_u32(buf, &n, @intCast(blobs[i].len));
                put_bytes(buf, &n, blobs[i]);
            }
            assert(n == total);
            return buf;
        }

        // Populate an empty database from a serialize() snapshot. A section whose name no
        // collection claims is dropped (a removed collection's data does not linger); a
        // section whose record layout no longer matches is a SchemaMismatch.
        pub fn deserialize(self: *Self, data: []const u8) Error!void {
            inline for (fields) |f| assert(@field(self.cols, f.name).count() == 0);

            var n: usize = 0;
            const sections = try read_u32(data, &n);
            if (sections > data.len) return error.Corrupt; // >= 1 byte each; bounds the loop
            var seen = [_]bool{false} ** fields.len; // a collection appears at most once
            var s: usize = 0;
            while (s < sections) : (s += 1) {
                const name = try take(data, &n, try read_u32(data, &n));
                const hash = try read_u64(data, &n);
                const blob = try take(data, &n, try read_u32(data, &n));
                inline for (fields, 0..) |f, fi| {
                    if (std.mem.eql(u8, f.name, name)) {
                        if (seen[fi]) return error.Corrupt; // a section name appears twice
                        seen[fi] = true;
                        // The collection owns the hash decision: current shape -> decode;
                        // a known older shape -> migrate; anything else -> SchemaMismatch.
                        try @field(self.cols, f.name).deserialize_versioned(blob, hash);
                    }
                }
            }
            if (n != data.len) return error.Corrupt; // no trailing bytes past the last section
        }

        // Persist the whole database to `path` atomically (temp + rename).
        pub fn save(self: *const Self, io: std.Io, path: []const u8) !void {
            const buf = try self.serialize();
            defer self.gpa.free(buf);
            try collection.write_atomic(io, self.gpa, path, buf);
        }

        // Load an empty database from `path`; a missing file leaves it empty.
        pub fn load(self: *Self, io: std.Io, path: []const u8) !void {
            const data = std.Io.Dir.cwd().readFileAlloc(io, path, self.gpa, .unlimited) catch |e| {
                if (e == error.FileNotFound) return;
                return e;
            };
            defer self.gpa.free(data);
            try self.deserialize(data);
        }
    };
}

// Build the on-disk Security from the user's Encryption. For password, derive the key once
// (Argon2id) from the salt the existing file carries, or a fresh salt for a new database.
fn resolve_crypto(
    gpa: std.mem.Allocator,
    io: std.Io,
    enc: Encryption,
    existing: ?[]const u8,
) !secure.Security {
    switch (enc) {
        .password => |p| {
            var salt: [secure.salt_len]u8 = undefined;
            if (existing) |f| {
                salt = secure.read_salt(f) orelse return error.BadKey; // not a password file
            } else {
                try io.randomSecure(&salt);
            }
            const key = try secure.derive(gpa, io, p.passphrase, salt, p.params);
            return .{ .password = .{ .key = key, .salt = salt } };
        },
        .envelope => |provider| return .{ .envelope = provider },
        .keystore_bound => |provider| return .{ .keystore_bound = provider },
    }
}

// Each schema field must be a Collection (carry the decls/methods the container drives).
fn validate(comptime Schema: type) void {
    if (@typeInfo(Schema) != .@"struct") @compileError("qodb: a Database schema must be a struct");
    inline for (std.meta.fields(Schema)) |f| {
        if (!@hasDecl(f.type, "Record") or !@hasDecl(f.type, "serialize")) {
            @compileError("qodb: schema field '" ++ f.name ++ "' must be a qodb.Collection");
        }
    }
}

fn put_bytes(buf: []u8, n: *usize, bytes: []const u8) void {
    @memcpy(buf[n.*..][0..bytes.len], bytes);
    n.* += bytes.len;
}
fn put_u32(buf: []u8, n: *usize, v: u32) void {
    put_bytes(buf, n, std.mem.asBytes(&v));
}
fn put_u64(buf: []u8, n: *usize, v: u64) void {
    put_bytes(buf, n, std.mem.asBytes(&v));
}

fn take(data: []const u8, n: *usize, len: usize) Error![]const u8 {
    assert(n.* <= data.len); // the cursor never passes the end
    if (len > data.len - n.*) return error.Corrupt; // subtract: `n + len` could overflow
    defer n.* += len;
    return data[n.*..][0..len];
}
fn read_u32(data: []const u8, n: *usize) Error!u32 {
    const s = try take(data, n, @sizeOf(u32));
    var v: u32 = undefined;
    @memcpy(std.mem.asBytes(&v), s);
    return v;
}
fn read_u64(data: []const u8, n: *usize) Error!u64 {
    const s = try take(data, n, @sizeOf(u64));
    var v: u64 = undefined;
    @memcpy(std.mem.asBytes(&v), s);
    return v;
}

const testing = std.testing;
const q = @import("query.zig");

const User = struct { id: u64, age: u16, email: []const u8 };
const Order = struct { id: u64, total: u32 };
const App = Database(struct {
    users: collection.Collection(User, .{ .key = "id" }),
    orders: collection.Collection(Order, .{ .key = "id" }),
});

test "named collections, save and load the whole database" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const path = "qodb_db_roundtrip.bin";
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    {
        var db = App.init(testing.allocator);
        defer db.deinit();
        try db.cols.users.upsert(.{ .id = 1, .age = 20, .email = "ada@x.io" });
        try db.cols.users.upsert(.{ .id = 2, .age = 31, .email = "bo@x.io" });
        try db.cols.orders.upsert(.{ .id = 9, .total = 150 });
        try db.save(io, path);
    }
    {
        var db = App.init(testing.allocator);
        defer db.deinit();
        try db.load(io, path);
        try testing.expectEqual(@as(usize, 2), db.cols.users.count());
        try testing.expectEqualStrings("bo@x.io", db.cols.users.get(2).?.email);
        try testing.expectEqual(@as(u32, 150), db.cols.orders.get(9).?.total);

        var it = db.cols.users.query(q.gte("age", @as(u16, 25)));
        try testing.expectEqual(@as(u64, 2), it.next().?.id);
        try testing.expectEqual(@as(?User, null), it.next());
    }
}

test "a missing file loads as an empty database" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var db = App.init(testing.allocator);
    defer db.deinit();
    try db.load(threaded.io(), "qodb_db_absent.bin");
    try testing.expectEqual(@as(usize, 0), db.cols.users.count());
    try testing.expectEqual(@as(usize, 0), db.cols.orders.count());
}

test "a section no collection claims is dropped on load" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const path = "qodb_db_orphan.bin";
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    // A wider schema writes an extra collection the narrower one below does not have.
    const Wide = Database(struct {
        users: collection.Collection(User, .{ .key = "id" }),
        orders: collection.Collection(Order, .{ .key = "id" }),
        notes: collection.Collection(struct { id: u64, text: []const u8 }, .{ .key = "id" }),
    });
    {
        var db = Wide.init(testing.allocator);
        defer db.deinit();
        try db.cols.users.upsert(.{ .id = 1, .age = 20, .email = "ada@x.io" });
        try db.cols.notes.upsert(.{ .id = 7, .text = "to drop" });
        try db.save(io, path);
    }
    {
        var db = App.init(testing.allocator); // no `notes` collection
        defer db.deinit();
        try db.load(io, path); // the orphan `notes` section is skipped, not an error
        try testing.expectEqual(@as(usize, 1), db.cols.users.count());
    }
}

test "a changed record layout is rejected on load" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const path = "qodb_db_schema.bin";
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const NameV1 = struct { id: u64, name: []const u8 };
    const NameV2 = struct { id: u64, name: []const u8, age: u16 };
    const V1 = Database(struct {
        users: collection.Collection(NameV1, .{ .key = "id" }),
    });
    const V2 = Database(struct {
        users: collection.Collection(NameV2, .{ .key = "id" }),
    });
    {
        var db = V1.init(testing.allocator);
        defer db.deinit();
        try db.cols.users.upsert(.{ .id = 1, .name = "ada" });
        try db.save(io, path);
    }
    {
        var db = V2.init(testing.allocator);
        defer db.deinit();
        try testing.expectError(error.SchemaMismatch, db.load(io, path));
    }
}

const UserV1 = struct { id: u64, name: []const u8 };
const UserV2 = struct {
    id: u64,
    name: []const u8,
    age: u16,
    pub const qodb_migrations = .{up_from_v1};
    fn up_from_v1(old: UserV1) @This() {
        return .{ .id = old.id, .name = old.name, .age = 0 }; // new field gets a default
    }
};

test "a versioned migration upgrades old records on load" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const path = "qodb_db_migrate.bin";
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const V1 = Database(struct { users: collection.Collection(UserV1, .{ .key = "id" }) });
    const V2 = Database(struct { users: collection.Collection(UserV2, .{ .key = "id" }) });
    {
        var db = V1.init(testing.allocator);
        defer db.deinit();
        try db.cols.users.upsert(.{ .id = 1, .name = "ada" });
        try db.cols.users.upsert(.{ .id = 2, .name = "bo" });
        try db.save(io, path);
    }
    {
        var db = V2.init(testing.allocator);
        defer db.deinit();
        try db.load(io, path); // old records decoded as UserV1, folded to UserV2
        try testing.expectEqual(@as(usize, 2), db.cols.users.count());
        try testing.expectEqual(@as(u16, 0), db.cols.users.get(1).?.age);
        try testing.expectEqualStrings("ada", db.cols.users.get(1).?.name);
        try testing.expectEqualStrings("bo", db.cols.users.get(2).?.name);
    }
}

test "open, dirty tracking, checkpoint-after-writes, and close persist" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const path = "qodb_db_autosave.bin";
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    {
        var db = try App.open(testing.allocator, io, path, .{ .autosave = .{ .after_writes = 2 } });
        defer db.close(io) catch {};
        try testing.expect(!db.dirty());

        try db.cols.users.upsert(.{ .id = 1, .age = 20, .email = "a@x.io" });
        try testing.expect(db.dirty());
        try db.checkpoint(io); // 1 write < 2 -> not yet flushed
        try db.cols.users.upsert(.{ .id = 2, .age = 30, .email = "b@x.io" });
        try db.checkpoint(io); // 2 writes -> flush
        try testing.expect(!db.dirty());

        try db.cols.orders.upsert(.{ .id = 9, .total = 5 }); // dirty again; close flushes it
    }
    {
        var db = try App.open(testing.allocator, io, path, .{});
        defer db.close(io) catch {};
        try testing.expectEqual(@as(usize, 2), db.cols.users.count());
        try testing.expectEqual(@as(u32, 5), db.cols.orders.get(9).?.total);
    }
}

test "an encrypted database persists under a passphrase and rejects a wrong one" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const path = "qodb_db_secure.bin";
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    const pass = "open sesame";
    const secret = "do-not-leak-this-email";
    const fast = secure.Argon{ .t = 1, .m = 256 }; // keep the KDF cheap in the test

    {
        var db = try App.open(testing.allocator, io, path, .{
            .encryption = .{ .password = .{ .passphrase = pass, .params = fast } },
        });
        defer db.close(io) catch {};
        try db.cols.users.upsert(.{ .id = 1, .age = 9, .email = secret });
    }
    {
        const raw = try std.Io.Dir.cwd().readFileAlloc(io, path, testing.allocator, .unlimited);
        defer testing.allocator.free(raw);
        try testing.expect(std.mem.indexOf(u8, raw, secret) == null); // on disk it is ciphertext
    }
    {
        const bad = App.open(testing.allocator, io, path, .{
            .encryption = .{ .password = .{ .passphrase = "wrong", .params = fast } },
        });
        try testing.expectError(error.BadKey, bad);
    }
    {
        var db = try App.open(testing.allocator, io, path, .{
            .encryption = .{ .password = .{ .passphrase = pass, .params = fast } },
        });
        defer db.deinit();
        try testing.expectEqualStrings(secret, db.cols.users.get(1).?.email);
    }
}

test "a missing open() file starts empty and clean" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var db = try App.open(testing.allocator, io, "qodb_db_open_absent.bin", .{});
    defer db.deinit();
    try testing.expect(!db.dirty());
    try testing.expectEqual(@as(usize, 0), db.cols.users.count());
}

test "reordering a record's fields needs no migration" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const path = "qodb_db_reorder.bin";
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const Wide = struct { id: u64, name: []const u8, age: u16 };
    const Reordered = struct { age: u16, name: []const u8, id: u64 }; // same fields, reordered
    const A = Database(struct { users: collection.Collection(Wide, .{ .key = "id" }) });
    const B = Database(struct { users: collection.Collection(Reordered, .{ .key = "id" }) });
    {
        var db = A.init(testing.allocator);
        defer db.deinit();
        try db.cols.users.upsert(.{ .id = 1, .name = "ada", .age = 20 });
        try db.save(io, path);
    }
    {
        var db = B.init(testing.allocator);
        defer db.deinit();
        try db.load(io, path); // same canonical layout -> loads directly, no SchemaMismatch
        try testing.expectEqualStrings("ada", db.cols.users.get(1).?.name);
        try testing.expectEqual(@as(u16, 20), db.cols.users.get(1).?.age);
    }
}
