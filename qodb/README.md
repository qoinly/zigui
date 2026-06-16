# qodb

A typed, embedded, no-SQL database engine for Zig. One file holds many named collections
of Zig structs; you query them by field with a compile-checked API (no SQL string, no
parser, no injection), persist them with a compact binary codec, evolve them with typed
migrations, and optionally encrypt the whole database. Pure Zig, zero external
dependencies.

qodb is general-purpose and standalone - it links into any Zig application.

## Why

The record's type is already known at compile time, so SQL is unnecessary. qodb leans on
that: field names and operand types are checked by the compiler, queries monomorphize to
straight-line comparisons, and the on-disk format is a compact binary image rather than
JSON. The result is small, fast, and type-safe.

## Status and limits (be honest)

qodb is a **snapshot store**: the whole database lives in memory and each save rewrites
the file (atomically, via temp + rename - a crash never leaves a torn file). This fits
small-to-medium local data well. It is **not** a page/B-tree/WAL engine: it does not give
GB-scale storage or per-transaction durability (a crash loses mutations since the last
flush). Those are future work, not pretended here.

## Install

Add qodb as a dependency, then wire the module in `build.zig`:

```zig
const qodb = b.dependency("qodb", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("qodb", qodb.module("qodb"));
```

## Quick start

```zig
const qodb = @import("qodb");

const User = struct { id: u64, email: []const u8, age: u16 };
const Order = struct { id: u64, user_id: u64, total: u32 };

const App = qodb.Database(struct {
    users: qodb.Collection(User, .{ .key = "id", .indexes = &.{"email"} }),
    orders: qodb.Collection(Order, .{ .key = "id" }),
});

var db = App.init(gpa);
defer db.deinit();

try db.cols.users.upsert(.{ .id = 1, .email = "ada@x.io", .age = 21 });
const u = db.cols.users.get(1); // ?User, borrows store memory until the next mutation

var it = db.cols.users.query(qodb.query.gte("age", @as(u16, 18)));
while (it.next()) |adult| { ... }
```

`db.cols.<name>` is the typed collection, resolved at compile time - no runtime dispatch
to reach it.

## Collections

A `Collection(T, config)` is an in-memory set of struct `T` keyed by one field. `config`:

- `key` - the primary-key field name (unique per record).
- `indexes` - secondary-index field names (optional).

Operations: `upsert`, `get`, `remove`, `count`, `items`, `query`, `find_by`. A record
returned by `get`/`query`/`find_by` borrows the collection's storage and is valid until the
next mutation.

## Queries

A predicate is a comptime-composed value; the field name is checked against `T` and the
operand type must match the field, both at compile time.

- Leaf ops: `eq`, `ne`, `lt`, `lte`, `gt`, `gte`, `in`, `between`; on `[]const u8`:
  `contains`, `starts_with`.
- Combinators: `all` (AND), `any` (OR), `not`.

```zig
var it = db.cols.users.query(qodb.query.all(.{
    qodb.query.gte("age", @as(u16, 18)),
    qodb.query.any(.{ qodb.query.eq("country", "ID"), qodb.query.eq("country", "MY") }),
}));
```

The iterator is lazy - no intermediate result set, no per-query heap.

### Indexes

A secondary index (`.indexes = &.{"email"}`) is a hash of field value to records, rebuilt
on load and never stored. `find_by("email", value)` is a direct index lookup. `query` is
**index-aware**: when the predicate has an `eq` on an indexed field (alone or inside a
top-level `all`), it seeds from that index and filters the rest, instead of scanning. Range
predicates over a hash index still scan.

## Persistence

Two idioms. Manual:

```zig
try db.save(io, "app.qodb");
try db.load(io, "app.qodb"); // a missing file loads as an empty database
```

Or open()-managed, with an autosave policy and dirty tracking:

```zig
var db = try App.open(gpa, io, "app.qodb", .{
    .autosave = .{ .after_writes = 100, .on_close = true },
});
defer db.close(io) catch {}; // flushes a dirty database, then releases it

try db.cols.users.upsert(.{ .id = 1, .email = "ada@x.io", .age = 21 });
try db.checkpoint(io); // flushes when the policy is due; cheap to call often
```

Dirtiness is derived from a per-collection mutation counter (no lock, no background
thread). `flush` serializes and atomically writes only when there are unflushed changes.

## Schema migration

Reordering a struct's fields is invisible - the wire format is canonical (fields sorted by
name), so it changes neither the bytes nor the layout hash, and needs no migration. A real
shape change (add/remove/rename/retype a field) is caught on load.

To evolve a record type, keep the old shape and declare a migration chain on the new type:

```zig
const UserV1 = struct { id: u64, name: []const u8 };

const User = struct {
    id: u64,
    name: []const u8,
    age: u16, // added
    pub const qodb_migrations = .{ up_from_v1 };
    fn up_from_v1(old: UserV1) @This() {
        return .{ .id = old.id, .name = old.name, .age = 0 };
    }
};
```

On load, old records are decoded as the old shape and folded forward to the current type;
the engine derives the version from the chain (no hand-written version number to forget)
and validates at compile time that the chain links and ends at the current type. An
unregistered shape change is a `SchemaMismatch`, never a silent mis-decode.

## Encryption

Encryption is a property of the whole database (one gate over the snapshot), selected at
`open`. Three modes:

```zig
// password: a key derived from a passphrase via Argon2id (pure Zig, no host dependency)
var db = try App.open(gpa, io, "app.qodb", .{
    .encryption = .{ .password = .{ .passphrase = secret } },
});
```

- `password` - Argon2id derives the key once per session from the passphrase and a stored
  salt; each save seals a fresh data key under it (AES-256-GCM).
- `envelope` - a fresh data key per save, wrapped by a host-supplied `KeyProvider` (a
  secure element, an OS keychain, an HSM).
- `keystore_bound` - the provider seals/opens the whole snapshot; the key never leaves it.

The crypto is `std.crypto` AES-256-GCM with a unique IV per save; a wrong passphrase/key or
a tampered file fails authentication (`BadKey`) rather than returning wrong data. qodb never
names or imports a platform key store - that lives behind `KeyProvider`.

## Supported field types

The codec handles ints, floats, bools, enums, arrays, structs, optionals, tagged unions,
and `[]const u8`. Scalars use native width and endianness (qodb is a per-device store);
`[]const u8` is length-prefixed and decoded zero-copy (the value borrows the blob).

## Building

```sh
zig build test   # run the test suite
```
