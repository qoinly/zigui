const geometry = @import("geometry.zig");
const color = @import("color.zig");
const tokens = @import("theme.zig");

const Rgba = color.Rgba;

pub const Length = union(enum) {
    auto,
    px: f32,
    percent: f32,

    pub const zero = Length{ .px = 0 };
};

// Escape hatch for hand-building a Style directly; the facade wraps these.
pub fn px(v: f32) Length {
    return .{ .px = v };
}
pub fn pct(v: f32) Length {
    return .{ .percent = v };
}
pub fn pad(v: f32) Edges(Length) {
    return Edges(Length).all(.{ .px = v });
}

pub const Display = enum { block, flex, none };

pub const FlexDirection = enum {
    row,
    row_reverse,
    column,
    column_reverse,

    pub fn is_row(self: FlexDirection) bool {
        return self == .row or self == .row_reverse;
    }

    pub fn is_reverse(self: FlexDirection) bool {
        return self == .row_reverse or self == .column_reverse;
    }
};

pub const FlexWrap = enum { no_wrap, wrap, wrap_reverse };

pub const JustifyContent = enum {
    flex_start,
    flex_end,
    center,
    space_between,
    space_around,
    space_evenly,
};

pub const AlignItems = enum {
    flex_start,
    flex_end,
    center,
    stretch,
    baseline,
};

pub const AlignSelf = enum {
    auto,
    flex_start,
    flex_end,
    center,
    stretch,
    baseline,
};

pub const Position = enum { relative, absolute };

pub const Overflow = enum { visible, hidden, scroll };

pub const BoxShadow = struct {
    color: Rgba = Rgba.init(0, 0, 0, 0.25),
    offset_x: f32 = 0,
    offset_y: f32 = 0,
    blur_radius: f32 = 0,
    spread_radius: f32 = 0,

    pub const sm = BoxShadow{ .offset_y = 1, .blur_radius = 3, .color = Rgba.init(0, 0, 0, 0.15) };
    pub const md = BoxShadow{ .offset_y = 4, .blur_radius = 8, .color = Rgba.init(0, 0, 0, 0.2) };
    pub const lg = BoxShadow{ .offset_y = 8, .blur_radius = 16, .color = Rgba.init(0, 0, 0, 0.25) };
    pub const xl = BoxShadow{ .offset_y = 12, .blur_radius = 24, .color = Rgba.init(0, 0, 0, 0.3) };
};

// Distinct from geometry.Edges (extern, numeric): non-extern, takes Length.
pub fn Edges(comptime T: type) type {
    return struct {
        top: T,
        right: T,
        bottom: T,
        left: T,

        const Self = @This();

        pub fn all(value: T) Self {
            return .{ .top = value, .right = value, .bottom = value, .left = value };
        }

        pub fn symmetric(vertical: T, horizontal: T) Self {
            return .{
                .top = vertical,
                .right = horizontal,
                .bottom = vertical,
                .left = horizontal,
            };
        }

        pub fn zero() Self {
            if (T == Length) return all(Length.zero);
            if (T == f32) return all(0);
            @compileError("Edges.zero() requires Length or f32; got " ++ @typeName(T));
        }
    };
}

pub fn Corners(comptime T: type) type {
    return struct {
        top_left: T,
        top_right: T,
        bottom_right: T,
        bottom_left: T,

        const Self = @This();

        pub fn all(value: T) Self {
            return .{
                .top_left = value,
                .top_right = value,
                .bottom_right = value,
                .bottom_left = value,
            };
        }

        pub fn zero() Self {
            return all(0);
        }
    };
}

// Full CSS-flex surface. Fields marked NYI are declared but not yet honored by
// the layout engine - they are silent no-ops, so a hand-built Style can't rely
// on them.
pub const Style = struct {
    display: Display = .flex,
    position: Position = .relative, // NYI: absolute stays in flow
    overflow_x: Overflow = .visible, // NYI: no clip / no scroll content-size
    overflow_y: Overflow = .visible, // NYI

    flex_direction: FlexDirection = .row, // reverse: no-wrap flips order; wrap ignores it (NYI)
    flex_wrap: FlexWrap = .no_wrap, // wrap ok; wrap_reverse NYI (== wrap)
    justify_content: JustifyContent = .flex_start,
    align_items: AlignItems = .stretch, // baseline NYI (falls back to flex_start)

    align_self: AlignSelf = .auto,
    flex_grow: f32 = 0,
    flex_shrink: f32 = 1, // overflow shrinks by shrink*base, floored at min size
    flex_basis: Length = .auto,

    width: Length = .auto,
    height: Length = .auto,
    min_width: Length = .auto, // clamps resolved width (min wins over max)
    min_height: Length = .auto, // clamps resolved height (min wins over max)
    max_width: Length = .auto,
    max_height: Length = .auto,

    margin: Edges(Length) = Edges(Length).zero(), // NYI: no offset/consumption
    padding: Edges(Length) = Edges(Length).zero(), // px only (percent NYI)
    inset: Edges(Length) = Edges(Length).all(.auto), // NYI

    row_gap: Length = Length.zero, // px only (percent NYI)
    column_gap: Length = Length.zero, // px only (percent NYI)

    background: ?Rgba = null,
    border_color: ?Rgba = null,
    border_widths: Edges(f32) = Edges(f32).zero(),
    corner_radii: Corners(f32) = Corners(f32).zero(),
    box_shadow: ?BoxShadow = null,

    // Honored only on a wrap row: the engine slices the row into N equal tracks
    // (N resolved from the container width) instead of greedy width packing.
    grid_cols: ?tokens.GridCols = null,
};
