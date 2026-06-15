// qodb - a typed, embedded, no-SQL data store for Zig apps. Collections of structs,
// type-safe field queries (compile-checked, no SQL), a compact comptime codec, and
// optional per-collection encryption.

// The binary codec: encode/decode any supported Zig value to a compact blob.
pub const codec = @import("codec.zig");

test {
    _ = codec;
}
