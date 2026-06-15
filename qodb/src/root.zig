// qodb - a typed, embedded, no-SQL data store for Zig apps. Collections of structs,
// type-safe field queries (compile-checked, no SQL), and a compact comptime codec.

const collection = @import("collection.zig");

// A typed collection: in-memory CRUD over a struct keyed by one field, the typed query
// iterator, and atomic snapshot persistence.
pub const Collection = collection.Collection;
pub const Config = collection.Config;

// The typed query DSL: field predicates (eq/ne/lt/lte/gt/gte/in/between/contains/
// starts_with) and combinators (all/any/not), comptime-composed and compile-checked.
pub const query = @import("query.zig");

// The binary codec: encode/decode any supported Zig value to a compact blob.
pub const codec = @import("codec.zig");

test {
    _ = collection;
    _ = query;
    _ = codec;
}
