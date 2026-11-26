// Unit-test a view's layout without a window. Build the tree with the normal builders
// between begin() and layout(), then check the boxes by name. See docs/debugging.md.
const std = @import("std");
const node = @import("node.zig");
const layout_engine = @import("layout.zig");
const frame_ctx = @import("frame_ctx.zig");
const paint = @import("window/paint.zig");
const types = @import("window/types.zig");
const geometry = @import("geometry.zig");

pub const Rect = node.Rect;

// Builders keep a paint pointer for hover and clicks, which only matter when drawing.
// Nothing here draws, so they get this placeholder and never read it.
var no_paint: paint.PaintContext = undefined;

pub const Layout = struct {
    arena: std.heap.ArenaAllocator,
    eng: layout_engine.LayoutEngine,
    theme: types.Theme,
    fc: frame_ctx.FrameCtx = undefined,
    size: geometry.SizeF,
    rects: std.ArrayList(Rect) = .empty,
    building: bool = false,

    pub fn init(gpa: std.mem.Allocator, width: f32, height: f32) Layout {
        return .{
            .arena = std.heap.ArenaAllocator.init(gpa),
            .eng = layout_engine.LayoutEngine.init(gpa),
            .theme = types.Theme.default_dark(),
            .size = .{ .width = width, .height = height },
        };
    }

    pub fn deinit(self: *Layout) void {
        if (self.building) frame_ctx.leave();
        self.eng.deinit();
        self.arena.deinit();
    }

    // Make the builders usable. `state` is what callbacks would receive; pass null if
    // the view has no clicks to wire.
    pub fn begin(self: *Layout, state: ?*anyopaque) void {
        std.debug.assert(!self.building);
        self.fc = .{
            .arena = self.arena.allocator(),
            .theme = &self.theme,
            .paint = &no_paint,
            .state = state,
        };
        frame_ctx.enter(&self.fc);
        self.building = true;
    }

    // Lay out the tree built since begin() and record every node.
    pub fn layout(self: *Layout, root: *node.Node) !void {
        std.debug.assert(self.building);
        frame_ctx.leave();
        self.building = false;
        self.rects.clearRetainingCapacity();
        try node.layout_rects(&self.eng, self.arena.allocator(), root, self.size, &self.rects);
    }

    // The first node with this name, in draw order.
    pub fn find(self: *const Layout, name: []const u8) ?Rect {
        for (self.rects.items) |r| if (std.mem.eql(u8, r.name, name)) return r;
        return null;
    }

    // Like find, but fails the test with a clear message when the name is missing.
    pub fn get(self: *const Layout, name: []const u8) !Rect {
        return self.find(name) orelse {
            std.debug.print("zigui.testing: no node named \"{s}\"\n", .{name});
            return error.NodeNotFound;
        };
    }
};

const zigui = @import("root.zig");
const expectEqual = std.testing.expectEqual;

test "two grow cells with basis 0 split a row exactly" {
    var t = Layout.init(std.testing.allocator, 400, 100);
    defer t.deinit();
    t.begin(null);
    const root = zigui.row(.{ .gap = .{ .px = 10 } }, &.{
        zigui.col(.{ .name = "a", .grow = 1, .basis = 0 }, &.{zigui.text("Short", .{})}),
        zigui.col(.{ .name = "b", .grow = 1, .basis = 0 }, &.{zigui.text("A much longer label", .{})}),
    });
    try t.layout(root);
    const a = try t.get("a");
    const b = try t.get("b");
    try expectEqual(@as(f32, 195), a.w);
    try expectEqual(a.w, b.w);
    try expectEqual(@as(f32, 205), b.x);
}

test "a shrink 0 badge keeps its width next to a long truncating label" {
    var t = Layout.init(std.testing.allocator, 300, 100);
    defer t.deinit();
    t.begin(null);
    const root = zigui.row(.{}, &.{
        zigui.col(.{ .name = "label", .grow = 1, .min_width = 0 }, &.{
            zigui.text("A label far too long to fit in a three hundred point row at all", .{ .truncate = true }),
        }),
        zigui.col(.{ .name = "badge", .width = 48, .height = 22, .shrink = 0 }, &.{}),
    });
    try t.layout(root);
    try expectEqual(@as(f32, 48), (try t.get("badge")).w);
    try expectEqual(@as(f32, 252), (try t.get("label")).w);
}

test "a layers box is as wide as its widest child" {
    var t = Layout.init(std.testing.allocator, 200, 200);
    defer t.deinit();
    t.begin(null);
    const root = zigui.col(.{ .width = 44, .height = 44, .cross = .center }, &.{zigui.layers(&.{
        zigui.col(.{ .name = "disc", .width = 34, .height = 34 }, &.{}),
        zigui.row(.{ .name = "badge_row", .width = 34, .height = 10, .justify = .flex_end }, &.{}),
    })});
    try t.layout(root);
    const disc = try t.get("disc");
    try expectEqual(@as(f32, 34), disc.w);
    try expectEqual(@as(f32, 5), disc.x);
}

test "a badge hangs over the rim when the layers box is padded out (docs/layout.md)" {
    var t = Layout.init(std.testing.allocator, 200, 200);
    defer t.deinit();
    t.begin(null);
    const out = 4;
    const root = zigui.col(.{ .width = 34 + 2 * out, .height = 34 + 2 * out, .shrink = 0 }, &.{zigui.layers(&.{
        zigui.col(.{ .pad = .{ .px = out } }, &.{zigui.col(.{ .name = "disc", .width = 34, .height = 34 }, &.{})}),
        zigui.row(.{ .justify = .flex_end }, &.{zigui.col(.{ .name = "badge", .width = 14, .height = 14 }, &.{})}),
    })});
    try t.layout(root);
    const disc = try t.get("disc");
    const badge = try t.get("badge");
    try expectEqual(@as(f32, 4), disc.x);
    try expectEqual(@as(f32, 4), disc.y);
    // The badge's right edge is 4 past the disc's, and its top is 4 above it.
    try expectEqual(disc.x + disc.w + out, badge.x + badge.w);
    try expectEqual(disc.y - out, badge.y);
}
