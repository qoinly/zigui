// Whole-snapshot encryption: seal a serialized image to one ciphertext file and open it
// back. The unit is a byte buffer (a database or collection snapshot), so an encrypted
// store is just a store whose image is ciphertext. One seal per save, one open per load
// (whole-image AES-256-GCM); no per-record crypto.
//
// Three modes:
//   password        - the key is derived from a passphrase via Argon2id (pure Zig, no
//                     host dependency). The caller derives the key once per session (the
//                     KDF is slow) and passes it with the salt; a fresh DEK is sealed
//                     under it each save, so the per-save path is fast.
//   envelope        - a fresh 32-byte DEK each save seals the image; a host KeyProvider
//                     wraps the DEK under a non-exportable key. The DEK is zeroed after.
//   keystore_bound  - the provider seals/opens the whole image itself; the key never
//                     leaves it and qodb does no bulk crypto.

const std = @import("std");
const Aes256Gcm = std.crypto.aead.aes_gcm.Aes256Gcm;

pub const Error = error{
    Corrupt, // the file is truncated, mis-tagged, or carries trailing bytes
    BadKey, // GCM auth failed: the wrong key/passphrase, or the file was tampered with
    EntropyUnavailable, // randomSecure could not obtain fresh entropy
    Canceled, // the io operation was canceled
} || std.mem.Allocator.Error;

const dek_len = 32;
const iv_len = Aes256Gcm.nonce_length;
const tag_len = Aes256Gcm.tag_length;
const wrap_len = iv_len + dek_len + tag_len; // a DEK sealed under another key (GCM)
pub const salt_len = 16;
const magic = "QODBSEC1".*;

const Mode = enum(u8) { password, envelope, keystore_bound };

// Argon2id work factors (the caller may raise them). The defaults are a moderate
// interactive cost; t = passes, m = memory in KiB, p = lanes.
pub const Argon = struct { t: u32 = 3, m: u32 = 19456, p: u24 = 1 };

// A passphrase-derived key plus the salt it was derived with. The salt is stored in the
// file (cleartext), so the next open re-derives the same key; derive() produces this.
pub const Password = struct { key: [dek_len]u8, salt: [salt_len]u8 };

// The platform half of the secure path, supplied by the host (a hardware secure element,
// an OS keychain, an HSM; host tests pass a software provider). qodb calls only the pair
// its mode needs: wrap/unwrap for envelope, seal/open for keystore_bound.
pub const KeyProvider = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        wrap: *const fn (ctx: *anyopaque, dek: *const [dek_len]u8, out: []u8) Error!usize,
        unwrap: *const fn (ctx: *anyopaque, wrapped: []const u8, dek: *[dek_len]u8) Error!void,
        seal: *const fn (ctx: *anyopaque, gpa: std.mem.Allocator, plain: []const u8) Error![]u8,
        open: *const fn (ctx: *anyopaque, gpa: std.mem.Allocator, sealed: []const u8) Error![]u8,
    };

    // An upper bound on a wrapped DEK (an RSA-2048 key wrap is 256 bytes; an AES-GCM
    // wrap is 60). The wrap buffer is stack-sized to this.
    pub const WRAP_MAX = 256;
};

pub const Security = union(enum) {
    password: Password,
    envelope: KeyProvider,
    keystore_bound: KeyProvider,
};

// Derive a 32-byte key from `passphrase` and `salt` via Argon2id. Slow by design - run
// once per session, not per save. KDF errors propagate as themselves (an out-of-memory or
// canceled derivation is NOT a wrong-passphrase; it must not be reported as one).
pub fn derive(
    gpa: std.mem.Allocator,
    io: std.Io,
    passphrase: []const u8,
    salt: [salt_len]u8,
    params: Argon,
) ![dek_len]u8 {
    std.debug.assert(passphrase.len != 0); // an empty passphrase is a caller error
    var key: [dek_len]u8 = undefined;
    const p = std.crypto.pwhash.argon2.Params{ .t = params.t, .m = params.m, .p = params.p };
    try std.crypto.pwhash.argon2.kdf(gpa, &key, passphrase, &salt, p, .argon2id, io);
    return key;
}

// The salt a password-mode file was written with, so the caller can re-derive its key
// before opening. Null if the file is not password mode (or is malformed).
pub fn read_salt(file: []const u8) ?[salt_len]u8 {
    var r = Reader{ .buf = file };
    if (!r.match(&magic)) return null;
    if ((r.byte() orelse return null) != @intFromEnum(Mode.password)) return null;
    const meta = r.slice(r.read_u32() catch return null) catch return null;
    if (meta.len < salt_len) return null;
    return meta[0..salt_len].*;
}

// Seal `plain` into a caller-freed ciphertext file under `sec`.
pub fn seal(gpa: std.mem.Allocator, io: std.Io, plain: []const u8, sec: Security) Error![]u8 {
    switch (sec) {
        .password => |pw| {
            var dek: [dek_len]u8 = undefined;
            defer std.crypto.secureZero(u8, &dek);
            try io.randomSecure(&dek);
            var meta: [salt_len + wrap_len]u8 = undefined;
            @memcpy(meta[0..salt_len], &pw.salt);
            try gcm_wrap(io, meta[salt_len..][0..wrap_len], &dek, pw.key);
            return seal_dek(gpa, io, plain, .password, &meta, dek);
        },
        .envelope => |provider| {
            var dek: [dek_len]u8 = undefined;
            defer std.crypto.secureZero(u8, &dek);
            try io.randomSecure(&dek);
            var wrapped: [KeyProvider.WRAP_MAX]u8 = undefined;
            const wlen = try provider.vtable.wrap(provider.ctx, &dek, &wrapped);
            std.debug.assert(wlen <= wrapped.len);
            return seal_dek(gpa, io, plain, .envelope, wrapped[0..wlen], dek);
        },
        .keystore_bound => |provider| {
            const sealed = try provider.vtable.seal(provider.ctx, gpa, plain);
            defer gpa.free(sealed);
            const file = try alloc_frame(gpa, "", sealed.len);
            var w = Writer{ .buf = file };
            w.header(.keystore_bound, "", sealed.len);
            w.put(sealed);
            std.debug.assert(w.n == file.len);
            return file;
        },
    }
}

// file = magic | mode | u32 meta_len | meta | u32 body_len | body; body = iv | ct | tag.
fn seal_dek(
    gpa: std.mem.Allocator,
    io: std.Io,
    plain: []const u8,
    mode: Mode,
    meta: []const u8,
    dek: [dek_len]u8,
) Error![]u8 {
    var iv: [iv_len]u8 = undefined;
    try io.randomSecure(&iv);
    const body_len = iv_len + plain.len + tag_len;
    const file = try alloc_frame(gpa, meta, body_len);
    errdefer gpa.free(file);
    var w = Writer{ .buf = file };
    w.header(mode, meta, body_len);
    w.put(&iv);
    Aes256Gcm.encrypt(w.take(plain.len), w.take(tag_len)[0..tag_len], plain, "", iv, dek);
    std.debug.assert(w.n == file.len);
    return file;
}

// Open a ciphertext `file` to a caller-freed plaintext image under `sec`.
pub fn open(gpa: std.mem.Allocator, file: []const u8, sec: Security) Error![]u8 {
    var r = Reader{ .buf = file };
    if (!r.match(&magic)) return error.Corrupt;
    const want: Mode = switch (sec) {
        .password => .password,
        .envelope => .envelope,
        .keystore_bound => .keystore_bound,
    };
    if ((r.byte() orelse return error.Corrupt) != @intFromEnum(want)) return error.BadKey;
    const meta = try r.slice(try r.read_u32());
    const body = try r.slice(try r.read_u32());
    if (r.n != file.len) return error.Corrupt; // trailing bytes -> malformed

    switch (sec) {
        .password => |pw| {
            if (meta.len != salt_len + wrap_len) return error.Corrupt;
            var dek: [dek_len]u8 = undefined;
            defer std.crypto.secureZero(u8, &dek);
            try gcm_unwrap(&dek, meta[salt_len..], pw.key);
            return open_dek(gpa, body, dek);
        },
        .envelope => |provider| {
            var dek: [dek_len]u8 = undefined;
            defer std.crypto.secureZero(u8, &dek);
            try provider.vtable.unwrap(provider.ctx, meta, &dek);
            return open_dek(gpa, body, dek);
        },
        .keystore_bound => |provider| {
            if (meta.len != 0) return error.Corrupt; // no meta in this mode
            return provider.vtable.open(provider.ctx, gpa, body);
        },
    }
}

fn open_dek(gpa: std.mem.Allocator, body: []const u8, dek: [dek_len]u8) Error![]u8 {
    if (body.len < iv_len + tag_len) return error.Corrupt;
    const iv = body[0..iv_len].*;
    const ct = body[iv_len .. body.len - tag_len];
    const tag = body[body.len - tag_len ..][0..tag_len].*;
    const plain = try gpa.alloc(u8, ct.len);
    errdefer gpa.free(plain);
    Aes256Gcm.decrypt(plain, ct, tag, "", iv, dek) catch return error.BadKey;
    return plain;
}

// Seal a DEK under `key` into `out` (iv | ciphertext | tag), fresh IV.
fn gcm_wrap(io: std.Io, out: *[wrap_len]u8, dek: *const [dek_len]u8, key: [dek_len]u8) Error!void {
    try io.randomSecure(out[0..iv_len]);
    const iv = out[0..iv_len].*;
    const ct = out[iv_len..][0..dek_len];
    Aes256Gcm.encrypt(ct, out[iv_len + dek_len ..][0..tag_len], dek, "", iv, key);
}

fn gcm_unwrap(out: *[dek_len]u8, wrapped: []const u8, key: [dek_len]u8) Error!void {
    if (wrapped.len != wrap_len) return error.Corrupt;
    const iv = wrapped[0..iv_len].*;
    const ct = wrapped[iv_len..][0..dek_len];
    const tag = wrapped[iv_len + dek_len ..][0..tag_len].*;
    Aes256Gcm.decrypt(out, ct, tag, "", iv, key) catch return error.BadKey;
}

fn alloc_frame(gpa: std.mem.Allocator, meta: []const u8, body_len: usize) Error![]u8 {
    const total = magic.len + 1 + @sizeOf(u32) + meta.len + @sizeOf(u32) + body_len;
    return gpa.alloc(u8, total);
}

const Writer = struct {
    buf: []u8,
    n: usize = 0,

    fn header(w: *Writer, mode: Mode, meta: []const u8, body_len: usize) void {
        std.debug.assert(meta.len <= std.math.maxInt(u32));
        std.debug.assert(body_len <= std.math.maxInt(u32));
        w.put(&magic);
        w.put(&[_]u8{@intFromEnum(mode)});
        w.put_u32(@intCast(meta.len));
        w.put(meta);
        w.put_u32(@intCast(body_len));
    }

    fn put(w: *Writer, bytes: []const u8) void {
        @memcpy(w.buf[w.n..][0..bytes.len], bytes);
        w.n += bytes.len;
    }
    fn put_u32(w: *Writer, v: u32) void {
        w.put(std.mem.asBytes(&v));
    }
    fn take(w: *Writer, len: usize) []u8 {
        const out = w.buf[w.n..][0..len];
        w.n += len;
        return out;
    }
};

const Reader = struct {
    buf: []const u8,
    n: usize = 0,

    fn match(r: *Reader, want: []const u8) bool {
        const got = r.slice(want.len) catch return false;
        return std.mem.eql(u8, got, want);
    }
    fn byte(r: *Reader) ?u8 {
        if (r.n >= r.buf.len) return null;
        defer r.n += 1;
        return r.buf[r.n];
    }
    fn read_u32(r: *Reader) Error!u32 {
        const s = try r.slice(@sizeOf(u32));
        var v: u32 = undefined;
        @memcpy(std.mem.asBytes(&v), s);
        return v;
    }
    fn slice(r: *Reader, len: usize) Error![]const u8 {
        std.debug.assert(r.n <= r.buf.len); // the cursor never passes the end
        if (len > r.buf.len - r.n) return error.Corrupt; // subtract: `n + len` could overflow
        defer r.n += len;
        return r.buf[r.n..][0..len];
    }
};

const testing = std.testing;
const SoftwareKeyProvider = @import("software_keystore.zig").SoftwareKeyProvider;
const marker = "topsecret-plaintext-marker";

fn roundtrip(sec: Security, io: std.Io) !void {
    const gpa = testing.allocator;
    const plain = marker ++ "-and-more-body-bytes";
    const file = try seal(gpa, io, plain, sec);
    defer gpa.free(file);
    try testing.expect(std.mem.indexOf(u8, file, marker) == null); // ciphertext, not cleartext
    const got = try open(gpa, file, sec);
    defer gpa.free(got);
    try testing.expectEqualStrings(plain, got);
}

test "password mode round-trips and the file is ciphertext" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const salt = [_]u8{3} ** salt_len;
    const key = try derive(testing.allocator, io, "correct horse", salt, .{ .t = 1, .m = 256 });
    try roundtrip(.{ .password = .{ .key = key, .salt = salt } }, io);
}

test "envelope and keystore_bound round-trip via a provider" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var ks = SoftwareKeyProvider{ .master = @splat(7), .io = io };
    try roundtrip(.{ .envelope = ks.provider() }, io);
    try roundtrip(.{ .keystore_bound = ks.provider() }, io);
}

test "a wrong passphrase, wrong key, and mode mismatch are rejected" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;
    const salt = [_]u8{1} ** salt_len;
    const key = try derive(gpa, io, "right", salt, .{ .t = 1, .m = 256 });
    const file = try seal(gpa, io, "body", .{ .password = .{ .key = key, .salt = salt } });
    defer gpa.free(file);

    try testing.expectEqualSlices(u8, &salt, &read_salt(file).?);
    const wrong = try derive(gpa, io, "wrong", salt, .{ .t = 1, .m = 256 });
    const bad = Security{ .password = .{ .key = wrong, .salt = salt } };
    try testing.expectError(error.BadKey, open(gpa, file, bad));

    var ks = SoftwareKeyProvider{ .master = @splat(9), .io = io };
    try testing.expectError(error.BadKey, open(gpa, file, .{ .envelope = ks.provider() }));
}
