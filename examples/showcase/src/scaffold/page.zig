const zigui = @import("zigui");
const Node = zigui.Node;
const Theme = zigui.Theme;

pub fn header(title: []const u8, subtitle: []const u8) *Node {
    return zigui.col(.{ .gap = .xs }, &.{
        zigui.text(title, .{ .size = 24, .weight = .semi_bold }),
        zigui.text(subtitle, .{ .size = 13, .muted = true }),
    });
}

pub fn page(kids: []const *Node) *Node {
    return zigui.col(.{ .pad = .xl, .gap = .lg }, kids);
}

pub fn section(t: *const Theme, title: []const u8, examples: []const *Node) *Node {
    return zigui.col(.{ .gap = .sm }, &.{
        title_label(title),
        zigui.row(.{
            .gap = .md,
            .cross = .center,
            .wrap = true,
            .pad = .lg,
            .bg = t.card,
            .border = t.border,
            .radius = t.radius,
        }, examples),
    });
}

// For kits that draw their own box (textarea, tabs).
pub fn title_label(title: []const u8) *Node {
    return zigui.text(title, .{ .size = 12, .weight = .semi_bold, .muted = true });
}

pub fn sized(w: f32, kid: *Node) *Node {
    return zigui.col(.{ .width = w }, &.{kid});
}
