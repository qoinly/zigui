// System notifications.
const p = @import("platform.zig");
const impl = p.domain("notifications");

pub fn post(title: []const u8, body: []const u8) void {
    if (@hasDecl(impl, "post")) impl.post(title, body) else p.unsupported("notifications.post");
}
