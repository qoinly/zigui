// qodb - a typed, embedded, no-SQL database engine for Zig. A database of named
// collections, type-safe field queries (compile-checked, no SQL), a compact comptime
// codec, schema migration, and optional whole-database encryption.

const collection = @import("collection.zig");

// A typed collection: in-memory CRUD over a struct keyed by one field, the typed query
// iterator, and atomic snapshot persistence.
pub const Collection = collection.Collection;
pub const Config = collection.Config;

// A database: one file of many named collections behind one boundary, with a comptime
// schema and whole-database snapshot persistence.
pub const Database = @import("database.zig").Database;

// The typed query DSL: field predicates (eq/ne/lt/lte/gt/gte/in/between/contains/
// starts_with) and combinators (all/any/not), comptime-composed and compile-checked.
pub const query = @import("query.zig");

// The binary codec: encode/decode any supported Zig value to a compact blob.
pub const codec = @import("codec.zig");

// Whole-snapshot encryption (the database gate): password (Argon2id, pure Zig) or
// envelope / keystore_bound via a host-supplied KeyProvider. The crypto is std.crypto
// AES-256-GCM; any platform key custody lives behind KeyProvider, not in qodb.
pub const secure = @import("secure.zig");

test {
    _ = collection;
    _ = query;
    _ = codec;
    _ = secure;
    _ = @import("database.zig");
}
