// A pure-software KeyProvider: wrap/seal are AES-256-GCM under a caller-supplied master
// key (a fresh IV each call). It keeps the master key in process memory, so it does NOT
// match a hardware-backed provider's threat model - it is for host tests and for hosts
// with no secure element yet. Not re-exported from root: a consumer opts in explicitly.

const std = @import("std");
const secure = @import("secure.zig");
const Aes256Gcm = std.crypto.aead.aes_gcm.Aes256Gcm;

const key_len = 32;
const iv_len = Aes256Gcm.nonce_length;
const tag_len = Aes256Gcm.tag_length;

pub const SoftwareKeyProvider = struct {
    master: [key_len]u8,
    io: std.Io,

    const vtable = secure.KeyProvider.VTable{
        .wrap = wrap,
        .unwrap = unwrap,
        .seal = seal,
        .open = open,
    };

    pub fn provider(self: *SoftwareKeyProvider) secure.KeyProvider {
        return .{ .ctx = self, .vtable = &vtable };
    }

    fn wrap(ctx: *anyopaque, dek: *const [key_len]u8, out: []u8) secure.Error!usize {
        const self: *SoftwareKeyProvider = @ptrCast(@alignCast(ctx));
        const n = iv_len + key_len + tag_len;
        std.debug.assert(out.len >= n);
        try seal_into(self.io, out[0..n], dek, self.master);
        return n;
    }
    fn unwrap(ctx: *anyopaque, wrapped: []const u8, dek: *[key_len]u8) secure.Error!void {
        const self: *SoftwareKeyProvider = @ptrCast(@alignCast(ctx));
        if (wrapped.len != iv_len + key_len + tag_len) return error.Corrupt;
        try open_into(dek, wrapped, self.master);
    }
    fn seal(ctx: *anyopaque, gpa: std.mem.Allocator, plain: []const u8) secure.Error![]u8 {
        const self: *SoftwareKeyProvider = @ptrCast(@alignCast(ctx));
        const out = try gpa.alloc(u8, iv_len + plain.len + tag_len);
        errdefer gpa.free(out);
        try seal_into(self.io, out, plain, self.master);
        return out;
    }
    fn open(ctx: *anyopaque, gpa: std.mem.Allocator, sealed: []const u8) secure.Error![]u8 {
        const self: *SoftwareKeyProvider = @ptrCast(@alignCast(ctx));
        if (sealed.len < iv_len + tag_len) return error.Corrupt;
        const out = try gpa.alloc(u8, sealed.len - iv_len - tag_len);
        errdefer gpa.free(out);
        try open_into(out, sealed, self.master);
        return out;
    }
};

// iv | ciphertext | tag into `out` (sized iv_len + plain.len + tag_len).
fn seal_into(io: std.Io, out: []u8, plain: []const u8, key: [key_len]u8) secure.Error!void {
    std.debug.assert(out.len == iv_len + plain.len + tag_len);
    var iv: [iv_len]u8 = undefined;
    try io.randomSecure(&iv);
    @memcpy(out[0..iv_len], &iv);
    const ct = out[iv_len..][0..plain.len];
    Aes256Gcm.encrypt(ct, out[iv_len + plain.len ..][0..tag_len], plain, "", iv, key);
}

fn open_into(out: []u8, sealed: []const u8, key: [key_len]u8) secure.Error!void {
    std.debug.assert(sealed.len == iv_len + out.len + tag_len);
    const iv = sealed[0..iv_len].*;
    const ct = sealed[iv_len .. sealed.len - tag_len];
    const tag = sealed[sealed.len - tag_len ..][0..tag_len].*;
    Aes256Gcm.decrypt(out, ct, tag, "", iv, key) catch return error.BadKey;
}
