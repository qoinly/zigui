// Page-route navigation, the Flutter-feel shell. The route STACK is plain app
// state (immediate-mode: UI is a function of state, so a stack is just data); the
// app owns the route->view dispatch while this file owns the machine: the stack
// ops and the app-bar chrome (a flat shadcn bar with an auto back-chevron at depth
// > 1). The platform Back / desktop Esc -> pop wiring lives in the paint loop
// (PaintContext.take_back) + the facade handle_back.
//
// Navigation carries data both ways, the startActivity/onActivityResult shape: a
// push hands the new page a byte payload (its args, an intent's extras), and a page
// stages a result that pop delivers once to the parent (setResult). Both are inline
// fixed storage, so the whole stack stays allocation-free.

const std = @import("std");
const render = @import("../render/root.zig");
const RenderBuilder = render.RenderBuilder;
const RenderError = render.RenderError;
const types = @import("../window/types.zig");
const Theme = types.Theme;
const label = @import("../render/label.zig");
const icon_render = @import("../render/icon.zig");
const custom_paint = @import("../window/paint.zig");
const Quad = @import("../primitives.zig").Quad;

// Per-entry byte cap for a route id and its title; a stack is a handful of short
// routes, so fixed inline storage keeps NavStack allocation-free.
pub const ROUTE_MAX: usize = 64;
pub const DEPTH_MAX: usize = 12;

// Per-entry byte cap for a forward payload (push args) and a returned result; a
// hard cap rather than truncation, so a caller never silently loses data.
pub const ARG_MAX: usize = 256;

// The app-bar band height in points; the back-chevron reuses it as a square slot.
pub const BAR_H: f32 = 48;

pub const NavStack = struct {
    routes: [DEPTH_MAX][ROUTE_MAX]u8 = undefined,
    route_lens: [DEPTH_MAX]usize = undefined,
    titles: [DEPTH_MAX][ROUTE_MAX]u8 = undefined,
    title_lens: [DEPTH_MAX]usize = undefined,
    // The forward payload each entry was pushed with (its args / intent extras).
    args: [DEPTH_MAX][ARG_MAX]u8 = undefined,
    arg_lens: [DEPTH_MAX]usize = undefined,
    // The result an entry staged for its parent (setResult); 0 len = none staged.
    results: [DEPTH_MAX][ARG_MAX]u8 = undefined,
    result_lens: [DEPTH_MAX]usize = undefined,
    depth: usize = 0, // 0 until the first go/push seeds the root
    // The result a pop handed back, awaiting the parent's one take_result.
    result_out: [ARG_MAX]u8 = undefined,
    result_out_len: usize = 0,
    result_out_valid: bool = false,

    // Slide transition: a brief animated push/pop. `top` is always the destination;
    // these hold the OTHER page (push: the parent left behind; pop: the popped page)
    // so the navigator can build both during the slide. All inline - no allocation.
    trans_active: bool = false,
    trans_pop: bool = false, // direction: false = push (new slides in from the right)
    trans_start: f64 = -1, // paint.now_s when the slide began; < 0 = not yet stamped
    trans_route: [ROUTE_MAX]u8 = undefined,
    trans_route_len: usize = 0,
    trans_title: [ROUTE_MAX]u8 = undefined,
    trans_title_len: usize = 0,
    trans_args: [ARG_MAX]u8 = undefined,
    trans_arg_len: usize = 0,
    // While true, current()/current_title()/current_args() return the transition's
    // from-page; the navigator flips it around building the leaving page.
    build_from: bool = false,

    // Flat replace (reset to a single root entry), the showcase's go(section). A
    // reseeded root has no parent to receive a result, so any pending one is dropped.
    pub fn go(self: *NavStack, route: []const u8, title: []const u8) void {
        std.debug.assert(route.len > 0); // a route id is never empty
        std.debug.assert(title.len > 0);
        self.depth = 0;
        self.result_out_valid = false;
        self.trans_active = false; // a flat replace cancels any mid-flight slide
        self.build_from = false;
        self.push(route, title);
        std.debug.assert(self.depth == 1); // go always leaves exactly the root
    }

    // Push a route with no payload (the plain detail-page move).
    pub fn push(self: *NavStack, route: []const u8, title: []const u8) void {
        std.debug.assert(route.len > 0);
        std.debug.assert(title.len > 0);
        self.push_with(route, title, "");
    }

    // Push a route carrying a forward payload (startActivity with extras); the new
    // page reads it via current_args. A full stack is a no-op, not an overflow.
    pub fn push_with(
        self: *NavStack,
        route: []const u8,
        title: []const u8,
        data: []const u8,
    ) void {
        std.debug.assert(route.len > 0);
        std.debug.assert(title.len > 0);
        std.debug.assert(data.len <= ARG_MAX); // a payload must fit the entry
        if (self.depth >= DEPTH_MAX) return;
        if (self.depth >= 1) self.begin_transition(false); // slide the new page in
        set_str(&self.routes[self.depth], &self.route_lens[self.depth], route);
        set_str(&self.titles[self.depth], &self.title_lens[self.depth], title);
        store_bytes(&self.args[self.depth], &self.arg_lens[self.depth], data);
        self.result_lens[self.depth] = 0; // a fresh entry has staged no result
        self.depth += 1;
        std.debug.assert(self.arg_lens[self.depth - 1] == data.len); // full payload stored
    }

    // Pop back one level; the root never pops (Back at the root backgrounds the app).
    // A staged result on the popped entry is delivered to the parent's take_result.
    pub fn pop(self: *NavStack) void {
        std.debug.assert(self.depth <= DEPTH_MAX); // the stack never overflows its storage
        const before = self.depth;
        if (self.depth > 1) {
            self.begin_transition(true); // slide the popped page out
            const top = self.depth - 1;
            if (self.result_lens[top] > 0) {
                const staged = self.results[top][0..self.result_lens[top]];
                store_bytes(&self.result_out, &self.result_out_len, staged);
                self.result_out_valid = true;
            }
            self.depth -= 1;
        }
        std.debug.assert(self.depth == before or self.depth + 1 == before); // at most one level
    }

    // Stage a result for the current page's parent (setResult); pop delivers it.
    pub fn set_result(self: *NavStack, data: []const u8) void {
        std.debug.assert(self.depth > 0); // a result needs a live page to stage on
        std.debug.assert(data.len <= ARG_MAX);
        const i = self.depth - 1;
        store_bytes(&self.results[i], &self.result_lens[i], data);
        std.debug.assert(self.result_lens[i] == data.len); // the full result was staged
    }

    // The parent reads a just-returned result exactly once (onActivityResult); the
    // slice points into the stack, so copy it before the next pop. Null = none.
    pub fn take_result(self: *NavStack) ?[]const u8 {
        if (!self.result_out_valid) return null;
        std.debug.assert(self.result_out_len <= ARG_MAX);
        self.result_out_valid = false;
        return self.result_out[0..self.result_out_len];
    }

    pub fn current(self: *const NavStack) []const u8 {
        std.debug.assert(self.depth <= DEPTH_MAX);
        if (self.build_from and self.trans_active) return self.trans_route[0..self.trans_route_len];
        if (self.depth == 0) return "";
        const i = self.depth - 1;
        std.debug.assert(self.route_lens[i] <= ROUTE_MAX); // the slice stays inside the entry
        return self.routes[i][0..self.route_lens[i]];
    }

    pub fn current_title(self: *const NavStack) []const u8 {
        std.debug.assert(self.depth <= DEPTH_MAX);
        if (self.build_from and self.trans_active) return self.trans_title[0..self.trans_title_len];
        if (self.depth == 0) return "";
        const i = self.depth - 1;
        std.debug.assert(self.title_lens[i] <= ROUTE_MAX);
        return self.titles[i][0..self.title_lens[i]];
    }

    // The forward payload the current page was pushed with (its intent extras).
    pub fn current_args(self: *const NavStack) []const u8 {
        std.debug.assert(self.depth <= DEPTH_MAX);
        if (self.build_from and self.trans_active) return self.trans_args[0..self.trans_arg_len];
        if (self.depth == 0) return "";
        const i = self.depth - 1;
        std.debug.assert(self.arg_lens[i] <= ARG_MAX);
        return self.args[i][0..self.arg_lens[i]];
    }

    // Capture the live top as the transition's from-page (push: the parent being left;
    // pop: the page being popped), so the navigator can build both during the slide.
    fn begin_transition(self: *NavStack, is_pop: bool) void {
        std.debug.assert(self.depth > 0); // a transition captures a live page
        const i = self.depth - 1;
        self.trans_active = true;
        self.trans_pop = is_pop;
        self.trans_start = -1; // stamped on the first render frame
        set_str(&self.trans_route, &self.trans_route_len, self.routes[i][0..self.route_lens[i]]);
        set_str(&self.trans_title, &self.trans_title_len, self.titles[i][0..self.title_lens[i]]);
        store_bytes(&self.trans_args, &self.trans_arg_len, self.args[i][0..self.arg_lens[i]]);
    }
};

fn set_str(buf: *[ROUTE_MAX]u8, len: *usize, s: []const u8) void {
    std.debug.assert(s.len > 0); // a route/title segment is never empty
    const n = @min(s.len, ROUTE_MAX);
    @memcpy(buf[0..n], s[0..n]);
    len.* = n;
}

fn store_bytes(buf: []u8, len: *usize, s: []const u8) void {
    std.debug.assert(buf.len > 0); // the entry has storage to copy into
    const n = @min(s.len, buf.len);
    @memcpy(buf[0..n], s[0..n]);
    len.* = n;
}

pub const AppBarOptions = struct {
    show_back: bool = false,
    paint: ?*custom_paint.PaintContext = null,
};

// The back-chevron tap funnels through the same back request as Esc / the Android
// Back button (handle_back pops on it), so a navigator needs no per-bar callback.
fn request_back(ctx: ?*anyopaque) void {
    std.debug.assert(ctx != null); // the hitbox always carries the PaintContext
    const p: *custom_paint.PaintContext = @ptrCast(@alignCast(ctx.?));
    p.back_pressed = true;
    p.request_redraw();
}

// The flat themed band: theme background + a 1px bottom border (the title-band /
// sidebar idiom), the centered title, and an optional left back-chevron whose
// square slot is hovered + clickable.
pub fn app_bar(
    b: *RenderBuilder,
    x: f32,
    y: f32,
    w: f32,
    title: []const u8,
    theme: *const Theme,
    opts: AppBarOptions,
) RenderError!void {
    std.debug.assert(w > 0);
    var bar = Quad.init(x, y, w, BAR_H);
    _ = bar.set_background(theme.background);
    try b.append_quad(bar);
    var sep = Quad.init(x, y + BAR_H - 1, w, 1);
    _ = sep.set_background(theme.border);
    try b.append_quad(sep);

    var title_x = x + 16;
    if (opts.show_back) {
        std.debug.assert(w >= BAR_H); // the bar must seat the square chevron slot
        if (opts.paint) |p| {
            if (p.is_hovered(x, y, BAR_H, BAR_H)) {
                var wash = Quad.init(x, y, BAR_H, BAR_H);
                _ = wash.set_background(.{ .r = 1, .g = 1, .b = 1, .a = 0.06 });
                try b.append_quad(wash);
            }
            try p.add_hitbox(.{
                .x = x,
                .y = y,
                .w = BAR_H,
                .h = BAR_H,
                .on_click = request_back,
                .ctx = p,
            });
        }
        _ = try icon_render.render_icon_centered_xy(b, x, y, BAR_H, BAR_H, .chevron_left, .{
            .point_size = 22,
            .color = theme.foreground,
        });
        title_x = x + BAR_H;
    }
    std.debug.assert(title_x >= x); // the title never sits left of the bar origin

    const ls = label.Style{ .font_size = 17, .weight = .semi_bold, .color = theme.foreground };
    const m = label.measure(b, title, ls);
    const top = y + (BAR_H - (m.ascent + m.descent)) / 2;
    _ = try label.render(b, title_x, top, title, ls);
}
