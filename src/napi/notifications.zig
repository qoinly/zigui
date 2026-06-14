// System notifications.
const p = @import("platform.zig");
const impl = p.domain("notifications");

pub fn post(title: []const u8, body: []const u8) void {
    if (@hasDecl(impl, "post")) impl.post(title, body) else p.unsupported("notifications.post");
}
// A transient overlay message (Android toast); no channel or permission needed.
pub fn toast(text: []const u8) void {
    if (@hasDecl(impl, "toast")) impl.toast(text) else p.unsupported("notifications.toast");
}
