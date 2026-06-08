// Breakpoints key on a CONTAINER width (container-query semantics), for the
// three reflows flexbox can't derive from width alone: axis flip, child count,
// show/hide.

const std = @import("std");

pub const Spacing = union(enum) {
    none,
    xs,
    sm,
    md,
    lg,
    xl,
    xxl,
    px: f32,

    pub fn resolve(self: Spacing) f32 {
        return switch (self) {
            .none => 0,
            .xs => 4,
            .sm => 8,
            .md => 12,
            .lg => 16,
            .xl => 24,
            .xxl => 32,
            .px => |v| v,
        };
    }
};

pub const Breakpoint = enum(u8) { base = 0, sm, md, lg, xl };

const BP_PX = [_]f32{ 0, 640, 768, 1024, 1280 };

pub const Width = struct {
    px: f32,

    pub fn at(self: Width) Breakpoint {
        var b: Breakpoint = .base;
        inline for (.{ Breakpoint.sm, Breakpoint.md, Breakpoint.lg, Breakpoint.xl }) |cand| {
            if (self.px >= BP_PX[@intFromEnum(cand)]) b = cand;
        }
        return b;
    }

    pub fn ge(self: Width, b: Breakpoint) bool {
        return self.px >= BP_PX[@intFromEnum(b)];
    }

    pub fn lt(self: Width, b: Breakpoint) bool {
        return !self.ge(b);
    }

    pub fn at_least(self: Width, edge: f32) bool {
        return self.px >= edge;
    }
};

// Responsive column count for a wrap-grid, resolved per frame against the
// CONTAINER width (a true container query) so one tree reflows with no caller
// branching. Tailwind-style cascade: widest matching breakpoint wins.
pub const GridCols = struct {
    base: u8 = 1,
    sm: ?u8 = null,
    md: ?u8 = null,
    lg: ?u8 = null,
    xl: ?u8 = null,

    // Floored at 1: the layout engine divides by and steps the grid loop by this,
    // so 0 would be a div-by-zero / non-terminating step.
    pub fn resolve(self: GridCols, width: f32) u8 {
        var cols = self.base;
        if (self.sm) |v| if (width >= BP_PX[@intFromEnum(Breakpoint.sm)]) {
            cols = v;
        };
        if (self.md) |v| if (width >= BP_PX[@intFromEnum(Breakpoint.md)]) {
            cols = v;
        };
        if (self.lg) |v| if (width >= BP_PX[@intFromEnum(Breakpoint.lg)]) {
            cols = v;
        };
        if (self.xl) |v| if (width >= BP_PX[@intFromEnum(Breakpoint.xl)]) {
            cols = v;
        };
        const out = @max(cols, 1);
        std.debug.assert(out >= 1);
        return out;
    }
};

pub fn bp(width: f32) Width {
    return .{ .px = width };
}

// Continuous scaling for gap/pad/font where a breakpoint jump would read as a
// visible step.
pub fn fluid(width: f32, w0: f32, w1: f32, lo: f32, hi: f32) f32 {
    std.debug.assert(w1 > w0);
    if (width <= w0) return lo;
    if (width >= w1) return hi;
    return lo + (hi - lo) * (width - w0) / (w1 - w0);
}

test "spacing resolves the scale + px escape" {
    const md: Spacing = .md;
    const none: Spacing = .none;
    try std.testing.expect(md.resolve() == 12);
    try std.testing.expect((Spacing{ .px = 7 }).resolve() == 7);
    try std.testing.expect(none.resolve() == 0);
}

test "breakpoint queries" {
    const w = bp(800);
    try std.testing.expect(w.at() == .md);
    try std.testing.expect(w.ge(.md));
    try std.testing.expect(w.lt(.lg));
    try std.testing.expect(w.at_least(768));
    try std.testing.expect(!w.at_least(801));
}

test "fluid clamps and lerps" {
    try std.testing.expect(fluid(0, 640, 1280, 8, 20) == 8);
    try std.testing.expect(fluid(2000, 640, 1280, 8, 20) == 20);
    try std.testing.expect(fluid(960, 640, 1280, 8, 20) == 14);
}

test "GridCols cascades like Tailwind and holds undefined breakpoints" {
    const g = GridCols{ .base = 1, .sm = 2, .xl = 4 };
    try std.testing.expect(g.resolve(500) == 1); // below sm
    try std.testing.expect(g.resolve(700) == 2); // >= sm
    try std.testing.expect(g.resolve(1024) == 2); // lg undefined -> holds sm's 2
    try std.testing.expect(g.resolve(1300) == 4); // >= xl
    // base 0 would divide by zero downstream; resolve floors at 1.
    try std.testing.expect((GridCols{ .base = 0 }).resolve(99) == 1);
}
