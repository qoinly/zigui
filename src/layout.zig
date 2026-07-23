const std = @import("std");
const geometry = @import("geometry.zig");
const styles = @import("style.zig");

const Bounds = geometry.Bounds;
const Size = geometry.Size;
const SizeProposal = geometry.SizeProposal;
const Point = geometry.Point;
const Style = styles.Style;
const Length = styles.Length;
const Display = styles.Display;
const FlexDirection = styles.FlexDirection;
const JustifyContent = styles.JustifyContent;
const AlignItems = styles.AlignItems;

// Layout traversal recurses on the tree; cap depth so a malformed tree
// can't blow the stack. Real UI hierarchies sit well under this.
pub const MAX_LAYOUT_DEPTH: u32 = 64;

pub const LayoutId = struct {
    index: u32,

    pub const nil = LayoutId{ .index = std.math.maxInt(u32) };

    pub fn is_nil(self: LayoutId) bool {
        return self.index == std.math.maxInt(u32);
    }
};

// Reports a leaf's size given the space the engine offers (null axis =
// unconstrained). measure_ctx is dereferenced during compute(), so it must
// outlive that call - back it with caller-stable or per-frame-arena memory,
// never a temporary.
pub const MeasureFunc = *const fn (ctx: *anyopaque, proposal: SizeProposal) Size(f32);

// MeasureFunc is external component code (text metrics); a NaN/inf or negative
// from it would poison every sibling's origin downstream and reach Metal. Clamp
// every measure_fn result so one bad measure can't corrupt the frame.
fn finite_size(s: Size(f32)) Size(f32) {
    return .{
        .width = if (std.math.isFinite(s.width)) @max(s.width, 0) else 0,
        .height = if (std.math.isFinite(s.height)) @max(s.height, 0) else 0,
    };
}

const LayoutNode = struct {
    style: Style,
    children: std.ArrayListUnmanaged(LayoutId),
    computed_bounds: Bounds(f32),
    content_size: Size(f32),
    measure_fn: ?MeasureFunc,
    measure_ctx: ?*anyopaque,

    fn init(style: Style) LayoutNode {
        return .{
            .style = style,
            .children = .empty,
            .computed_bounds = .{},
            .content_size = .{},
            .measure_fn = null,
            .measure_ctx = null,
        };
    }

    fn deinit(self: *LayoutNode, allocator: std.mem.Allocator) void {
        self.children.deinit(allocator);
    }
};

pub const LayoutEngine = struct {
    allocator: std.mem.Allocator,
    // nodes is a high-water pool: its length only grows. `live` is the count
    // used this frame; slots [0, live) are the current tree. clear() keeps the
    // slots (and each node's children-list capacity) so a steady-state UI does
    // zero per-frame layout allocation after warm-up. LayoutId.index < live.
    nodes: std.ArrayListUnmanaged(LayoutNode) = .empty,
    live: usize = 0,
    root: LayoutId = LayoutId.nil,

    pub fn init(allocator: std.mem.Allocator) LayoutEngine {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *LayoutEngine) void {
        for (self.nodes.items) |*node| {
            node.deinit(self.allocator);
        }
        self.nodes.deinit(self.allocator);
    }

    pub fn clear(self: *LayoutEngine) void {
        for (self.nodes.items[0..self.live]) |*node| node.children.clearRetainingCapacity();
        self.live = 0;
        self.root = LayoutId.nil;
    }

    fn reuse_or_append(self: *LayoutEngine, style: Style) std.mem.Allocator.Error!void {
        if (self.live < self.nodes.items.len) {
            const n = &self.nodes.items[self.live];
            n.style = style;
            n.computed_bounds = .{};
            n.content_size = .{};
            n.measure_fn = null;
            n.measure_ctx = null;
        } else {
            try self.nodes.append(self.allocator, LayoutNode.init(style));
        }
        self.live += 1;
    }

    pub fn add_node(self: *LayoutEngine, style: Style) std.mem.Allocator.Error!LayoutId {
        const index: u32 = @intCast(self.live);
        try self.reuse_or_append(style);
        return .{ .index = index };
    }

    pub fn add_node_with_measure(
        self: *LayoutEngine,
        style: Style,
        measure_fn: MeasureFunc,
        measure_ctx: *anyopaque,
    ) std.mem.Allocator.Error!LayoutId {
        const index: u32 = @intCast(self.live);
        try self.reuse_or_append(style);
        const n = &self.nodes.items[index];
        n.measure_fn = measure_fn;
        n.measure_ctx = measure_ctx;
        return .{ .index = index };
    }

    pub fn add_child(
        self: *LayoutEngine,
        parent: LayoutId,
        child: LayoutId,
    ) std.mem.Allocator.Error!void {
        if (parent.is_nil() or child.is_nil()) return;
        std.debug.assert(parent.index < self.nodes.items.len);
        try self.nodes.items[parent.index].children.append(self.allocator, child);
    }

    pub fn set_root(self: *LayoutEngine, id: LayoutId) void {
        self.root = id;
    }

    pub fn compute(self: *LayoutEngine, viewport: Size(f32)) void {
        if (self.root.is_nil()) return;
        const root_bounds = Bounds(f32){ .origin = .{}, .size = viewport };
        self.layout_node(self.root, root_bounds, 0, null);
    }

    pub fn get_bounds(self: *LayoutEngine, id: LayoutId) Bounds(f32) {
        if (id.is_nil()) return .{};
        std.debug.assert(id.index < self.nodes.items.len);
        return self.nodes.items[id.index].computed_bounds;
    }

    pub fn compute_subtree(self: *LayoutEngine, id: LayoutId, bounds: Bounds(f32)) void {
        self.layout_node(id, bounds, 0, null);
    }

    // `definite` is the size a flex parent already resolved for this child - use
    // it verbatim so a percent isn't re-resolved (squared per level) and a
    // stretched/explicit cross isn't overwritten by content. null = root or
    // subtree entry: resolve own style against `available` and collapse auto
    // axes to laid-out content.
    fn layout_node(
        self: *LayoutEngine,
        id: LayoutId,
        available: Bounds(f32),
        depth: u32,
        definite: ?Size(f32),
    ) void {
        if (id.is_nil()) return;
        if (depth > MAX_LAYOUT_DEPTH) return; // release-safe stack-overflow guard
        std.debug.assert(id.index < self.nodes.items.len);

        var node = &self.nodes.items[id.index];
        const style = &node.style;

        if (style.display == .none) {
            node.computed_bounds = .{};
            return;
        }

        var final_width: f32 = undefined;
        var final_height: f32 = undefined;
        var w_auto = false;
        var h_auto = false;
        if (definite) |d| {
            final_width = d.width;
            final_height = d.height;
        } else {
            const rw = self.resolve_length(style.width, available.size.width);
            const rh = self.resolve_length(style.height, available.size.height);
            final_width = rw orelse available.size.width;
            final_height = rh orelse available.size.height;
            w_auto = rw == null;
            h_auto = rh == null;
        }

        const padding_h = self.resolve_px(style.padding.left) +
            self.resolve_px(style.padding.right);
        const padding_v = self.resolve_px(style.padding.top) +
            self.resolve_px(style.padding.bottom);
        const content_width = @max(final_width - padding_h, 0);
        const content_height = @max(final_height - padding_v, 0);

        var children_size = Size(f32){ .width = 0, .height = 0 };
        if (style.layers and node.children.items.len > 0) {
            // Z-stack: every child gets the full content box, overlapping.
            const box = Bounds(f32){ .origin = available.origin, .size = .{ .width = content_width, .height = content_height } };
            for (node.children.items) |child_id| {
                self.layout_node(child_id, box, depth + 1, box.size);
            }
            children_size = box.size;
        } else if (style.display == .flex and node.children.items.len > 0) {
            children_size = self.layout_flex_children(
                node,
                available.origin,
                content_width,
                content_height,
                depth,
            );
        }

        // Auto axes (root/subtree path) collapse to the laid-out content extent —
        // shrink-wrap. EXCEPT a grow>0 node's main axis: grow means "fill the
        // available space", so it keeps `available` even at the root (a full-window
        // overlay scrim fills the window; a grow=0 menu still shrink-wraps to content).
        const fill_main = style.flex_grow > 0;
        const main_is_row = style.flex_direction.is_row();
        const keep_w = fill_main and main_is_row; // row -> main axis is width
        const keep_h = fill_main and !main_is_row; // column -> main axis is height
        if (w_auto and children_size.width > 0 and !keep_w) final_width = children_size.width;
        if (h_auto and children_size.height > 0 and !keep_h) final_height = children_size.height;

        final_width = self.clamp_axis(
            final_width,
            style.min_width,
            style.max_width,
            available.size.width,
        );
        final_height = self.clamp_axis(
            final_height,
            style.min_height,
            style.max_height,
            available.size.height,
        );

        node.computed_bounds = .{
            .origin = available.origin,
            .size = .{ .width = final_width, .height = final_height },
        };
    }

    fn layout_flex_children(
        self: *LayoutEngine,
        node: *LayoutNode,
        parent_origin: Point(f32),
        content_width: f32,
        content_height: f32,
        depth: u32,
    ) Size(f32) {
        if (depth > MAX_LAYOUT_DEPTH) return .{};

        const style = &node.style;
        if (style.flex_wrap != .no_wrap and node.children.items.len > 1) {
            return self.layout_flex_wrap(node, parent_origin, content_width, content_height, depth);
        }
        const is_row = style.flex_direction.is_row();
        const is_reverse = style.flex_direction.is_reverse();

        const main_size = @max(if (is_row) content_width else content_height, 0);
        const cross_size = @max(if (is_row) content_height else content_width, 0);

        const gap = if (is_row)
            self.resolve_px(style.column_gap)
        else
            self.resolve_px(style.row_gap);
        const child_count = node.children.items.len;
        const gap_count = if (child_count > 1) child_count - 1 else 0;
        const total_gap = gap * @as(f32, @floatFromInt(gap_count));

        // Per-child base/grow/shrink/min on the main axis. child_base also stamps
        // content_size (measured/intrinsic) as a side effect, which the placement
        // loop below reads. Release-safe hard cap: the scratch is a fixed stack
        // buffer, so children past MAX_FLEX_CHILDREN are dropped, not written OOB.
        std.debug.assert(child_count <= MAX_FLEX_CHILDREN);
        const n = @min(child_count, MAX_FLEX_CHILDREN);
        var base: [MAX_FLEX_CHILDREN]ChildBase = undefined;
        var total_fixed: f32 = 0;
        var total_flex_grow: f32 = 0;
        for (node.children.items[0..n], 0..) |child_id, bi| {
            std.debug.assert(child_id.index < self.nodes.items.len);
            base[bi] = self.child_base(child_id, is_row, main_size, cross_size, depth);
            // Grow from the effective floor (max of basis and min) so a min-clamped
            // child can't make a growing sibling overrun the row (see place_flex_line).
            const eff = @max(base[bi].main, base[bi].min_main);
            total_fixed += eff;
            total_flex_grow += base[bi].grow;
        }

        const free = main_size - total_fixed - total_gap;
        const remaining = @max(free, 0);
        // Final main size per child, resolved iteratively so a min- or max-clamped
        // child's unusable share is redistributed to the still-flexible ones.
        var resolved: [MAX_FLEX_CHILDREN]f32 = undefined;
        resolve_flex_mains(base[0..n], main_size - total_gap, resolved[0..n]);

        var main_offset: f32 = self.resolve_px(
            if (is_row) style.padding.left else style.padding.top,
        );
        var justify_gap: f32 = 0;

        if (total_flex_grow == 0 and remaining > 0) {
            switch (style.justify_content) {
                .flex_start => {},
                .flex_end => main_offset += remaining,
                .center => main_offset += remaining / 2,
                .space_between => {
                    if (child_count > 1) {
                        justify_gap = remaining / @as(f32, @floatFromInt(child_count - 1));
                    }
                },
                .space_around => {
                    const space = remaining / @as(f32, @floatFromInt(child_count));
                    main_offset += space / 2;
                    justify_gap = space;
                },
                .space_evenly => {
                    const space = remaining / @as(f32, @floatFromInt(child_count + 1));
                    main_offset += space;
                    justify_gap = space;
                },
            }
        }

        const cross_offset = self.resolve_px(if (is_row) style.padding.top else style.padding.left);
        const indices = node.children.items;

        var i: usize = 0;
        while (i < n) : (i += 1) {
            const idx = if (is_reverse) n - 1 - i else i;
            const child_id = indices[idx];
            var child = &self.nodes.items[child_id.index];

            var actual_main: f32 = undefined;
            var actual_cross: f32 = undefined;

            const style_cross = if (is_row)
                self.resolve_length(child.style.height, cross_size)
            else
                self.resolve_length(child.style.width, cross_size);

            // The resolver already folded in grow/shrink distribution and the
            // min/max clamps (with redistribution when a clamp binds).
            actual_main = resolved[idx];
            actual_cross = style_cross orelse base[idx].cross;
            // child_base measures content at the FULL available main (before siblings
            // consume it / shrink runs), so a child whose main axis ended up smaller than
            // that must have its cross re-measured at the resolved width. Wrapping content
            // (text, or a container holding it) gets TALLER as it narrows, and skipping this
            // leaves the line too short so its wrapped tail overlaps the next one.
            if (style_cross == null and actual_main + 0.5 < base[idx].main) {
                const aw = if (is_row) actual_main else cross_size;
                const ah = if (is_row) cross_size else actual_main;
                if (child.measure_fn) |mf| {
                    const m = finite_size(mf(child.measure_ctx.?, .{ .width = aw, .height = ah }));
                    actual_cross = if (is_row) m.height else m.width;
                } else if (child.children.items.len > 0) {
                    const intr = self.measure_intrinsic_size(child_id, aw, ah, depth + 1);
                    actual_cross = if (is_row) intr.height else intr.width;
                }
            }
            if (!base[idx].has_content and style_cross == null) actual_cross = cross_size;
            var child_cross_offset = cross_offset;

            const aligns = if (child.style.align_self != .auto)
                @as(AlignItems, @enumFromInt(@intFromEnum(child.style.align_self) - 1))
            else
                style.align_items;

            switch (aligns) {
                .flex_start => {},
                .flex_end => child_cross_offset = cross_offset + cross_size - actual_cross,
                .center => child_cross_offset = cross_offset + (cross_size - actual_cross) / 2,
                .stretch => {
                    // Fill the cross axis exactly when the child pins no explicit
                    // cross size: enlarge a small child AND shrink an oversized one.
                    // The shrink is what lets a nested flex-wrap row reflow - its
                    // single-line intrinsic width is capped to the parent so it
                    // breaks into lines.
                    const child_cross_style = if (is_row)
                        self.resolve_length(child.style.height, cross_size)
                    else
                        self.resolve_length(child.style.width, cross_size);
                    if (child_cross_style == null) actual_cross = cross_size;
                },
                .baseline => {},
            }

            if (is_row) {
                child.computed_bounds = .{
                    .origin = .{
                        .x = parent_origin.x + main_offset,
                        .y = parent_origin.y + child_cross_offset,
                    },
                    .size = .{ .width = actual_main, .height = actual_cross },
                };
            } else {
                child.computed_bounds = .{
                    .origin = .{
                        .x = parent_origin.x + child_cross_offset,
                        .y = parent_origin.y + main_offset,
                    },
                    .size = .{ .width = actual_cross, .height = actual_main },
                };
            }

            self.layout_node(
                child_id,
                child.computed_bounds,
                depth + 1,
                child.computed_bounds.size,
            );

            const final_main = if (is_row)
                child.computed_bounds.size.width
            else
                child.computed_bounds.size.height;
            main_offset += final_main + gap + justify_gap;
        }

        const padding_end = self.resolve_px(
            if (is_row) style.padding.right else style.padding.bottom,
        );
        const total_main = main_offset - gap - justify_gap + padding_end;

        var max_cross: f32 = 0;
        for (node.children.items) |child_id| {
            const child = &self.nodes.items[child_id.index];
            const child_cross_size = if (is_row)
                child.computed_bounds.size.height
            else
                child.computed_bounds.size.width;
            max_cross = @max(max_cross, child_cross_size);
        }

        const cross_padding =
            self.resolve_px(if (is_row) style.padding.top else style.padding.left) +
            self.resolve_px(if (is_row) style.padding.bottom else style.padding.right);
        const total_cross = max_cross + cross_padding;

        return if (is_row)
            Size(f32){ .width = total_main, .height = total_cross }
        else
            Size(f32){ .width = total_cross, .height = total_main };
    }

    const ChildBase = struct {
        main: f32,
        cross: f32,
        grow: f32,
        shrink: f32,
        min_main: f32,
        max_main: f32,
        has_content: bool,
    };
    const MAX_FLEX_CHILDREN = 128;

    // Resolve every child's final main size (the CSS flexible-lengths loop):
    // distribute free space by grow, or overflow by shrink weighted by base size.
    // A child whose min (shrinking) or max (growing) clamps its target is frozen at
    // the clamp and the pass reruns so the unusable share is redistributed among the
    // still-flexible children. A single pass would let every clamped child overflow
    // the container by its clamped amount (e.g. fixed chrome rows above a
    // shrinkable pane pushing the pane's content past a fixed-height ancestor).
    fn resolve_flex_mains(base: []const ChildBase, available: f32, resolved: []f32) void {
        std.debug.assert(base.len == resolved.len);
        std.debug.assert(base.len <= MAX_FLEX_CHILDREN);
        var frozen: [MAX_FLEX_CHILDREN]bool = undefined;
        var sum_eff: f32 = 0;
        for (base, 0..) |cb, i| {
            frozen[i] = false;
            sum_eff += @max(cb.main, cb.min_main);
        }
        const growing = sum_eff <= available;
        // An inflexible child (no grow when growing / no shrink when shrinking)
        // stays at its clamped base.
        for (base, 0..) |cb, i| {
            const flex = if (growing) cb.grow else cb.shrink;
            if (flex == 0) {
                const eff = @max(cb.main, cb.min_main);
                resolved[i] = @max(@min(eff, cb.max_main), cb.min_main);
                frozen[i] = true;
            }
        }
        var pass: usize = 0;
        while (pass <= base.len) : (pass += 1) {
            var free = available;
            var total_weight: f32 = 0;
            for (base, 0..) |cb, i| {
                if (frozen[i]) {
                    free -= resolved[i];
                } else {
                    const eff = @max(cb.main, cb.min_main);
                    free -= eff;
                    total_weight += if (growing) cb.grow else cb.shrink * eff;
                }
            }
            if (total_weight <= 0) break;
            const unit = if (growing) @max(free, 0) / total_weight else @max(-free, 0) / total_weight;
            var violated = false;
            for (base, 0..) |cb, i| {
                if (frozen[i]) continue;
                const eff = @max(cb.main, cb.min_main);
                const target = if (growing) eff + unit * cb.grow else eff - unit * cb.shrink * eff;
                if (growing and target > cb.max_main) {
                    resolved[i] = @max(cb.max_main, cb.min_main);
                    frozen[i] = true;
                    violated = true;
                } else if (!growing and target < cb.min_main) {
                    resolved[i] = cb.min_main;
                    frozen[i] = true;
                    violated = true;
                }
            }
            if (!violated) {
                for (base, 0..) |cb, i| {
                    if (frozen[i]) continue;
                    const eff = @max(cb.main, cb.min_main);
                    const target = if (growing) eff + unit * cb.grow else eff - unit * cb.shrink * eff;
                    resolved[i] = @max(@min(target, cb.max_main), cb.min_main);
                }
                return;
            }
        }
        // Everything frozen (or nothing flexible): any child not yet resolved keeps
        // its clamped base.
        for (base, 0..) |cb, i| {
            if (frozen[i]) continue;
            const eff = @max(cb.main, cb.min_main);
            resolved[i] = @max(@min(eff, cb.max_main), cb.min_main);
        }
    }

    // flex_basis seeds the main-axis base before grow/shrink; .auto falls through
    // to width/height/content. Resolved against the container main extent.
    fn basis_main(self: *LayoutEngine, child: *LayoutNode, main_size: f32) ?f32 {
        return self.resolve_length(child.style.flex_basis, main_size);
    }

    // Base main/cross extent of one flex child before distribution: measured leaf,
    // intrinsic container, explicit style size, or a bare-grow item (main 0). grow
    // and shrink ride along for every kind (flex: grow/shrink act on top of the
    // basis), as does the min-main shrink floor. flex_basis (when set) overrides
    // the main base.
    fn child_base(
        self: *LayoutEngine,
        child_id: LayoutId,
        is_row: bool,
        main_size: f32,
        cross_size: f32,
        depth: u32,
    ) ChildBase {
        std.debug.assert(child_id.index < self.nodes.items.len);
        var child = &self.nodes.items[child_id.index];
        const grow = child.style.flex_grow;
        const shrink = child.style.flex_shrink;
        const min_m = self.min_main(child, is_row, main_size);
        const max_m = self.max_main(child, is_row, main_size);
        const basis = self.basis_main(child, main_size);
        // CSS flex min-width/height:auto - the automatic minimum is the child's
        // min-content along the main axis, so shrink never crushes it below its
        // content and bleeds it over a sibling. Only when no explicit min is set;
        // each return caps it at that branch's base extent, so it never enlarges
        // the child nor perturbs the free-space/shrink math (eff stays the base).
        const main_min = if (is_row) child.style.min_width else child.style.min_height;
        // Skip the (recursive) min-content probe when the child can't shrink - the
        // auto floor only ever binds a shrinking child.
        const min_auto: f32 = if (shrink > 0) switch (main_min) {
            .auto => self.min_content_main(child_id, is_row, depth + 1),
            else => 0,
        } else 0;
        if (child.measure_fn) |measure_fn| {
            const aw = if (is_row) main_size else cross_size;
            const ah = if (is_row) cross_size else main_size;
            const m = finite_size(measure_fn(child.measure_ctx.?, .{ .width = aw, .height = ah }));
            child.content_size = m;
            const main = basis orelse (if (is_row) m.width else m.height);
            const cross = if (is_row) m.height else m.width;
            return .{
                .main = main,
                .cross = cross,
                .grow = grow,
                .shrink = shrink,
                .min_main = @max(min_m, @min(min_auto, main)),
                .max_main = max_m,
                .has_content = true,
            };
        }
        const sm = if (is_row)
            self.resolve_length(child.style.width, main_size)
        else
            self.resolve_length(child.style.height, main_size);
        const sc = if (is_row)
            self.resolve_length(child.style.height, cross_size)
        else
            self.resolve_length(child.style.width, cross_size);
        if (child.children.items.len > 0) {
            const av_w = if (is_row) main_size else cross_size;
            const av_h = if (is_row) cross_size else main_size;
            const intr = self.measure_intrinsic_size(child_id, av_w, av_h, depth + 1);
            child.content_size = intr;
            const main = basis orelse sm orelse (if (is_row) intr.width else intr.height);
            const cross = sc orelse (if (is_row) intr.height else intr.width);
            return .{
                .main = main,
                .cross = cross,
                .grow = grow,
                .shrink = shrink,
                .min_main = @max(min_m, @min(min_auto, main)),
                .max_main = max_m,
                .has_content = true,
            };
        }
        if (basis) |b| return .{
            .main = b,
            .cross = sc orelse 0,
            .grow = grow,
            .shrink = shrink,
            .min_main = @max(min_m, @min(min_auto, b)),
            .max_main = max_m,
            .has_content = true,
        };
        if (sm) |v| return .{
            .main = v,
            .cross = sc orelse 0,
            .grow = grow,
            .shrink = shrink,
            .min_main = @max(min_m, @min(min_auto, v)),
            .max_main = max_m,
            .has_content = true,
        };
        return .{
            .main = 0,
            .cross = sc orelse 0,
            .grow = grow,
            .shrink = shrink,
            .min_main = min_m,
            .max_main = max_m,
            .has_content = false,
        };
    }

    // Greedily packs children into lines, stacking lines on the cross axis with
    // cross gap = the other axis' gap. Each line distributes its own leftover and
    // aligns within its own cross height. no_wrap never reaches here.
    fn layout_flex_wrap(
        self: *LayoutEngine,
        node: *LayoutNode,
        parent_origin: Point(f32),
        content_width: f32,
        content_height: f32,
        depth: u32,
    ) Size(f32) {
        if (depth > MAX_LAYOUT_DEPTH) return .{};
        const style = &node.style;
        const is_row = style.flex_direction.is_row();
        const main_size = @max(if (is_row) content_width else content_height, 0);
        const cross_avail = @max(if (is_row) content_height else content_width, 0);
        const main_gap = if (is_row)
            self.resolve_px(style.column_gap)
        else
            self.resolve_px(style.row_gap);
        const cross_gap = if (is_row)
            self.resolve_px(style.row_gap)
        else
            self.resolve_px(style.column_gap);

        const children = node.children.items;
        // Release-safe hard cap: the per-line scratch is a fixed stack buffer, so
        // children past MAX_FLEX_CHILDREN are dropped rather than smashing the
        // stack. Asserts in debug; a UI row should never approach this.
        std.debug.assert(children.len <= MAX_FLEX_CHILDREN);
        const n = @min(children.len, MAX_FLEX_CHILDREN);

        // grid_cols (when set) turns the wrap row into N equal-width tracks: resolve
        // N from the container width, size every child to one track, and pack exactly
        // N per line (count break, not width). A count break can't drift early on FP
        // the way a width compare would, and a min-floored card can't widen a track.
        const cols_opt: ?usize = if (style.grid_cols) |gc| gc.resolve(main_size) else null;
        const grid_track: ?f32 = if (cols_opt) |c| blk: {
            const cf: f32 = @floatFromInt(c);
            break :blk @max((main_size - main_gap * (cf - 1)) / cf, 0);
        } else null;

        var base: [MAX_FLEX_CHILDREN]ChildBase = undefined;
        for (children[0..n], 0..) |child_id, i| {
            base[i] = self.child_base(
                child_id,
                is_row,
                grid_track orelse main_size,
                cross_avail,
                depth,
            );
            if (grid_track) |tw| {
                base[i].main = tw;
                base[i].min_main = 0;
                base[i].max_main = tw;
                base[i].grow = 0;
                base[i].shrink = 0;
            }
        }

        const main_pad_start = self.resolve_px(
            if (is_row) style.padding.left else style.padding.top,
        );
        const cross_pad_start = self.resolve_px(
            if (is_row) style.padding.top else style.padding.left,
        );

        if (cols_opt) |cols| {
            // Liveness: the placement loop advances by `cols` each step, so a 0
            // would spin forever on the render thread. resolve() floors at 1 in
            // theme.zig; assert it here where the loop actually depends on it.
            std.debug.assert(cols >= 1);
            const main_pad_end = self.resolve_px(
                if (is_row) style.padding.right else style.padding.bottom,
            );
            const cross_pad_end = self.resolve_px(
                if (is_row) style.padding.bottom else style.padding.right,
            );
            var cursor: f32 = cross_pad_start;
            var lo: usize = 0;
            while (lo < n) {
                const hi = @min(lo + cols, n);
                const lc = self.place_flex_line(node, parent_origin, .{
                    .base = &base,
                    .lo = lo,
                    .hi = hi,
                    .is_row = is_row,
                    .main_size = main_size,
                    .main_gap = main_gap,
                    .main_pad_start = main_pad_start,
                    .cross_offset = cursor,
                    .depth = depth,
                });
                cursor += lc;
                lo = hi;
                if (lo < n) cursor += cross_gap;
            }
            const total_main = main_pad_start + main_size + main_pad_end;
            const final_cross = cursor + cross_pad_end;
            return if (is_row)
                Size(f32){ .width = total_main, .height = final_cross }
            else
                Size(f32){ .width = final_cross, .height = total_main };
        }

        var cross_cursor: f32 = cross_pad_start;
        var line_start: usize = 0;
        var line_main: f32 = 0;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const is_first = i == line_start;
            // Pack by the item's EFFECTIVE main extent: a child floored to its
            // min_main (place_flex_line never shrinks below it) occupies min_main,
            // not its smaller content base. Using base.main alone would mis-decide
            // the break (a min-floored card overflows the line instead of wrapping).
            const eff = @max(base[i].main, base[i].min_main);
            const add = eff + (if (is_first) 0 else main_gap);
            if (!is_first and line_main + add > main_size) {
                const lc = self.place_flex_line(node, parent_origin, .{
                    .base = &base,
                    .lo = line_start,
                    .hi = i,
                    .is_row = is_row,
                    .main_size = main_size,
                    .main_gap = main_gap,
                    .main_pad_start = main_pad_start,
                    .cross_offset = cross_cursor,
                    .depth = depth,
                });
                cross_cursor += lc + cross_gap;
                line_start = i;
                line_main = eff;
            } else {
                line_main += add;
            }
        }
        var total_cross: f32 = cross_pad_start;
        if (line_start < n) {
            const lc = self.place_flex_line(node, parent_origin, .{
                .base = &base,
                .lo = line_start,
                .hi = n,
                .is_row = is_row,
                .main_size = main_size,
                .main_gap = main_gap,
                .main_pad_start = main_pad_start,
                .cross_offset = cross_cursor,
                .depth = depth,
            });
            total_cross = cross_cursor + lc;
        }

        const main_pad_end = self.resolve_px(
            if (is_row) style.padding.right else style.padding.bottom,
        );
        const cross_pad_end = self.resolve_px(
            if (is_row) style.padding.bottom else style.padding.right,
        );
        const total_main = main_pad_start + main_size + main_pad_end;
        const final_cross = total_cross + cross_pad_end;
        return if (is_row)
            Size(f32){ .width = total_main, .height = final_cross }
        else
            Size(f32){ .width = final_cross, .height = total_main };
    }

    // Args for one wrapped-line placement; struct keeps place_flex_line's call
    // sites readable (a flat positional list would run well past the col cap).
    const FlexLineParams = struct {
        base: *const [MAX_FLEX_CHILDREN]ChildBase,
        lo: usize,
        hi: usize,
        is_row: bool,
        main_size: f32,
        main_gap: f32,
        main_pad_start: f32,
        cross_offset: f32,
        depth: u32,
    };

    fn place_flex_line(
        self: *LayoutEngine,
        node: *LayoutNode,
        parent_origin: Point(f32),
        p: FlexLineParams,
    ) f32 {
        const style = &node.style;
        const children = node.children.items;
        const base = p.base;
        const lo = p.lo;
        const hi = p.hi;
        const is_row = p.is_row;
        const main_size = p.main_size;
        const main_gap = p.main_gap;
        const cross_offset = p.cross_offset;
        const depth = p.depth;
        std.debug.assert(lo <= hi);
        std.debug.assert(hi <= children.len);
        const count = hi - lo;

        var total_fixed: f32 = 0;
        var total_grow: f32 = 0;
        var total_shrink_weight: f32 = 0;
        var line_cross: f32 = 0;
        var k: usize = lo;
        while (k < hi) : (k += 1) {
            // Grow from the item's effective floor (max of basis and min): a child
            // clamped UP to its min must occupy min in the free-space math, else a
            // growing sibling overruns the line (a min-width card pushes the row
            // past the container).
            const eff = @max(base[k].main, base[k].min_main);
            total_fixed += eff;
            total_grow += base[k].grow;
            // CSS shrink weight is shrink * base; a 0-base item never shrinks.
            total_shrink_weight += base[k].shrink * eff;
            line_cross = @max(line_cross, base[k].cross);
        }
        const total_gap = main_gap * @as(f32, @floatFromInt(if (count > 1) count - 1 else 0));
        const free = main_size - total_fixed - total_gap;
        const remaining = @max(free, 0);
        const flex_unit = if (total_grow > 0) remaining / total_grow else 0;
        // Overflow (free < 0) distributes the negative space by shrink*base weight.
        const overflow = @max(-free, 0);
        const shrink_unit = if (overflow > 0 and total_shrink_weight > 0)
            overflow / total_shrink_weight
        else
            0;

        var main_offset: f32 = p.main_pad_start;
        var justify_gap: f32 = 0;
        if (total_grow == 0 and remaining > 0) {
            switch (style.justify_content) {
                .flex_start => {},
                .flex_end => main_offset += remaining,
                .center => main_offset += remaining / 2,
                .space_between => {
                    if (count > 1) justify_gap = remaining / @as(f32, @floatFromInt(count - 1));
                },
                .space_around => {
                    const s = remaining / @as(f32, @floatFromInt(count));
                    main_offset += s / 2;
                    justify_gap = s;
                },
                .space_evenly => {
                    const s = remaining / @as(f32, @floatFromInt(count + 1));
                    main_offset += s;
                    justify_gap = s;
                },
            }
        }

        k = lo;
        while (k < hi) : (k += 1) {
            const child_id = children[k];
            std.debug.assert(child_id.index < self.nodes.items.len);
            const child = &self.nodes.items[child_id.index];
            // Grow adds, shrink subtracts (shrink*base weighted), floored at the
            // child's min-main and never below 0.
            const eff = @max(base[k].main, base[k].min_main);
            const shrink_take = shrink_unit * base[k].shrink * eff;
            const grown = eff + flex_unit * base[k].grow - shrink_take;
            const actual_main = @max(@min(grown, base[k].max_main), base[k].min_main);
            var actual_cross = base[k].cross;
            var cross_in_line: f32 = 0;

            const aligns = if (child.style.align_self != .auto)
                @as(AlignItems, @enumFromInt(@intFromEnum(child.style.align_self) - 1))
            else
                style.align_items;
            switch (aligns) {
                .flex_start => {},
                .flex_end => cross_in_line = line_cross - actual_cross,
                .center => cross_in_line = (line_cross - actual_cross) / 2,
                .stretch => {
                    const explicit = if (is_row)
                        self.resolve_length(child.style.height, line_cross)
                    else
                        self.resolve_length(child.style.width, line_cross);
                    if (explicit == null and line_cross > actual_cross) actual_cross = line_cross;
                },
                .baseline => {},
            }

            if (is_row) {
                child.computed_bounds = .{
                    .origin = .{
                        .x = parent_origin.x + main_offset,
                        .y = parent_origin.y + cross_offset + cross_in_line,
                    },
                    .size = .{ .width = actual_main, .height = actual_cross },
                };
            } else {
                child.computed_bounds = .{
                    .origin = .{
                        .x = parent_origin.x + cross_offset + cross_in_line,
                        .y = parent_origin.y + main_offset,
                    },
                    .size = .{ .width = actual_cross, .height = actual_main },
                };
            }
            self.layout_node(
                child_id,
                child.computed_bounds,
                depth + 1,
                child.computed_bounds.size,
            );
            const final_main = if (is_row)
                child.computed_bounds.size.width
            else
                child.computed_bounds.size.height;
            main_offset += final_main + main_gap + justify_gap;
        }
        return line_cross;
    }

    fn measure_intrinsic_size(
        self: *LayoutEngine,
        id: LayoutId,
        available_width: f32,
        available_height: f32,
        depth: u32,
    ) Size(f32) {
        if (depth > MAX_LAYOUT_DEPTH) return .{};
        if (id.is_nil()) return .{ .width = 0, .height = 0 };
        std.debug.assert(id.index < self.nodes.items.len);

        const node = &self.nodes.items[id.index];
        const style = &node.style;

        const padding_h = self.resolve_px(style.padding.left) +
            self.resolve_px(style.padding.right);
        const padding_v = self.resolve_px(style.padding.top) +
            self.resolve_px(style.padding.bottom);

        const explicit_w = self.resolve_length(style.width, available_width);
        const explicit_h = self.resolve_length(style.height, available_height);

        if (explicit_w != null and explicit_h != null) {
            return .{ .width = explicit_w.?, .height = explicit_h.? };
        }

        const is_row = style.flex_direction.is_row();
        const content_width = @max(explicit_w orelse (available_width - padding_h), 0);
        const content_height = @max(explicit_h orelse (available_height - padding_v), 0);

        // Height-for-width: a wrap row fills the width and stacks lines, so its
        // intrinsic HEIGHT depends on how many lines the children break into at
        // this width. The single-line sum below would under-report it and a parent
        // stacking a sibling underneath us would overlap.
        if (is_row and style.flex_wrap != .no_wrap and node.children.items.len > 1) {
            const main_gap = self.resolve_px(style.column_gap);
            const cross_gap = self.resolve_px(style.row_gap);
            // Same release-safe cap as layout_flex_wrap; both passes must agree on
            // the line count, so assert the bound here too (dropping past it would
            // under-report the stacked height the parent reserves for us).
            std.debug.assert(node.children.items.len <= MAX_FLEX_CHILDREN);
            const cap = @min(node.children.items.len, MAX_FLEX_CHILDREN);

            // grid_cols path: ceil(n/cols) lines of equal tracks. Mirror the layout
            // pass exactly (track width, count break) so the reported height matches
            // what gets laid out - else a sibling below overlaps the last grid row.
            if (style.grid_cols) |gc| {
                const cols: usize = gc.resolve(content_width);
                std.debug.assert(cols >= 1); // == 0 would never reset on_line
                const cf: f32 = @floatFromInt(cols);
                const track = @max((content_width - main_gap * (cf - 1)) / cf, 0);
                var stacked: f32 = 0;
                var line_cross: f32 = 0;
                var on_line: usize = 0;
                var lines: usize = 0;
                for (node.children.items[0..cap]) |child_id| {
                    if (on_line == cols) {
                        stacked += line_cross;
                        lines += 1;
                        line_cross = 0;
                        on_line = 0;
                    }
                    const cb = self.child_base(child_id, true, track, content_height, depth + 1);
                    line_cross = @max(line_cross, cb.cross);
                    on_line += 1;
                }
                if (on_line > 0) {
                    stacked += line_cross;
                    lines += 1;
                }
                const gaps = cross_gap * @as(f32, @floatFromInt(if (lines > 1) lines - 1 else 0));
                return .{
                    .width = explicit_w orelse (content_width + padding_h),
                    .height = explicit_h orelse (stacked + gaps + padding_v),
                };
            }

            var line_main: f32 = 0;
            var line_cross: f32 = 0;
            var stacked: f32 = 0;
            var lines: usize = 0;
            var on_line: usize = 0;
            for (node.children.items[0..cap]) |child_id| {
                const cb = self.child_base(
                    child_id,
                    true,
                    content_width,
                    content_height,
                    depth + 1,
                );
                // Pack by effective extent (max of base + min_main), matching
                // layout_flex_wrap exactly so the measured line count == the laid-out
                // one; else the parent reserves too little and the next sibling overlaps.
                const eff = @max(cb.main, cb.min_main);
                const add = eff + (if (on_line > 0) main_gap else 0);
                if (on_line > 0 and line_main + add > content_width) {
                    stacked += line_cross;
                    lines += 1;
                    line_main = eff;
                    line_cross = cb.cross;
                    on_line = 1;
                } else {
                    line_main += add;
                    line_cross = @max(line_cross, cb.cross);
                    on_line += 1;
                }
            }
            if (on_line > 0) {
                stacked += line_cross;
                lines += 1;
            }
            const gaps = cross_gap * @as(f32, @floatFromInt(if (lines > 1) lines - 1 else 0));
            return .{
                .width = explicit_w orelse (content_width + padding_h),
                .height = explicit_h orelse (stacked + gaps + padding_v),
            };
        }

        const gap = if (is_row)
            self.resolve_px(style.column_gap)
        else
            self.resolve_px(style.row_gap);

        var total_main: f32 = 0;
        var max_cross: f32 = 0;
        var child_count: usize = 0;
        // Row children share the main-axis width; measure each at what's LEFT after the ones
        // before it, so a wrapping child (text next to a fixed key/indent) reports its real,
        // taller height instead of a single line at the full width - otherwise a parent stacking
        // a sibling underneath reserves too little and they overlap. Columns give every child the
        // full width (they stack), so this narrowing is row-only and never enlarges the estimate.
        var used_main: f32 = 0;

        for (node.children.items) |child_id| {
            var child = &self.nodes.items[child_id.index];
            const avail_w = if (is_row) @max(content_width - used_main, 0) else content_width;

            var child_size: Size(f32) = undefined;

            if (child.measure_fn) |measure_fn| {
                const prop = SizeProposal{ .width = avail_w, .height = content_height };
                child_size = finite_size(measure_fn(child.measure_ctx.?, prop));
                child.content_size = child_size;
            } else if (child.children.items.len > 0) {
                child_size = self.measure_intrinsic_size(
                    child_id,
                    avail_w,
                    content_height,
                    depth + 1,
                );
                child.content_size = child_size;
            } else {
                child_size = .{
                    .width = self.resolve_length(child.style.width, content_width) orelse 0,
                    .height = self.resolve_length(child.style.height, content_height) orelse 0,
                };
            }

            const child_main = if (is_row) child_size.width else child_size.height;
            const child_cross = if (is_row) child_size.height else child_size.width;

            total_main += child_main;
            max_cross = @max(max_cross, child_cross);
            if (is_row) used_main += child_main + gap;
            child_count += 1;
        }

        if (child_count > 1) {
            total_main += gap * @as(f32, @floatFromInt(child_count - 1));
        }

        const final_width = if (is_row) total_main + padding_h else max_cross + padding_h;
        const final_height = if (is_row) max_cross + padding_v else total_main + padding_v;

        return .{
            .width = explicit_w orelse final_width,
            .height = explicit_h orelse final_height,
        };
    }

    fn resolve_length(self: *LayoutEngine, len: Length, parent: f32) ?f32 {
        _ = self;
        return switch (len) {
            .auto => null,
            .px => |v| v,
            .percent => |v| parent * v / 100.0,
        };
    }

    // Clamp one axis size to [min, max] resolved against `parent`. .auto bounds
    // are unconstrained. Per CSS, min wins when min > max (apply max first, then
    // min). Negative resolved bounds are floored at 0.
    fn clamp_axis(
        self: *LayoutEngine,
        value: f32,
        min_len: Length,
        max_len: Length,
        parent: f32,
    ) f32 {
        var out = value;
        if (self.resolve_length(max_len, parent)) |mx| out = @min(out, @max(mx, 0));
        if (self.resolve_length(min_len, parent)) |mn| out = @max(out, @max(mn, 0));
        return out;
    }

    // A flex child's hard floor on the main axis: its min-main (0 if .auto), used
    // as the shrink floor so a child never shrinks below its min size or below 0.
    fn min_main(self: *LayoutEngine, child: *LayoutNode, is_row: bool, parent: f32) f32 {
        const len = if (is_row) child.style.min_width else child.style.min_height;
        const mn = self.resolve_length(len, parent) orelse 0;
        return @max(mn, 0);
    }

    // Min-content extent of a subtree along the main axis (is_row => width): the
    // smallest it can be without breaking unbreakable content. A leaf measures at
    // main=0 (text => its widest word); a container sums children on its own main
    // axis (no_wrap), else takes the max (cross axis or wrap). Feeds the CSS flex
    // auto-min shrink floor in child_base, which caps it at the child's base extent.
    fn min_content_main(self: *LayoutEngine, child_id: LayoutId, is_row: bool, depth: u32) f32 {
        if (depth > MAX_LAYOUT_DEPTH) return 0;
        std.debug.assert(child_id.index < self.nodes.items.len);
        const child = &self.nodes.items[child_id.index];

        // An explicit min on the main axis overrides the automatic min-content probe
        // (CSS: an explicit min-size replaces the content minimum). This is what lets
        // a scroll viewport (min-height:0) report a 0 min so a fixed-height ancestor
        // can bound it, instead of inheriting its tall, clipped child's height.
        const explicit_min = if (is_row) child.style.min_width else child.style.min_height;
        if (explicit_min != .auto) return self.resolve_length(explicit_min, 0) orelse 0;

        if (child.measure_fn) |measure_fn| {
            if (is_row) {
                const m = finite_size(measure_fn(child.measure_ctx.?, .{ .min_content = true }));
                return m.width;
            }
            // Column main axis: min-content height is the natural single-line height.
            const m = finite_size(measure_fn(child.measure_ctx.?, .{}));
            return m.height;
        }

        const kids = child.children.items;
        if (kids.len == 0) return 0;

        const style = child.style;
        const same_axis = style.flex_direction.is_row() == is_row;
        const sums = same_axis and style.flex_wrap == .no_wrap;
        const pad_main = if (is_row)
            self.resolve_px(style.padding.left) + self.resolve_px(style.padding.right)
        else
            self.resolve_px(style.padding.top) + self.resolve_px(style.padding.bottom);
        const gap = if (is_row)
            self.resolve_px(style.column_gap)
        else
            self.resolve_px(style.row_gap);

        std.debug.assert(kids.len <= MAX_FLEX_CHILDREN);
        const cap = @min(kids.len, MAX_FLEX_CHILDREN);
        var acc: f32 = 0;
        var count: usize = 0;
        for (kids[0..cap]) |kid_id| {
            const mc = self.min_content_main(kid_id, is_row, depth + 1);
            if (sums) {
                acc += mc;
                count += 1;
            } else {
                acc = @max(acc, mc);
            }
        }
        if (sums and count > 1) acc += gap * @as(f32, @floatFromInt(count - 1));
        return acc + pad_main;
    }

    // A flex child's hard ceiling on the main axis: its max-main, used to cap the
    // grown size so flex-grow never overshoots max_width. Unbounded (.auto) maps
    // to floatMax so the @min is a no-op.
    fn max_main(self: *LayoutEngine, child: *LayoutNode, is_row: bool, parent: f32) f32 {
        const len = if (is_row) child.style.max_width else child.style.max_height;
        const mx = self.resolve_length(len, parent) orelse return std.math.floatMax(f32);
        return @max(mx, 0);
    }

    fn resolve_px(self: *LayoutEngine, len: Length) f32 {
        _ = self;
        return switch (len) {
            .px => |v| v,
            else => 0,
        };
    }
};

test "LayoutEngine basic single root" {
    var eng = LayoutEngine.init(std.testing.allocator);
    defer eng.deinit();

    const root = try eng.add_node(.{ .width = .{ .px = 100 }, .height = .{ .px = 50 } });
    eng.set_root(root);
    eng.compute(.{ .width = 200, .height = 200 });

    const b = eng.get_bounds(root);
    try std.testing.expect(b.size.width == 100 and b.size.height == 50);
}

test "LayoutEngine flex row distributes" {
    var eng = LayoutEngine.init(std.testing.allocator);
    defer eng.deinit();

    const parent = try eng.add_node(.{
        .display = .flex,
        .flex_direction = .row,
        .width = .{ .px = 200 },
        .height = .{ .px = 50 },
    });
    const a = try eng.add_node(.{ .width = .{ .px = 60 }, .height = .{ .px = 50 } });
    const b = try eng.add_node(.{ .width = .{ .px = 40 }, .height = .{ .px = 50 } });
    try eng.add_child(parent, a);
    try eng.add_child(parent, b);
    eng.set_root(parent);
    eng.compute(.{ .width = 200, .height = 200 });

    const ba = eng.get_bounds(a);
    const bb = eng.get_bounds(b);
    try std.testing.expect(ba.origin.x == 0 and ba.size.width == 60);
    try std.testing.expect(bb.origin.x == 60 and bb.size.width == 40);
}

test "LayoutEngine display none collapses" {
    var eng = LayoutEngine.init(std.testing.allocator);
    defer eng.deinit();

    const root = try eng.add_node(.{ .display = .none, .width = .{ .px = 100 } });
    eng.set_root(root);
    eng.compute(.{ .width = 200, .height = 200 });

    const b = eng.get_bounds(root);
    try std.testing.expect(b.size.width == 0 and b.size.height == 0);
}

test "LayoutEngine flex wrap breaks lines" {
    var eng = LayoutEngine.init(std.testing.allocator);
    defer eng.deinit();

    // Three 40px boxes in a 100px row, 10px gaps: 40+10+40=90 fits, the third
    // (would be 140) wraps to a second line stacked by the 10px row_gap.
    const parent = try eng.add_node(.{
        .display = .flex,
        .flex_direction = .row,
        .flex_wrap = .wrap,
        .width = .{ .px = 100 },
        .column_gap = .{ .px = 10 },
        .row_gap = .{ .px = 10 },
    });
    const a = try eng.add_node(.{ .width = .{ .px = 40 }, .height = .{ .px = 20 } });
    const b2 = try eng.add_node(.{ .width = .{ .px = 40 }, .height = .{ .px = 20 } });
    const c = try eng.add_node(.{ .width = .{ .px = 40 }, .height = .{ .px = 20 } });
    try eng.add_child(parent, a);
    try eng.add_child(parent, b2);
    try eng.add_child(parent, c);
    eng.set_root(parent);
    eng.compute(.{ .width = 100, .height = 200 });

    const ba = eng.get_bounds(a);
    const bb = eng.get_bounds(b2);
    const bc = eng.get_bounds(c);
    try std.testing.expect(ba.origin.x == 0 and ba.origin.y == 0);
    try std.testing.expect(bb.origin.x == 50 and bb.origin.y == 0);
    try std.testing.expect(bc.origin.x == 0 and bc.origin.y == 30);
}

test "percent width resolves once, not per nesting level" {
    var eng = LayoutEngine.init(std.testing.allocator);
    defer eng.deinit();

    // A 50%-wide child in a 200px row is 100, not 50 (the old double-resolve
    // halved it: 50% of the already-50%-resolved 100).
    const root = try eng.add_node(.{
        .flex_direction = .row,
        .width = .{ .px = 200 },
        .height = .{ .px = 100 },
    });
    const child = try eng.add_node(.{ .width = .{ .percent = 50 }, .height = .{ .px = 100 } });
    try eng.add_child(root, child);
    eng.set_root(root);
    eng.compute(.{ .width = 200, .height = 100 });

    try std.testing.expect(eng.get_bounds(child).size.width == 100);
}

test "nested container stretches to parent cross axis" {
    var eng = LayoutEngine.init(std.testing.allocator);
    defer eng.deinit();

    // A row with intrinsic content inside a 300px column should still fill the
    // column width (align stretch), not collapse to its 40px content.
    const col = try eng.add_node(.{
        .flex_direction = .column,
        .width = .{ .px = 300 },
        .height = .{ .px = 200 },
    });
    const row = try eng.add_node(.{ .flex_direction = .row });
    const leaf = try eng.add_node(.{ .width = .{ .px = 40 }, .height = .{ .px = 30 } });
    try eng.add_child(col, row);
    try eng.add_child(row, leaf);
    eng.set_root(col);
    eng.compute(.{ .width = 300, .height = 200 });

    try std.testing.expect(eng.get_bounds(row).size.width == 300);
}

test "flex grow stacks on top of a base size" {
    var eng = LayoutEngine.init(std.testing.allocator);
    defer eng.deinit();

    // Two 50px children that each grow=1 in a 200px row: remaining 100 splits
    // 50/50, so each ends at 100. The old path dropped grow when a base existed.
    const row = try eng.add_node(.{
        .flex_direction = .row,
        .width = .{ .px = 200 },
        .height = .{ .px = 50 },
    });
    const a = try eng.add_node(.{
        .width = .{ .px = 50 },
        .height = .{ .px = 50 },
        .flex_grow = 1,
    });
    const b = try eng.add_node(.{
        .width = .{ .px = 50 },
        .height = .{ .px = 50 },
        .flex_grow = 1,
    });
    try eng.add_child(row, a);
    try eng.add_child(row, b);
    eng.set_root(row);
    eng.compute(.{ .width = 200, .height = 100 });

    try std.testing.expect(eng.get_bounds(a).size.width == 100);
    const b_bounds = eng.get_bounds(b);
    try std.testing.expect(b_bounds.origin.x == 100 and b_bounds.size.width == 100);
}

test "flex grow accounts for a min-clamped sibling, no overflow" {
    var eng = LayoutEngine.init(std.testing.allocator);
    defer eng.deinit();

    // A grows from its min floor (200), not its small basis (50): that floor must
    // count in the free space so B's grow can't overrun the 300px row. The old
    // path clamped A up to 200 AFTER distributing grow, overflowing the row by 50
    // (the dashboard's overview/sales cards ran off the edge this way).
    const row = try eng.add_node(.{
        .flex_direction = .row,
        .flex_wrap = .wrap,
        .width = .{ .px = 300 },
        .height = .{ .px = 50 },
    });
    const a = try eng.add_node(.{
        .width = .{ .px = 50 },
        .min_width = .{ .px = 200 },
        .height = .{ .px = 50 },
        .flex_grow = 1,
    });
    const b = try eng.add_node(.{
        .width = .{ .px = 50 },
        .height = .{ .px = 50 },
        .flex_grow = 1,
    });
    try eng.add_child(row, a);
    try eng.add_child(row, b);
    eng.set_root(row);
    eng.compute(.{ .width = 300, .height = 50 });

    try std.testing.expect(eng.get_bounds(a).size.width == 225);
    const bb = eng.get_bounds(b);
    try std.testing.expect(bb.origin.x == 225 and bb.size.width == 75);
}

test "flex grow is capped by max_width" {
    var eng = LayoutEngine.init(std.testing.allocator);
    defer eng.deinit();

    // A bare grow child in a 200px row would fill to 200, but max_width=80 caps
    // it: the box AND its child-layout track stay 80 (a lone wrapped card whose
    // header row must not spill its icon past the clamped width).
    const row = try eng.add_node(.{
        .flex_direction = .row,
        .width = .{ .px = 200 },
        .height = .{ .px = 50 },
    });
    const a = try eng.add_node(.{
        .flex_grow = 1,
        .max_width = .{ .px = 80 },
        .height = .{ .px = 50 },
    });
    try eng.add_child(row, a);
    eng.set_root(row);
    eng.compute(.{ .width = 200, .height = 50 });

    try std.testing.expect(eng.get_bounds(a).size.width == 80);
}

test "flex wrap handles a full MAX_FLEX_CHILDREN line without overflow" {
    var eng = LayoutEngine.init(std.testing.allocator);
    defer eng.deinit();

    // Exactly the fixed-buffer max: must lay out without smashing the stack
    // scratch (the release cap @min protects beyond this; debug asserts it).
    const row = try eng.add_node(.{
        .flex_direction = .row,
        .flex_wrap = .wrap,
        .width = .{ .px = 1000 },
    });
    var i: usize = 0;
    while (i < LayoutEngine.MAX_FLEX_CHILDREN) : (i += 1) {
        const c = try eng.add_node(.{ .width = .{ .px = 10 }, .height = .{ .px = 10 } });
        try eng.add_child(row, c);
    }
    eng.set_root(row);
    eng.compute(.{ .width = 1000, .height = 1000 });

    try std.testing.expect(eng.get_bounds(row).size.width == 1000);
}

test "clear reuses node slots across frames (no per-frame alloc growth)" {
    var eng = LayoutEngine.init(std.testing.allocator);
    defer eng.deinit();

    // Build, clear, rebuild: the second frame must reuse slots (nodes pool does
    // not grow) and still compute correct bounds.
    for (0..3) |_| {
        eng.clear();
        const root = try eng.add_node(.{
            .flex_direction = .row,
            .width = .{ .px = 100 },
            .height = .{ .px = 20 },
        });
        const a = try eng.add_node(.{ .width = .{ .px = 40 }, .height = .{ .px = 20 } });
        try eng.add_child(root, a);
        eng.set_root(root);
        eng.compute(.{ .width = 100, .height = 100 });
        try std.testing.expect(eng.get_bounds(a).size.width == 40);
    }
    try std.testing.expect(eng.nodes.items.len == 2); // high-water, never grew
}

test "wrap row reports stacked height so a sibling below doesn't overlap" {
    var eng = LayoutEngine.init(std.testing.allocator);
    defer eng.deinit();

    // A 250px column holding a wrapping grid then a footer. The grid has three
    // 120px boxes, 10px gaps: two fit on line 1 (120+10+120=250), the third
    // wraps -> grid height = 30 + 10 + 30 = 70. The footer must sit at y=70, not
    // overlap at the single-line height of 30 (the height-for-width bug).
    const col = try eng.add_node(.{
        .flex_direction = .column,
        .width = .{ .px = 250 },
        .height = .{ .px = 400 },
        .row_gap = .{ .px = 0 },
    });
    const grid = try eng.add_node(.{
        .flex_direction = .row,
        .flex_wrap = .wrap,
        .column_gap = .{ .px = 10 },
        .row_gap = .{ .px = 10 },
    });
    try eng.add_child(col, grid);
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const box = try eng.add_node(.{ .width = .{ .px = 120 }, .height = .{ .px = 30 } });
        try eng.add_child(grid, box);
    }
    const footer = try eng.add_node(.{ .width = .{ .px = 250 }, .height = .{ .px = 20 } });
    try eng.add_child(col, footer);
    eng.set_root(col);
    eng.compute(.{ .width = 250, .height = 400 });

    try std.testing.expect(eng.get_bounds(footer).origin.y == 70);
}

test "grid_cols packs exactly N equal tracks per row" {
    var eng = LayoutEngine.init(std.testing.allocator);
    defer eng.deinit();

    // grid_cols base=2 in a 410px row, 10px gaps: track = (410-10)/2 = 200. Four
    // children -> two rows of two; the third wraps below at row_gap 10 (y=60).
    const row = try eng.add_node(.{
        .flex_direction = .row,
        .flex_wrap = .wrap,
        .grid_cols = .{ .base = 2 },
        .width = .{ .px = 410 },
        .height = .{ .px = 400 },
        .column_gap = .{ .px = 10 },
        .row_gap = .{ .px = 10 },
    });
    var ids: [4]LayoutId = undefined;
    for (&ids) |*id| {
        id.* = try eng.add_node(.{ .height = .{ .px = 50 } });
        try eng.add_child(row, id.*);
    }
    eng.set_root(row);
    eng.compute(.{ .width = 410, .height = 400 });

    try std.testing.expect(eng.get_bounds(ids[0]).origin.x == 0);
    try std.testing.expect(eng.get_bounds(ids[0]).size.width == 200);
    try std.testing.expect(eng.get_bounds(ids[1]).origin.x == 210);
    try std.testing.expect(eng.get_bounds(ids[1]).size.width == 200);
    const c2 = eng.get_bounds(ids[2]);
    try std.testing.expect(c2.origin.x == 0 and c2.origin.y == 60);
}

test "grid_cols resolves a responsive column count from the container width" {
    var eng = LayoutEngine.init(std.testing.allocator);
    defer eng.deinit();

    // Same tree, 1000px row, base=1 sm=2 xl=4: at 1000 (>= sm, < xl) it picks 2
    // cols. track = (1000-10)/2 = 495. Second child at x=505, third wraps.
    const row = try eng.add_node(.{
        .flex_direction = .row,
        .flex_wrap = .wrap,
        .grid_cols = .{ .base = 1, .sm = 2, .xl = 4 },
        .width = .{ .px = 1000 },
        .height = .{ .px = 400 },
        .column_gap = .{ .px = 10 },
        .row_gap = .{ .px = 10 },
    });
    var ids: [4]LayoutId = undefined;
    for (&ids) |*id| {
        id.* = try eng.add_node(.{ .height = .{ .px = 50 } });
        try eng.add_child(row, id.*);
    }
    eng.set_root(row);
    eng.compute(.{ .width = 1000, .height = 400 });

    try std.testing.expect(eng.get_bounds(ids[1]).origin.x == 505);
    try std.testing.expect(eng.get_bounds(ids[2]).origin.y == 60);
}

test "max_width clamps a node's resolved size" {
    var eng = LayoutEngine.init(std.testing.allocator);
    defer eng.deinit();

    // width 300 but max_width 120 -> clamps to 120.
    const root = try eng.add_node(.{
        .width = .{ .px = 300 },
        .height = .{ .px = 40 },
        .max_width = .{ .px = 120 },
    });
    eng.set_root(root);
    eng.compute(.{ .width = 500, .height = 500 });

    try std.testing.expect(eng.get_bounds(root).size.width == 120);
}

test "min_width wins over max_width when they cross" {
    var eng = LayoutEngine.init(std.testing.allocator);
    defer eng.deinit();

    // width 10, min 80, max 50: max pulls to 50, then min pulls up to 80 (min wins).
    const root = try eng.add_node(.{
        .width = .{ .px = 10 },
        .height = .{ .px = 40 },
        .min_width = .{ .px = 80 },
        .max_width = .{ .px = 50 },
    });
    eng.set_root(root);
    eng.compute(.{ .width = 500, .height = 500 });

    try std.testing.expect(eng.get_bounds(root).size.width == 80);
}

test "flex_shrink distributes negative free space" {
    var eng = LayoutEngine.init(std.testing.allocator);
    defer eng.deinit();

    // Two 100px children (shrink 1 each) in a 120px row: 80px overflow shrinks by
    // shrink*base weight (equal here) -> 40px off each -> 60px each.
    const row = try eng.add_node(.{
        .flex_direction = .row,
        .width = .{ .px = 120 },
        .height = .{ .px = 30 },
    });
    const a = try eng.add_node(.{ .width = .{ .px = 100 }, .height = .{ .px = 30 } });
    const b = try eng.add_node(.{ .width = .{ .px = 100 }, .height = .{ .px = 30 } });
    try eng.add_child(row, a);
    try eng.add_child(row, b);
    eng.set_root(row);
    eng.compute(.{ .width = 120, .height = 100 });

    try std.testing.expect(eng.get_bounds(a).size.width == 60);
    try std.testing.expect(eng.get_bounds(b).size.width == 60);
}

test "flex_shrink floors a child at its min_width" {
    var eng = LayoutEngine.init(std.testing.allocator);
    defer eng.deinit();

    // 100px child, min 70, alone shrinking in an 50px row: would shrink to 50 but
    // the min floor holds it at 70 (overflows, as CSS does).
    const row = try eng.add_node(.{
        .flex_direction = .row,
        .width = .{ .px = 50 },
        .height = .{ .px = 30 },
    });
    const a = try eng.add_node(.{
        .width = .{ .px = 100 },
        .height = .{ .px = 30 },
        .min_width = .{ .px = 70 },
    });
    try eng.add_child(row, a);
    eng.set_root(row);
    eng.compute(.{ .width = 50, .height = 100 });

    try std.testing.expect(eng.get_bounds(a).size.width == 70);
}

test "flex_shrink does not run when shrink is 0" {
    var eng = LayoutEngine.init(std.testing.allocator);
    defer eng.deinit();

    // shrink 0 opts out: the child keeps its 100px base and overflows the 60px row.
    const row = try eng.add_node(.{
        .flex_direction = .row,
        .width = .{ .px = 60 },
        .height = .{ .px = 30 },
    });
    const a = try eng.add_node(.{
        .width = .{ .px = 100 },
        .height = .{ .px = 30 },
        .flex_shrink = 0,
    });
    try eng.add_child(row, a);
    eng.set_root(row);
    eng.compute(.{ .width = 60, .height = 100 });

    try std.testing.expect(eng.get_bounds(a).size.width == 100);
}

// A fake text leaf: natural width 200, min-content (widest word) 40.
const ProbeWide = struct {
    fn measure(_: *anyopaque, p: SizeProposal) Size(f32) {
        if (p.min_content) return .{ .width = 40, .height = 10 };
        return .{ .width = 200, .height = 10 };
    }
};

test "flex auto-min floors a measured child at its min-content" {
    var eng = LayoutEngine.init(std.testing.allocator);
    defer eng.deinit();

    // Default .auto min: a would shrink to 20 in the 80px row, but the CSS auto
    // floor holds it at its 40px min-content (sibling b cannot give - shrink 0).
    const row = try eng.add_node(.{
        .flex_direction = .row,
        .width = .{ .px = 80 },
        .height = .{ .px = 20 },
    });
    var ctx: u8 = 0;
    const a = try eng.add_node_with_measure(.{}, ProbeWide.measure, &ctx);
    const b = try eng.add_node(.{
        .width = .{ .px = 60 },
        .height = .{ .px = 20 },
        .flex_shrink = 0,
    });
    try eng.add_child(row, a);
    try eng.add_child(row, b);
    eng.set_root(row);
    eng.compute(.{ .width = 80, .height = 20 });

    try std.testing.expect(eng.get_bounds(a).size.width == 40);
}

test "flex auto-min takes the max of children (column) for the floor" {
    var eng = LayoutEngine.init(std.testing.allocator);
    defer eng.deinit();

    // A grow column whose only child is the 200/40 leaf: its min-content along the
    // row's main axis is max(child) = 40, so the column floors at 40, not 0.
    const row = try eng.add_node(.{
        .flex_direction = .row,
        .width = .{ .px = 100 },
        .height = .{ .px = 30 },
    });
    const col = try eng.add_node(.{ .flex_direction = .column, .flex_grow = 1 });
    var ctx: u8 = 0;
    const leaf = try eng.add_node_with_measure(.{}, ProbeWide.measure, &ctx);
    const btn = try eng.add_node(.{
        .width = .{ .px = 90 },
        .height = .{ .px = 30 },
        .flex_shrink = 0,
    });
    try eng.add_child(col, leaf);
    try eng.add_child(row, col);
    try eng.add_child(row, btn);
    eng.set_root(row);
    eng.compute(.{ .width = 100, .height = 30 });

    try std.testing.expect(eng.get_bounds(col).size.width == 40);
}

test "flex auto-min sums children (row) for the floor" {
    var eng = LayoutEngine.init(std.testing.allocator);
    defer eng.deinit();

    // A grow row of two 200/40 leaves: its min-content sums to 80, so it floors at
    // 80 (no_wrap, same axis) rather than collapsing under the non-shrink sibling.
    const outer = try eng.add_node(.{
        .flex_direction = .row,
        .width = .{ .px = 120 },
        .height = .{ .px = 30 },
    });
    const inner = try eng.add_node(.{ .flex_direction = .row, .flex_grow = 1 });
    var ctx: u8 = 0;
    const a = try eng.add_node_with_measure(.{}, ProbeWide.measure, &ctx);
    const b = try eng.add_node_with_measure(.{}, ProbeWide.measure, &ctx);
    const btn = try eng.add_node(.{
        .width = .{ .px = 90 },
        .height = .{ .px = 30 },
        .flex_shrink = 0,
    });
    try eng.add_child(inner, a);
    try eng.add_child(inner, b);
    try eng.add_child(outer, inner);
    try eng.add_child(outer, btn);
    eng.set_root(outer);
    eng.compute(.{ .width = 120, .height = 30 });

    try std.testing.expect(eng.get_bounds(inner).size.width == 80);
}

test "flex_basis seeds the main size before grow" {
    var eng = LayoutEngine.init(std.testing.allocator);
    defer eng.deinit();

    // No width, flex_basis 60 in a row: the child starts at 60 on the main axis
    // (the old path resolved a basis-only child to 0).
    const row = try eng.add_node(.{
        .flex_direction = .row,
        .width = .{ .px = 200 },
        .height = .{ .px = 30 },
    });
    const a = try eng.add_node(.{ .height = .{ .px = 30 }, .flex_basis = .{ .px = 60 } });
    try eng.add_child(row, a);
    eng.set_root(row);
    eng.compute(.{ .width = 200, .height = 100 });

    try std.testing.expect(eng.get_bounds(a).size.width == 60);
}

test "flex_basis overrides width as the main base" {
    var eng = LayoutEngine.init(std.testing.allocator);
    defer eng.deinit();

    // width 40 but flex_basis 90: basis wins on the main axis.
    const row = try eng.add_node(.{
        .flex_direction = .row,
        .width = .{ .px = 200 },
        .height = .{ .px = 30 },
    });
    const a = try eng.add_node(.{
        .width = .{ .px = 40 },
        .height = .{ .px = 30 },
        .flex_basis = .{ .px = 90 },
    });
    try eng.add_child(row, a);
    eng.set_root(row);
    eng.compute(.{ .width = 200, .height = 100 });

    try std.testing.expect(eng.get_bounds(a).size.width == 90);
}
