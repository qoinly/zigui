const zigui = @import("zigui");
const Node = zigui.Node;

// The standard pushed-page shell: a titled column inset below the app bar. Pages
// build their body as `page.screen(&.{ ... })`.
pub fn screen(kids: []const *Node) *Node {
    return zigui.col(.{ .pad = .lg, .gap = .md, .grow = 1 }, kids);
}

pub fn header(title: []const u8) *Node {
    return zigui.text(title, .{ .size = 20, .weight = .semi_bold });
}
