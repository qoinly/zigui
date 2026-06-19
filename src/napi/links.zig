// Outbound links: open a url, share text.
const p = @import("platform.zig");
const impl = p.domain("links");

pub fn open_url(url: []const u8) void {
    if (@hasDecl(impl, "open_url")) impl.open_url(url) else p.unsupported("links.open_url");
}
pub fn share_text(text: []const u8) void {
    if (@hasDecl(impl, "share_text")) impl.share_text(text) else p.unsupported("links.share_text");
}
