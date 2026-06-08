const std = @import("std");

pub const Corner = enum {
    top_left,
    top_right,
    bottom_left,
    bottom_right,

    pub fn opposite(self: Corner) Corner {
        return switch (self) {
            .top_left => .bottom_right,
            .top_right => .bottom_left,
            .bottom_left => .top_right,
            .bottom_right => .top_left,
        };
    }

    pub fn flip_horizontal(self: Corner) Corner {
        return switch (self) {
            .top_left => .top_right,
            .top_right => .top_left,
            .bottom_left => .bottom_right,
            .bottom_right => .bottom_left,
        };
    }

    pub fn flip_vertical(self: Corner) Corner {
        return switch (self) {
            .top_left => .bottom_left,
            .top_right => .bottom_right,
            .bottom_left => .top_left,
            .bottom_right => .top_right,
        };
    }
};

pub fn Point(comptime T: type) type {
    return extern struct {
        x: T = 0,
        y: T = 0,

        const Self = @This();

        pub fn init(x: T, y: T) Self {
            return .{ .x = x, .y = y };
        }
    };
}

pub fn Size(comptime T: type) type {
    return extern struct {
        width: T = 0,
        height: T = 0,

        const Self = @This();

        pub fn init(width: T, height: T) Self {
            return .{ .width = width, .height = height };
        }
    };
}

// Coordinate system: origin = top-left, +x right, +y down.
pub fn Bounds(comptime T: type) type {
    return extern struct {
        origin: Point(T) = .{},
        size: Size(T) = .{},

        const Self = @This();

        pub fn init(x: T, y: T, width: T, height: T) Self {
            // Skip for unsigned T (atlas tile rects): width >= 0 is a tautology there.
            const signed = comptime switch (@typeInfo(T)) {
                .int => |i| i.signedness == .signed,
                .float => true,
                else => false,
            };
            if (signed) {
                std.debug.assert(width >= 0);
                std.debug.assert(height >= 0);
            }
            return .{
                .origin = Point(T).init(x, y),
                .size = Size(T).init(width, height),
            };
        }

        pub fn contains(self: Self, point: Point(T)) bool {
            return point.x >= self.origin.x and
                point.x < self.origin.x + self.size.width and
                point.y >= self.origin.y and
                point.y < self.origin.y + self.size.height;
        }

        pub fn intersection(self: Self, other: Self) Self {
            const x1 = @max(self.origin.x, other.origin.x);
            const y1 = @max(self.origin.y, other.origin.y);
            const x2 = @min(self.origin.x + self.size.width, other.origin.x + other.size.width);
            const y2 = @min(self.origin.y + self.size.height, other.origin.y + other.size.height);

            return .{
                .origin = .{ .x = x1, .y = y1 },
                .size = .{
                    .width = @max(0, x2 - x1),
                    .height = @max(0, y2 - y1),
                },
            };
        }

        pub fn to_array(self: Self) [4]T {
            return .{ self.origin.x, self.origin.y, self.size.width, self.size.height };
        }

        pub fn left(self: Self) T {
            return self.origin.x;
        }

        pub fn right(self: Self) T {
            return self.origin.x + self.size.width;
        }

        pub fn top(self: Self) T {
            return self.origin.y;
        }

        pub fn bottom(self: Self) T {
            return self.origin.y + self.size.height;
        }

        pub fn top_left(self: Self) Point(T) {
            return self.origin;
        }

        pub fn top_right(self: Self) Point(T) {
            return .{ .x = self.origin.x + self.size.width, .y = self.origin.y };
        }

        pub fn bottom_left(self: Self) Point(T) {
            return .{ .x = self.origin.x, .y = self.origin.y + self.size.height };
        }

        pub fn bottom_right(self: Self) Point(T) {
            return .{ .x = self.origin.x + self.size.width, .y = self.origin.y + self.size.height };
        }

        pub fn corner(self: Self, c: Corner) Point(T) {
            return switch (c) {
                .top_left => self.top_left(),
                .top_right => self.top_right(),
                .bottom_left => self.bottom_left(),
                .bottom_right => self.bottom_right(),
            };
        }

        pub fn from_corner_and_size(c: Corner, origin: Point(T), s: Size(T)) Self {
            const adjusted: Point(T) = switch (c) {
                .top_left => origin,
                .top_right => .{ .x = origin.x - s.width, .y = origin.y },
                .bottom_left => .{ .x = origin.x, .y = origin.y - s.height },
                .bottom_right => .{ .x = origin.x - s.width, .y = origin.y - s.height },
            };
            return .{ .origin = adjusted, .size = s };
        }
    };
}

pub fn Corners(comptime T: type) type {
    return extern struct {
        top_left: T = 0,
        top_right: T = 0,
        bottom_left: T = 0,
        bottom_right: T = 0,

        const Self = @This();

        pub fn all(value: T) Self {
            return .{
                .top_left = value,
                .top_right = value,
                .bottom_left = value,
                .bottom_right = value,
            };
        }
    };
}

// Edge order = top, right, bottom, left.
pub fn Edges(comptime T: type) type {
    return extern struct {
        top: T = 0,
        right: T = 0,
        bottom: T = 0,
        left: T = 0,

        const Self = @This();

        pub fn all(value: T) Self {
            return .{ .top = value, .right = value, .bottom = value, .left = value };
        }
    };
}

pub const PointF = Point(f32);
pub const SizeF = Size(f32);
pub const BoundsF = Bounds(f32);

// Space a layout offers a component's measure(); null on an axis = unconstrained
// (return the intrinsic extent there). A component honours a constraint only if
// it flexes on that axis (e.g. text wrapping to width); fixed components ignore it.
pub const SizeProposal = struct {
    width: ?f32 = null,
    height: ?f32 = null,
    // The layout's min-content probe: report the smallest extent the component can
    // take (text => its widest word), independent of width/height. A real 0 offer
    // still means "0 space", so the floor query can't be confused with it.
    min_content: bool = false,
};
pub const CornersF = Corners(f32);
pub const EdgesF = Edges(f32);

pub const PointI = Point(i32);
pub const SizeI = Size(i32);
pub const BoundsI = Bounds(i32);

pub const ContentMask = struct {
    bounds: Bounds(f32),

    pub fn intersect(self: ContentMask, other: ContentMask) ContentMask {
        return .{ .bounds = self.bounds.intersection(other.bounds) };
    }

    // Bounds wide enough to act as "no clip" for any practical render.
    pub fn full() ContentMask {
        return .{
            .bounds = .{
                .origin = .{ .x = -1e9, .y = -1e9 },
                .size = .{ .width = 2e9, .height = 2e9 },
            },
        };
    }

    pub fn to_array(self: ContentMask) [4]f32 {
        return self.bounds.to_array();
    }
};

test "Bounds contains and intersection" {
    const b = BoundsF.init(0, 0, 100, 100);
    try std.testing.expect(b.contains(PointF.init(50, 50)));
    try std.testing.expect(!b.contains(PointF.init(100, 50)));

    const a = BoundsF.init(50, 50, 100, 100);
    const c = b.intersection(a);
    try std.testing.expect(c.origin.x == 50 and c.origin.y == 50);
    try std.testing.expect(c.size.width == 50 and c.size.height == 50);
}

test "Corner flips and opposite" {
    try std.testing.expect(Corner.top_left.opposite() == .bottom_right);
    try std.testing.expect(Corner.top_left.flip_horizontal() == .top_right);
    try std.testing.expect(Corner.top_left.flip_vertical() == .bottom_left);
}
