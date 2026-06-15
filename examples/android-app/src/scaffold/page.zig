const zigui = @import("zigui");
const Node = zigui.Node;

// The standard pushed-page shell: a titled column inset below the app bar. Pages
// build their body as `page.screen(&.{ page.header("Title"), ... })`.
pub fn screen(kids: []const *Node) *Node {
    return zigui.col(.{ .pad = .lg, .gap = .md, .grow = 1 }, kids);
}

pub fn header(title: []const u8) *Node {
    return zigui.text(title, .{ .size = 20, .weight = .semi_bold });
}

// A small muted status line - the "(no result yet)" read-backs each page shows.
pub fn note(text: []const u8) *Node {
    return zigui.text(text, .{ .size = 12, .muted = true });
}

// A status line at body text size (battery, service-enabled, a returned value).
pub fn status(text: []const u8) *Node {
    return zigui.text(text, .{ .size = 16 });
}
