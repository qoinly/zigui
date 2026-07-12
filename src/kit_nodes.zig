// Kit components as Node-tree builders: each returns a *Node leaf carrying a
// measure + draw adapter and an arena-stored Options payload. The
// @ptrCast(@alignCast(ctx)) back to the real Spec type lives ONLY in these
// adapters - the single bridge between the type-erased leaf and the typed kit
// render.

const std = @import("std");
const node = @import("node.zig");
const kit = @import("kit/root.zig");
const types = @import("window/types.zig");
const geometry = @import("geometry.zig");
const builder = @import("render/builder.zig");
const button_kit = @import("kit/button.zig");
const badge_kit = @import("kit/badge.zig");
const avatar_kit = @import("kit/avatar.zig");
const checkbox_kit = @import("kit/checkbox.zig");
const radio_kit = @import("kit/radio.zig");
const switch_kit = @import("kit/switch.zig");
const kbd_kit = @import("kit/kbd.zig");
const toggle_button_kit = @import("kit/toggle_button.zig");
const separator_kit = @import("kit/separator.zig");
const skeleton_kit = @import("kit/skeleton.zig");
const progress_kit = @import("kit/progress.zig");
const spinner_kit = @import("kit/spinner.zig");
const input_kit = @import("kit/input.zig");
const editable_kit = @import("kit/editable.zig");
const textarea_kit = @import("kit/textarea.zig");
const alert_kit = @import("kit/alert.zig");
const tabs_kit = @import("kit/tabs.zig");
const bottom_bar_kit = @import("kit/bottom_bar.zig");
const top_bar_kit = @import("kit/top_bar.zig");
const toggle_group_kit = @import("kit/toggle_group.zig");
const slider_kit = @import("kit/slider.zig");
const select_kit = @import("kit/select.zig");
const chart_kit = @import("kit/chart.zig");
const dialog_kit = @import("kit/dialog.zig");
const sidebar_kit = @import("kit/sidebar.zig");
const tabbar_kit = @import("kit/tabbar.zig");
const menu_kit = @import("kit/menu.zig");
const resizable_kit = @import("kit/resizable.zig");
const toast_kit = @import("kit/toast.zig");
const tooltip_kit = @import("kit/tooltip.zig");
const navigator_kit = @import("kit/navigator.zig");
const popover_kit = @import("kit/popover.zig");
const sheet_kit = @import("kit/sheet.zig");
const label_render = @import("render/label.zig");
const icon_render = @import("render/icon.zig");
const color = @import("color.zig");
const callbacks = @import("callbacks.zig");
const custom_paint = @import("window/paint.zig");
const custom_shell = @import("custom_shell.zig");
const theme_resolve = @import("kit/theme_resolve.zig");
const primitives = @import("primitives.zig");
const frame_mod = @import("frame.zig");

const Node = node.Node;
const Theme = types.Theme;
const Variant = types.Variant;
const Size = types.Size;
const Rgba = color.Rgba;
const RenderBuilder = builder.RenderBuilder;
const RenderError = builder.RenderError;
const SizeF = geometry.SizeF;
const BoundsF = geometry.BoundsF;
const A = std.mem.Allocator;

pub const Btn = struct {
    variant: Variant = .default,
    size: Size = .default,
    disabled: bool = false,
    icon: ?icon_render.Icon = null,
    loading: bool = false,
    // spin_phase is caller-owned rotation in cycles; advance it each frame to animate.
    spin_phase: f32 = 0,
    // Wire all three to make the button live: paint enables hover + the click
    // hitbox, on_click fires on release, ctx is handed back to it.
    paint: ?*custom_paint.PaintContext = null,
    on_click: ?callbacks.ClickFn = null,
    ctx: ?*anyopaque = null,
    // Laid-out box rect, only known post-layout; lets a caller anchor an overlay
    // (popover, menu, tooltip) to the trigger.
    rect_out: ?*[4]f32 = null,
};

const ButtonSpec = struct {
    theme: *const Theme,
    text: []const u8,
    o: Btn,
    fn opts(self: *const ButtonSpec) button_kit.ButtonOptions {
        return .{
            .variant = self.o.variant,
            .size = self.o.size,
            .disabled = self.o.disabled,
            .icon = self.o.icon,
            .loading = self.o.loading,
            .spin_phase = self.o.spin_phase,
            .paint = self.o.paint,
            .on_click = self.o.on_click,
            .ctx = self.o.ctx,
            .theme = self.theme,
        };
    }
    fn measure(b: *RenderBuilder, ctx: *anyopaque) SizeF {
        const self: *ButtonSpec = @ptrCast(@alignCast(ctx));
        return button_kit.measure(b, .{}, self.text, self.opts());
    }
    fn draw(b: *RenderBuilder, ctx: *anyopaque, r: BoundsF) RenderError!void {
        const self: *ButtonSpec = @ptrCast(@alignCast(ctx));
        std.debug.assert(r.size.width >= 0);
        if (r.size.width <= 0) return; // button_kit.render hard-asserts w>0; no-op unsized parent
        _ = try button_kit.render(b, r.origin.x, r.origin.y, r.size.width, self.text, self.opts());
        if (self.o.rect_out) |ro| {
            ro.* = .{ r.origin.x, r.origin.y, r.size.width, r.size.height };
        }
    }
};

pub const AppBar = struct {
    show_back: bool = false,
    paint: ?*custom_paint.PaintContext = null,
};

const AppBarSpec = struct {
    theme: *const Theme,
    title: []const u8,
    o: AppBar,
    fn measure(b: *RenderBuilder, ctx: *anyopaque) SizeF {
        _ = b;
        _ = ctx;
        return SizeF.init(0, navigator_kit.BAR_H);
    }
    fn draw(b: *RenderBuilder, ctx: *anyopaque, r: BoundsF) RenderError!void {
        const self: *AppBarSpec = @ptrCast(@alignCast(ctx));
        if (r.size.width <= 0) return;
        try navigator_kit.app_bar(
            b,
            r.origin.x,
            r.origin.y,
            r.size.width,
            self.title,
            self.theme,
            .{ .show_back = self.o.show_back, .paint = self.o.paint },
        );
    }
};

pub fn app_bar(a: A, theme: *const Theme, title: []const u8, o: AppBar) *Node {
    const spec = a.create(AppBarSpec) catch @panic("node arena oom");
    spec.* = .{ .theme = theme, .title = title, .o = o };
    return node.leaf(a, AppBarSpec.measure, AppBarSpec.draw, spec);
}

pub fn button(a: A, theme: *const Theme, text: []const u8, o: Btn) *Node {
    const spec = a.create(ButtonSpec) catch @panic("node arena oom");
    spec.* = .{ .theme = theme, .text = text, .o = o };
    return node.leaf(a, ButtonSpec.measure, ButtonSpec.draw, spec);
}

const BadgeSpec = struct {
    theme: *const Theme,
    text: []const u8,
    variant: Variant,
    fn opts(self: *const BadgeSpec) badge_kit.BadgeOptions {
        return .{ .variant = self.variant, .theme = self.theme };
    }
    fn measure(b: *RenderBuilder, ctx: *anyopaque) SizeF {
        const self: *BadgeSpec = @ptrCast(@alignCast(ctx));
        return badge_kit.measure(b, .{}, self.text, self.opts());
    }
    fn draw(b: *RenderBuilder, ctx: *anyopaque, r: BoundsF) RenderError!void {
        const self: *BadgeSpec = @ptrCast(@alignCast(ctx));
        _ = try badge_kit.render(b, r.origin.x, r.origin.y, self.text, self.opts());
    }
};

pub fn badge(a: A, theme: *const Theme, text: []const u8, variant: Variant) *Node {
    const spec = a.create(BadgeSpec) catch @panic("node arena oom");
    spec.* = .{ .theme = theme, .text = text, .variant = variant };
    return node.leaf(a, BadgeSpec.measure, BadgeSpec.draw, spec);
}

const AvatarSpec = struct {
    theme: *const Theme,
    initials: []const u8,
    size: f32,
    fn opts(self: *const AvatarSpec) avatar_kit.AvatarOptions {
        return .{ .initials = self.initials, .theme = self.theme, .size = self.size };
    }
    fn measure(b: *RenderBuilder, ctx: *anyopaque) SizeF {
        const self: *AvatarSpec = @ptrCast(@alignCast(ctx));
        return avatar_kit.measure(b, .{}, self.opts());
    }
    fn draw(b: *RenderBuilder, ctx: *anyopaque, r: BoundsF) RenderError!void {
        const self: *AvatarSpec = @ptrCast(@alignCast(ctx));
        _ = try avatar_kit.render(b, r.origin.x, r.origin.y, self.opts());
    }
};

pub fn avatar(a: A, theme: *const Theme, initials: []const u8, size: f32) *Node {
    const spec = a.create(AvatarSpec) catch @panic("node arena oom");
    spec.* = .{ .theme = theme, .initials = initials, .size = size };
    return node.leaf(a, AvatarSpec.measure, AvatarSpec.draw, spec);
}

// Shared wiring for the simple toggle/select leaves (checkbox, switch, radio):
// paint enables the hitbox + hover, on_change fires the gesture, ctx is handed
// straight back to it.
pub const Wire = struct {
    paint: ?*custom_paint.PaintContext = null,
    on_change: ?callbacks.ClickFn = null,
    ctx: ?*anyopaque = null,
};

const CheckboxSpec = struct {
    theme: *const Theme,
    checked: bool,
    label: []const u8,
    w: Wire,
    fn opts(self: *const CheckboxSpec) checkbox_kit.CheckboxOptions {
        return .{
            .checked = self.checked,
            .label = self.label,
            .theme = self.theme,
            .paint = self.w.paint,
            .on_toggle = self.w.on_change,
            .ctx = self.w.ctx,
        };
    }
    fn measure(b: *RenderBuilder, ctx: *anyopaque) SizeF {
        const self: *CheckboxSpec = @ptrCast(@alignCast(ctx));
        return checkbox_kit.measure(b, .{}, self.opts());
    }
    fn draw(b: *RenderBuilder, ctx: *anyopaque, r: BoundsF) RenderError!void {
        const self: *CheckboxSpec = @ptrCast(@alignCast(ctx));
        _ = try checkbox_kit.render(b, r.origin.x, r.origin.y, self.opts());
    }
};

pub fn checkbox(a: A, theme: *const Theme, checked: bool, label: []const u8, w: Wire) *Node {
    const spec = a.create(CheckboxSpec) catch @panic("node arena oom");
    spec.* = .{ .theme = theme, .checked = checked, .label = label, .w = w };
    return node.leaf(a, CheckboxSpec.measure, CheckboxSpec.draw, spec);
}

const RadioSpec = struct {
    theme: *const Theme,
    selected: bool,
    label: []const u8,
    w: Wire,
    fn opts(self: *const RadioSpec) radio_kit.RadioOptions {
        return .{
            .selected = self.selected,
            .label = self.label,
            .theme = self.theme,
            .paint = self.w.paint,
            .on_select = self.w.on_change,
            .ctx = self.w.ctx,
        };
    }
    fn measure(b: *RenderBuilder, ctx: *anyopaque) SizeF {
        const self: *RadioSpec = @ptrCast(@alignCast(ctx));
        return radio_kit.measure(b, .{}, self.opts());
    }
    fn draw(b: *RenderBuilder, ctx: *anyopaque, r: BoundsF) RenderError!void {
        const self: *RadioSpec = @ptrCast(@alignCast(ctx));
        _ = try radio_kit.render(b, r.origin.x, r.origin.y, self.opts());
    }
};

pub fn radio(a: A, theme: *const Theme, selected: bool, label: []const u8, w: Wire) *Node {
    const spec = a.create(RadioSpec) catch @panic("node arena oom");
    spec.* = .{ .theme = theme, .selected = selected, .label = label, .w = w };
    return node.leaf(a, RadioSpec.measure, RadioSpec.draw, spec);
}

// Switch, exposed as `toggle` because switch is a keyword.
const ToggleSpec = struct {
    theme: *const Theme,
    on: bool,
    label: []const u8,
    w: Wire,
    fn opts(self: *const ToggleSpec) switch_kit.SwitchOptions {
        return .{
            .on = self.on,
            .label = self.label,
            .theme = self.theme,
            .paint = self.w.paint,
            .on_toggle = self.w.on_change,
            .ctx = self.w.ctx,
        };
    }
    fn measure(b: *RenderBuilder, ctx: *anyopaque) SizeF {
        const self: *ToggleSpec = @ptrCast(@alignCast(ctx));
        return switch_kit.measure(b, .{}, self.opts());
    }
    fn draw(b: *RenderBuilder, ctx: *anyopaque, r: BoundsF) RenderError!void {
        const self: *ToggleSpec = @ptrCast(@alignCast(ctx));
        _ = try switch_kit.render(b, r.origin.x, r.origin.y, self.opts());
    }
};

pub fn toggle(a: A, theme: *const Theme, on: bool, label: []const u8, w: Wire) *Node {
    const spec = a.create(ToggleSpec) catch @panic("node arena oom");
    spec.* = .{ .theme = theme, .on = on, .label = label, .w = w };
    return node.leaf(a, ToggleSpec.measure, ToggleSpec.draw, spec);
}

// keys borrowed by ptr+len; the literal must outlive the frame (string literals
// are static, so a `&.{"\u{2318}", "K"}` call-site is safe).
const KbdSpec = struct {
    theme: *const Theme,
    keys: []const []const u8,
    fn opts(self: *const KbdSpec) kbd_kit.KbdOptions {
        return .{ .theme = self.theme };
    }
    fn measure(b: *RenderBuilder, ctx: *anyopaque) SizeF {
        const self: *KbdSpec = @ptrCast(@alignCast(ctx));
        return kbd_kit.measure(b, .{}, self.keys, self.opts());
    }
    fn draw(b: *RenderBuilder, ctx: *anyopaque, r: BoundsF) RenderError!void {
        const self: *KbdSpec = @ptrCast(@alignCast(ctx));
        _ = try kbd_kit.render(b, r.origin.x, r.origin.y, self.keys, self.opts());
    }
};

pub fn kbd(a: A, theme: *const Theme, keys: []const []const u8) *Node {
    const spec = a.create(KbdSpec) catch @panic("node arena oom");
    spec.* = .{ .theme = theme, .keys = keys };
    return node.leaf(a, KbdSpec.measure, KbdSpec.draw, spec);
}

pub const ToggleBtn = struct {
    on: bool = false,
    variant: toggle_button_kit.ToggleVariant = .default,
    size: Size = .default,
    icon: ?icon_render.Icon = null,
    paint: ?*custom_paint.PaintContext = null,
    on_toggle: ?callbacks.ClickFn = null,
    ctx: ?*anyopaque = null,
};

const ToggleButtonSpec = struct {
    theme: *const Theme,
    text: []const u8,
    o: ToggleBtn,
    fn opts(self: *const ToggleButtonSpec) toggle_button_kit.ToggleButtonOptions {
        return .{
            .on = self.o.on,
            .variant = self.o.variant,
            .size = self.o.size,
            .icon = self.o.icon,
            .paint = self.o.paint,
            .on_toggle = self.o.on_toggle,
            .ctx = self.o.ctx,
            .theme = self.theme,
        };
    }
    fn measure(b: *RenderBuilder, ctx: *anyopaque) SizeF {
        const self: *ToggleButtonSpec = @ptrCast(@alignCast(ctx));
        return toggle_button_kit.measure(b, .{}, self.text, self.opts());
    }
    fn draw(b: *RenderBuilder, ctx: *anyopaque, r: BoundsF) RenderError!void {
        const self: *ToggleButtonSpec = @ptrCast(@alignCast(ctx));
        // An icon-only toggle measured square, a labelled one to content, so the
        // laid-out rect width is the right paint width.
        const x = r.origin.x;
        const y = r.origin.y;
        _ = try toggle_button_kit.render(b, x, y, r.size.width, self.text, self.opts());
    }
};

pub fn toggle_button(a: A, theme: *const Theme, text: []const u8, o: ToggleBtn) *Node {
    const spec = a.create(ToggleButtonSpec) catch @panic("node arena oom");
    spec.* = .{ .theme = theme, .text = text, .o = o };
    return node.leaf(a, ToggleButtonSpec.measure, ToggleButtonSpec.draw, spec);
}

// Icon node options. source null = the engine default (so set_source wins);
// set it to force native (the OS's own set) or bundled (Lucide, portable).
pub const IconOpts = struct {
    size: f32 = 16,
    color: Rgba = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
    source: ?icon_render.IconSource = null,
};

const IconSpec = struct {
    glyph: icon_render.Icon,
    opts: IconOpts,
    fn measure(b: *RenderBuilder, ctx: *anyopaque) SizeF {
        _ = b;
        const self: *IconSpec = @ptrCast(@alignCast(ctx));
        // A glyph's drawn extent is only known after raster; reserve a square
        // point_size slot and centre the real sprite inside it at draw.
        std.debug.assert(self.opts.size > 0);
        return SizeF.init(self.opts.size, self.opts.size);
    }
    fn draw(b: *RenderBuilder, ctx: *anyopaque, r: BoundsF) RenderError!void {
        const self: *IconSpec = @ptrCast(@alignCast(ctx));
        std.debug.assert(r.size.width >= 0);
        std.debug.assert(r.size.height >= 0);
        const sty = icon_render.Style{
            .point_size = self.opts.size,
            .color = self.opts.color,
            .source = self.opts.source,
        };
        const o = r.origin;
        const s = r.size;
        const ic = self.glyph;
        _ = try icon_render.render_icon_centered_xy(b, o.x, o.y, s.width, s.height, ic, sty);
    }
};

// The one icon node: a portable Icon enum member drawn from the chosen source
// (native = the OS's own set, bundled = Lucide everywhere). A member with no
// glyph in that source logs one dev warning and draws nothing.
pub fn icon(a: A, ic: icon_render.Icon, opts: IconOpts) *Node {
    const spec = a.create(IconSpec) catch @panic("node arena oom");
    spec.* = .{ .glyph = ic, .opts = opts };
    return node.leaf(a, IconSpec.measure, IconSpec.draw, spec);
}

const SeparatorSpec = struct {
    theme: *const Theme,
    orientation: separator_kit.Orientation,
    fn measure(b: *RenderBuilder, ctx: *anyopaque) SizeF {
        _ = b;
        const self: *SeparatorSpec = @ptrCast(@alignCast(ctx));
        // 0 on the long axis: the hairline fills its container's cross axis via
        // stretch at layout time (horizontal in a col, vertical in a row), never
        // inflating intrinsics. THICKNESS pins the short axis.
        return switch (self.orientation) {
            .horizontal => SizeF.init(0, separator_kit.THICKNESS),
            .vertical => SizeF.init(separator_kit.THICKNESS, 0),
        };
    }
    fn draw(b: *RenderBuilder, ctx: *anyopaque, r: BoundsF) RenderError!void {
        const self: *SeparatorSpec = @ptrCast(@alignCast(ctx));
        const len = switch (self.orientation) {
            .horizontal => r.size.width,
            .vertical => r.size.height,
        };
        std.debug.assert(len >= 0);
        if (len <= 0) return; // unsized parent: nothing to draw (render asserts len>0)
        _ = try separator_kit.render(b, r.origin.x, r.origin.y, len, .{
            .orientation = self.orientation,
            .theme = self.theme,
        });
    }
};

pub fn separator(a: A, theme: *const Theme, orientation: separator_kit.Orientation) *Node {
    const spec = a.create(SeparatorSpec) catch @panic("node arena oom");
    spec.* = .{ .theme = theme, .orientation = orientation };
    return node.leaf(a, SeparatorSpec.measure, SeparatorSpec.draw, spec);
}

const FrameSpec = struct {
    source: *frame_mod.FrameSource,
    opts: frame_mod.FrameOpts,

    fn measure(b: *RenderBuilder, ctx: *anyopaque) SizeF {
        _ = b;
        _ = ctx;
        // Zero intrinsic size: the frame fills its cell (grow + cross-stretch) and
        // draw() letterboxes the source within it via fit. A reported size would
        // block the cross-axis stretch and pin the frame to its native pixels.
        return SizeF.init(0, 0);
    }

    fn draw(b: *RenderBuilder, ctx: *anyopaque, r: BoundsF) RenderError!void {
        const self: *FrameSpec = @ptrCast(@alignCast(ctx));
        std.debug.assert(r.size.width >= 0);
        std.debug.assert(r.size.height >= 0);
        const cur = self.source.acquire() orelse return; // no frame yet -> draw nothing
        const box = fit_rect(r, cur.width, cur.height, self.opts.fit);
        try b.append_frame(.{
            .bounds = box,
            .clip_bounds = .{ r.origin.x, r.origin.y, r.size.width, r.size.height },
            .tex = cur.tex,
            .tex_cbcr = cur.tex_cbcr,
            .csc = cur.csc,
            .opacity = self.opts.opacity,
        });
    }
};

// Map a source-sized frame into rect r per Fit -> {x, y, w, h} in points.
fn fit_rect(r: BoundsF, src_w: f32, src_h: f32, fit: frame_mod.Fit) [4]f32 {
    const rw = r.size.width;
    const rh = r.size.height;
    if (src_w <= 0 or src_h <= 0 or fit == .fill) {
        return .{ r.origin.x, r.origin.y, rw, rh };
    }
    const scale: f32 = switch (fit) {
        .contain => @min(rw / src_w, rh / src_h),
        .cover => @max(rw / src_w, rh / src_h),
        .native => 1.0,
        .fill => unreachable, // handled above
    };
    const w = src_w * scale;
    const h = src_h * scale;
    return .{ r.origin.x + (rw - w) / 2, r.origin.y + (rh - h) / 2, w, h };
}

// A live external frame (remote screen / video). Fills its layout cell (grow 1);
// opts.fit controls aspect within the cell. The texture is owned by `source`; this
// node only references the current frame.
pub fn frame(a: A, source: *frame_mod.FrameSource, opts: frame_mod.FrameOpts) *Node {
    const spec = a.create(FrameSpec) catch @panic("node arena oom");
    spec.* = .{ .source = source, .opts = opts };
    const n = node.leaf(a, FrameSpec.measure, FrameSpec.draw, spec);
    n.style.flex_grow = 1;
    return n;
}

const SkeletonSpec = struct {
    theme: *const Theme,
    w: f32,
    h: f32,
    radius: f32,
    fn measure(b: *RenderBuilder, ctx: *anyopaque) SizeF {
        _ = b;
        const self: *SkeletonSpec = @ptrCast(@alignCast(ctx));
        std.debug.assert(self.w > 0);
        std.debug.assert(self.h > 0);
        return SizeF.init(self.w, self.h);
    }
    fn draw(b: *RenderBuilder, ctx: *anyopaque, r: BoundsF) RenderError!void {
        const self: *SkeletonSpec = @ptrCast(@alignCast(ctx));
        std.debug.assert(r.size.width > 0);
        std.debug.assert(r.size.height > 0);
        _ = try skeleton_kit.render(b, r.origin.x, r.origin.y, r.size.width, r.size.height, .{
            .theme = self.theme,
            .radius = self.radius,
        });
    }
};

pub fn skeleton(a: A, theme: *const Theme, w: f32, h: f32, radius: f32) *Node {
    const spec = a.create(SkeletonSpec) catch @panic("node arena oom");
    spec.* = .{ .theme = theme, .w = w, .h = h, .radius = radius };
    return node.leaf(a, SkeletonSpec.measure, SkeletonSpec.draw, spec);
}

const ProgressSpec = struct {
    theme: *const Theme,
    value: f32,
    height: f32,
    indeterminate: bool = false,
    paint: ?*custom_paint.PaintContext = null, // for the indeterminate phase clock
    fn measure(b: *RenderBuilder, ctx: *anyopaque) SizeF {
        _ = b;
        const self: *ProgressSpec = @ptrCast(@alignCast(ctx));
        // 0 width: the track fills its parent via cross-stretch (put it in a col
        // or a width-sized box); height is the fixed bar thickness.
        std.debug.assert(self.height > 0);
        return SizeF.init(0, self.height);
    }
    fn draw(b: *RenderBuilder, ctx: *anyopaque, r: BoundsF) RenderError!void {
        const self: *ProgressSpec = @ptrCast(@alignCast(ctx));
        std.debug.assert(r.size.width >= 0);
        var phase: f32 = 0;
        if (self.indeterminate) if (self.paint) |p| {
            p.animating = true;
            phase = @floatCast(@mod(p.now_s * 0.6, 1.0));
        };
        _ = try progress_kit.render(b, r.origin.x, r.origin.y, r.size.width, self.value, .{
            .theme = self.theme,
            .height = self.height,
            .indeterminate = self.indeterminate,
            .phase = phase,
        });
    }
};

pub fn progress(a: A, theme: *const Theme, value: f32, height: f32) *Node {
    const spec = a.create(ProgressSpec) catch @panic("node arena oom");
    spec.* = .{ .theme = theme, .value = value, .height = height };
    return node.leaf(a, ProgressSpec.measure, ProgressSpec.draw, spec);
}

pub fn progress_indeterminate(
    a: A,
    theme: *const Theme,
    height: f32,
    paint: *custom_paint.PaintContext,
) *Node {
    const spec = a.create(ProgressSpec) catch @panic("node arena oom");
    spec.* = .{
        .theme = theme,
        .value = 0,
        .height = height,
        .indeterminate = true,
        .paint = paint,
    };
    return node.leaf(a, ProgressSpec.measure, ProgressSpec.draw, spec);
}

const SpinnerSpec = struct {
    radius: f32,
    color: Rgba,
    paint: *custom_paint.PaintContext,
    fn measure(b: *RenderBuilder, ctx: *anyopaque) SizeF {
        _ = b;
        const self: *SpinnerSpec = @ptrCast(@alignCast(ctx));
        std.debug.assert(self.radius > 0);
        // Pad past 2*radius by the dot extent so the comet dots stay inside the rect.
        const d = self.radius * 2 + self.radius * 0.52;
        return SizeF.init(d, d);
    }
    fn draw(b: *RenderBuilder, ctx: *anyopaque, r: BoundsF) RenderError!void {
        const self: *SpinnerSpec = @ptrCast(@alignCast(ctx));
        std.debug.assert(r.size.width > 0);
        std.debug.assert(r.size.height > 0);
        const cx = r.origin.x + r.size.width / 2;
        const cy = r.origin.y + r.size.height / 2;
        // Phase from the frame clock; animating=true keeps the redraw loop alive.
        const phase: f32 = @floatCast(@mod(self.paint.now_s * 1.2, 1.0));
        self.paint.animating = true;
        try spinner_kit.render(b, cx, cy, self.radius, .{ .color = self.color, .phase = phase });
    }
};

pub fn spinner(a: A, paint: *custom_paint.PaintContext, radius: f32, c: Rgba) *Node {
    const spec = a.create(SpinnerSpec) catch @panic("node arena oom");
    spec.* = .{ .radius = radius, .color = c, .paint = paint };
    return node.leaf(a, SpinnerSpec.measure, SpinnerSpec.draw, spec);
}

// The kit draws the box; the consumer owns the editor. on_focus reports the
// click, the focused input writes its laid-out box rect to rect_out (only known
// after layout) so the consumer overlays the native editor on it. disabled also
// suppresses the focus hitbox.
pub const InputWire = struct {
    paint: ?*custom_paint.PaintContext = null,
    on_focus: ?callbacks.FocusFn = null,
    ctx: ?*anyopaque = null,
    focused: bool = false,
    disabled: bool = false,
    invalid: bool = false,
    rect_out: ?*[4]f32 = null,
};

const InputSpec = struct {
    theme: *const Theme,
    value: []const u8,
    placeholder: []const u8,
    size: Size,
    w: InputWire,
    fn opts(self: *const InputSpec) input_kit.InputOptions {
        return .{
            .value = self.value,
            .placeholder = self.placeholder,
            .size = self.size,
            .focused = self.w.focused,
            .disabled = self.w.disabled,
            .invalid = self.w.invalid,
            .theme = self.theme,
            .paint = self.w.paint,
            .on_focus = self.w.on_focus,
            .ctx = self.w.ctx,
        };
    }
    fn measure(b: *RenderBuilder, ctx: *anyopaque) SizeF {
        _ = b;
        const self: *InputSpec = @ptrCast(@alignCast(ctx));
        // 0 width: fills the parent via cross-stretch; must not inflate the parent's
        // intrinsic width or it forces a wrap. Height comes from the size.
        return SizeF.init(0, input_kit.height_for(self.size));
    }
    fn draw(b: *RenderBuilder, ctx: *anyopaque, r: BoundsF) RenderError!void {
        const self: *InputSpec = @ptrCast(@alignCast(ctx));
        std.debug.assert(r.size.width >= 0);
        if (r.size.width <= 0) return; // unsized parent: render asserts w>0
        _ = try input_kit.render(b, r.origin.x, r.origin.y, r.size.width, self.opts());
        if (self.w.focused) if (self.w.rect_out) |ro| {
            ro.* = .{ r.origin.x, r.origin.y, r.size.width, r.size.height };
        };
    }
};

pub fn input(
    a: A,
    theme: *const Theme,
    value: []const u8,
    placeholder: []const u8,
    size: Size,
    w: InputWire,
) *Node {
    const spec = a.create(InputSpec) catch @panic("node arena oom");
    spec.* = .{ .theme = theme, .value = value, .placeholder = placeholder, .size = size, .w = w };
    return node.leaf(a, InputSpec.measure, InputSpec.draw, spec);
}

// Click-to-edit text. Reuses InputWire (disabled/invalid unused): idle is a plain
// label, focused is an input box reporting its rect via rect_out for the native
// overlay, like input.
const EditableSpec = struct {
    theme: *const Theme,
    value: []const u8,
    placeholder: []const u8,
    w: InputWire,
    fn opts(self: *const EditableSpec) editable_kit.EditableOptions {
        return .{
            .value = self.value,
            .placeholder = self.placeholder,
            .focused = self.w.focused,
            .theme = self.theme,
            .paint = self.w.paint,
            .on_focus = self.w.on_focus,
            .ctx = self.w.ctx,
        };
    }
    fn measure(b: *RenderBuilder, ctx: *anyopaque) SizeF {
        _ = b;
        _ = ctx;
        return SizeF.init(0, editable_kit.height_for());
    }
    fn draw(b: *RenderBuilder, ctx: *anyopaque, r: BoundsF) RenderError!void {
        const self: *EditableSpec = @ptrCast(@alignCast(ctx));
        std.debug.assert(r.size.width >= 0);
        if (r.size.width <= 0) return;
        _ = try editable_kit.render(b, r.origin.x, r.origin.y, r.size.width, self.opts());
        if (self.w.focused) if (self.w.rect_out) |ro| {
            ro.* = .{ r.origin.x, r.origin.y, r.size.width, r.size.height };
        };
    }
};

pub fn editable_text(
    a: A,
    theme: *const Theme,
    value: []const u8,
    placeholder: []const u8,
    w: InputWire,
) *Node {
    const spec = a.create(EditableSpec) catch @panic("node arena oom");
    spec.* = .{ .theme = theme, .value = value, .placeholder = placeholder, .w = w };
    return node.leaf(a, EditableSpec.measure, EditableSpec.draw, spec);
}

// The caller owns the TextAreaState (cross-frame) + its backing buffer; the kit
// manages its own internal scroll, caret, and key draining.
pub const Ta = struct {
    // The facade fills this; a direct kit_nodes caller must set it.
    paint: ?*custom_paint.PaintContext = null,
    spans: []const textarea_kit.TextSpan = &.{},
    height: f32 = 132,
    read_only: bool = false,
    wrap: bool = true,
    bordered: bool = true,
    font_family: []const u8 = "SF Mono",
    font_size: f32 = 13,
    on_focus: ?callbacks.FocusFn = null,
    ctx: ?*anyopaque = null,
};

const TextareaSpec = struct {
    theme: *const Theme,
    state: *textarea_kit.TextAreaState,
    o: Ta,
    fn opts(self: *const TextareaSpec) textarea_kit.TextAreaOptions {
        return .{
            .state = self.state,
            .spans = self.o.spans,
            .theme = self.theme,
            .paint = self.o.paint.?, // the facade always sets it before draw
            .read_only = self.o.read_only,
            .wrap = self.o.wrap,
            .bordered = self.o.bordered,
            .font_family = self.o.font_family,
            .font_size = self.o.font_size,
            .on_focus = self.o.on_focus,
            .ctx = self.o.ctx,
        };
    }
    fn measure(b: *RenderBuilder, ctx: *anyopaque) SizeF {
        _ = b;
        const self: *TextareaSpec = @ptrCast(@alignCast(ctx));
        return SizeF.init(0, self.o.height);
    }
    fn draw(b: *RenderBuilder, ctx: *anyopaque, r: BoundsF) RenderError!void {
        const self: *TextareaSpec = @ptrCast(@alignCast(ctx));
        if (r.size.width <= 0) return;
        const pc = self.o.paint orelse return; // the facade always sets it
        // Keep the loop ticking so the caret blinks between keystrokes.
        if (self.state.focused) pc.animating = true;
        _ = try textarea_kit.render(
            b,
            r.origin.x,
            r.origin.y,
            r.size.width,
            self.o.height,
            self.opts(),
        );
    }
};

pub fn textarea(a: A, theme: *const Theme, state: *textarea_kit.TextAreaState, o: Ta) *Node {
    const spec = a.create(TextareaSpec) catch @panic("node arena oom");
    spec.* = .{ .theme = theme, .state = state, .o = o };
    return node.leaf(a, TextareaSpec.measure, TextareaSpec.draw, spec);
}

pub const AlertOpt = struct {
    description: []const u8 = "",
    variant: alert_kit.AlertVariant = .default,
    icon: ?icon_render.Icon = .info,
};

const AlertSpec = struct {
    theme: *const Theme,
    title: []const u8,
    o: AlertOpt,
    fn opts(self: *const AlertSpec) alert_kit.AlertOptions {
        return .{
            .title = self.title,
            .description = self.o.description,
            .variant = self.o.variant,
            .icon = self.o.icon,
            .theme = self.theme,
        };
    }
    fn measure(b: *RenderBuilder, ctx: *anyopaque) SizeF {
        const self: *AlertSpec = @ptrCast(@alignCast(ctx));
        return SizeF.init(0, alert_kit.measure(b, .{}, self.opts()).height);
    }
    fn draw(b: *RenderBuilder, ctx: *anyopaque, r: BoundsF) RenderError!void {
        const self: *AlertSpec = @ptrCast(@alignCast(ctx));
        if (r.size.width <= 0) return;
        _ = try alert_kit.render(b, r.origin.x, r.origin.y, r.size.width, self.opts());
    }
};

pub fn alert(a: A, theme: *const Theme, title: []const u8, o: AlertOpt) *Node {
    const spec = a.create(AlertSpec) catch @panic("node arena oom");
    spec.* = .{ .theme = theme, .title = title, .o = o };
    return node.leaf(a, AlertSpec.measure, AlertSpec.draw, spec);
}

pub const Tabs = struct {
    selected: usize = 0,
    height: f32 = 36,
    paint: ?*custom_paint.PaintContext = null,
    on_select: ?callbacks.SelectFn = null,
    ctx: ?*anyopaque = null,
};

const TabsSpec = struct {
    theme: *const Theme,
    labels: []const []const u8,
    state: *tabs_kit.TabsState,
    o: Tabs,
    fn opts(self: *const TabsSpec) tabs_kit.TabsOptions {
        return .{
            .tabs = self.labels,
            .selected = self.o.selected,
            .height = self.o.height,
            .theme = self.theme,
            .paint = self.o.paint,
            .on_select = self.o.on_select,
            .ctx = self.o.ctx,
        };
    }
    fn measure(b: *RenderBuilder, ctx: *anyopaque) SizeF {
        _ = b;
        const self: *TabsSpec = @ptrCast(@alignCast(ctx));
        return SizeF.init(0, self.o.height);
    }
    fn draw(b: *RenderBuilder, ctx: *anyopaque, r: BoundsF) RenderError!void {
        const self: *TabsSpec = @ptrCast(@alignCast(ctx));
        if (r.size.width <= 0) return;
        _ = try tabs_kit.render(b, r.origin.x, r.origin.y, r.size.width, self.state, self.opts());
    }
};

pub fn tabs(
    a: A,
    theme: *const Theme,
    labels: []const []const u8,
    state: *tabs_kit.TabsState,
    o: Tabs,
) *Node {
    const spec = a.create(TabsSpec) catch @panic("node arena oom");
    spec.* = .{ .theme = theme, .labels = labels, .state = state, .o = o };
    return node.leaf(a, TabsSpec.measure, TabsSpec.draw, spec);
}

pub const BottomBar = struct {
    active: usize = 0,
    style: bottom_bar_kit.Style = .standard,
    indicator: bool = true,
    safe_bottom: f32 = 0,
    surface: ?bottom_bar_kit.Rgba = null,
    active_color: ?bottom_bar_kit.Rgba = null,
    inactive_color: ?bottom_bar_kit.Rgba = null,
    indicator_color: ?bottom_bar_kit.Rgba = null,
    paint: ?*custom_paint.PaintContext = null,
    on_select: ?callbacks.SelectFn = null,
    ctx: ?*anyopaque = null,
};

const BottomBarSpec = struct {
    theme: *const Theme,
    items: []const bottom_bar_kit.Item,
    state: *bottom_bar_kit.State,
    o: BottomBar,
    fn opts(self: *const BottomBarSpec) bottom_bar_kit.Options {
        return .{
            .items = self.items,
            .active = self.o.active,
            .style = self.o.style,
            .indicator = self.o.indicator,
            .safe_bottom = self.o.safe_bottom,
            .surface = self.o.surface,
            .active_color = self.o.active_color,
            .inactive_color = self.o.inactive_color,
            .indicator_color = self.o.indicator_color,
            .theme = self.theme,
            .paint = self.o.paint,
            .on_select = self.o.on_select,
            .ctx = self.o.ctx,
        };
    }
    fn measure(b: *RenderBuilder, ctx: *anyopaque) SizeF {
        _ = b;
        const self: *BottomBarSpec = @ptrCast(@alignCast(ctx));
        return SizeF.init(0, bottom_bar_kit.height(self.o.style));
    }
    fn draw(b: *RenderBuilder, ctx: *anyopaque, r: BoundsF) RenderError!void {
        const self: *BottomBarSpec = @ptrCast(@alignCast(ctx));
        if (r.size.width <= 0) return;
        const r0 = r.origin;
        _ = try bottom_bar_kit.render(b, r0.x, r0.y, r.size.width, self.state, self.opts());
    }
};

pub fn bottom_bar(
    a: A,
    theme: *const Theme,
    items: []const bottom_bar_kit.Item,
    state: *bottom_bar_kit.State,
    o: BottomBar,
) *Node {
    const spec = a.create(BottomBarSpec) catch @panic("node arena oom");
    spec.* = .{ .theme = theme, .items = items, .state = state, .o = o };
    return node.leaf(a, BottomBarSpec.measure, BottomBarSpec.draw, spec);
}

pub const TopBarStyle = top_bar_kit.Style;

pub const TopBar = struct {
    style: top_bar_kit.Style = .inline_,
    scroll: ?*top_bar_kit.ScrollState = null,
    frost: bool = true,
    search: ?[]const u8 = null,
    on_back: ?callbacks.ClickFn = null,
    on_action: ?callbacks.ClickFn = null,
    action_icon: ?top_bar_kit.Icon = null,
    ctx: ?*anyopaque = null,
    paint: ?*custom_paint.PaintContext = null,
};

const TopBarSpec = struct {
    theme: *const Theme,
    title: []const u8,
    o: TopBar,
    fn measure(b: *RenderBuilder, ctx: *anyopaque) SizeF {
        _ = b;
        _ = ctx;
        return SizeF.init(0, top_bar_kit.height());
    }
    fn draw(b: *RenderBuilder, ctx: *anyopaque, r: BoundsF) RenderError!void {
        const self: *TopBarSpec = @ptrCast(@alignCast(ctx));
        if (r.size.width <= 0) return;
        _ = try top_bar_kit.render(b, r.origin.x, r.origin.y, r.size.width, .{
            .title = self.title,
            .style = self.o.style,
            .scroll = self.o.scroll,
            .frost = self.o.frost,
            .search = self.o.search,
            .on_back = self.o.on_back,
            .on_action = self.o.on_action,
            .action_icon = self.o.action_icon,
            .ctx = self.o.ctx,
            .theme = self.theme,
            .paint = self.o.paint,
        });
    }
};

pub fn top_bar(a: A, theme: *const Theme, title: []const u8, o: TopBar) *Node {
    const spec = a.create(TopBarSpec) catch @panic("node arena oom");
    spec.* = .{ .theme = theme, .title = title, .o = o };
    return node.leaf(a, TopBarSpec.measure, TopBarSpec.draw, spec);
}

pub const ToggleGrp = struct {
    variant: toggle_group_kit.ToggleVariant = .default,
    size: Size = .default,
    connected: bool = false,
    paint: ?*custom_paint.PaintContext = null,
};

const ToggleGroupSpec = struct {
    theme: *const Theme,
    items: []const toggle_group_kit.ToggleGroupItem,
    o: ToggleGrp,
    fn opts(self: *const ToggleGroupSpec) toggle_group_kit.ToggleGroupOptions {
        return .{
            .items = self.items,
            .variant = self.o.variant,
            .size = self.o.size,
            .connected = self.o.connected,
            .theme = self.theme,
            .paint = self.o.paint,
        };
    }
    fn measure(b: *RenderBuilder, ctx: *anyopaque) SizeF {
        const self: *ToggleGroupSpec = @ptrCast(@alignCast(ctx));
        return toggle_group_kit.measure(b, .{}, self.opts());
    }
    fn draw(b: *RenderBuilder, ctx: *anyopaque, r: BoundsF) RenderError!void {
        const self: *ToggleGroupSpec = @ptrCast(@alignCast(ctx));
        if (r.size.width <= 0) return;
        _ = try toggle_group_kit.render(b, r.origin.x, r.origin.y, self.opts());
    }
};

pub fn toggle_group(
    a: A,
    theme: *const Theme,
    items: []const toggle_group_kit.ToggleGroupItem,
    o: ToggleGrp,
) *Node {
    // Copy into the arena: draw runs after build returns, so a caller's stack
    // literal would dangle.
    const copy = a.dupe(toggle_group_kit.ToggleGroupItem, items) catch @panic("node arena oom");
    const spec = a.create(ToggleGroupSpec) catch @panic("node arena oom");
    spec.* = .{ .theme = theme, .items = copy, .o = o };
    return node.leaf(a, ToggleGroupSpec.measure, ToggleGroupSpec.draw, spec);
}

// The caller owns the SliderState (geometry snapshot for the drag thunk) + the
// values slice; on_change(ctx, index, value) reports a moved thumb and the caller
// stores values[index] = value.
pub const Slider = struct {
    paint: ?*custom_paint.PaintContext = null,
    step: f32 = 0,
    disabled: bool = false,
    height: f32 = 22,
    on_change: ?slider_kit.ChangeAtFn = null,
    ctx: ?*anyopaque = null,
};

const SliderSpec = struct {
    theme: *const Theme,
    values: []const f32,
    state: *slider_kit.SliderState,
    o: Slider,
    fn opts(self: *const SliderSpec) slider_kit.SliderOptions {
        return .{
            .values = self.values,
            .step = self.o.step,
            .disabled = self.o.disabled,
            .theme = self.theme,
            .paint = self.o.paint,
            .on_change = self.o.on_change,
            .ctx = self.o.ctx,
        };
    }
    fn measure(b: *RenderBuilder, ctx: *anyopaque) SizeF {
        _ = b;
        const self: *SliderSpec = @ptrCast(@alignCast(ctx));
        return SizeF.init(0, self.o.height);
    }
    fn draw(b: *RenderBuilder, ctx: *anyopaque, r: BoundsF) RenderError!void {
        const self: *SliderSpec = @ptrCast(@alignCast(ctx));
        if (r.size.width <= 0) return;
        // centre the thumb band within the (possibly taller) row
        const ty = r.origin.y + (r.size.height - slider_kit.THUMB) / 2;
        try slider_kit.render(b, r.origin.x, ty, r.size.width, self.state, self.opts());
    }
};

pub fn slider(
    a: A,
    theme: *const Theme,
    values: []const f32,
    state: *slider_kit.SliderState,
    o: Slider,
) *Node {
    const spec = a.create(SliderSpec) catch @panic("node arena oom");
    spec.* = .{ .theme = theme, .values = values, .state = state, .o = o };
    return node.leaf(a, SliderSpec.measure, SliderSpec.draw, spec);
}

// The clickable trigger box; the dropdown panel is select.content, drawn by the
// consumer in its overlay layer at the rect this writes to rect_out.
pub const Sel = struct {
    open: bool = false,
    placeholder: bool = false,
    disabled: bool = false,
    invalid: bool = false,
    paint: ?*custom_paint.PaintContext = null,
    on_click: ?callbacks.ClickFn = null,
    ctx: ?*anyopaque = null,
    rect_out: ?*[4]f32 = null,
};

const SelectSpec = struct {
    theme: *const Theme,
    label: []const u8,
    o: Sel,
    fn opts(self: *const SelectSpec) select_kit.SelectOptions {
        return .{
            .label = self.label,
            .open = self.o.open,
            .placeholder = self.o.placeholder,
            .disabled = self.o.disabled,
            .invalid = self.o.invalid,
            .theme = self.theme,
            .paint = self.o.paint,
            .on_click = self.o.on_click,
            .ctx = self.o.ctx,
        };
    }
    fn measure(b: *RenderBuilder, ctx: *anyopaque) SizeF {
        _ = b;
        _ = ctx;
        return SizeF.init(0, select_kit.H);
    }
    fn draw(b: *RenderBuilder, ctx: *anyopaque, r: BoundsF) RenderError!void {
        const self: *SelectSpec = @ptrCast(@alignCast(ctx));
        std.debug.assert(r.size.width >= 0);
        if (r.size.width <= 0) return;
        _ = try select_kit.render(b, r.origin.x, r.origin.y, r.size.width, self.opts());
        if (self.o.rect_out) |ro| {
            ro.* = .{ r.origin.x, r.origin.y, r.size.width, r.size.height };
        }
    }
};

pub fn select(a: A, theme: *const Theme, label: []const u8, o: Sel) *Node {
    const spec = a.create(SelectSpec) catch @panic("node arena oom");
    spec.* = .{ .theme = theme, .label = label, .o = o };
    return node.leaf(a, SelectSpec.measure, SelectSpec.draw, spec);
}

// The open dropdown panel for a select, drawn in the overlay region. Anchored to
// the trigger's laid-out rect (its Sel.rect_out), not modal: it masks the body
// glyphs behind the panel instead of frosting, and rings the panel with dismiss
// hitboxes so an outside click closes while rows + the search field stay live.
pub const SelectOverlay = struct {
    groups: []const select_kit.SelectGroup,
    selected_id: []const u8 = "",
    state: *select_kit.SelectState,
    trigger: *const [4]f32, // read at draw, after the trigger wrote it this frame
    position: select_kit.SelectPosition = .item_aligned,
    scroll: *f32, // caller-owned offset; the wheel re-clamps it each frame
    max_height: f32 = 280,
    search: bool = false,
    search_field: ?*TextField = null, // non-null only for the combobox variant
    on_select: ?callbacks.SelectIdFn = null,
    on_scroll: ?select_kit.ScrollDeltaFn = null,
    on_dismiss: ?callbacks.ClickFn = null,
    paint: ?*custom_paint.PaintContext = null,
    ctx: ?*anyopaque = null,
};

// Distinct from the form-field ids (1-4) so the singleton editor re-seeds on open.
const SELECT_SEARCH_ID: u32 = 7000;

// A panel quad can't mask text (the renderer flushes glyphs over every quad), so
// zero the clip on body glyphs sitting behind the panel rect r.
fn mask_behind(range: []primitives.MonochromeSprite, r: [4]f32) void {
    std.debug.assert(r[2] >= 0);
    std.debug.assert(r[3] >= 0);
    for (range) |*s| {
        const sx = s.position[0];
        const sy = s.position[1];
        const hit = sx + s.size[0] > r[0] and sx < r[0] + r[2] and
            sy + s.size[1] > r[1] and sy < r[1] + r[3];
        if (hit) s.clip_bounds = .{ 0, 0, 0, 0 };
    }
}

// Dismiss hitboxes AROUND the panel rect r, not over it, so clicks inside (rows,
// the search field) stay live while outside clicks close. Registered after the
// panel's own hitboxes, which win in their rect (hit-test walks newest-first).
fn dismiss_around(
    pc: *custom_paint.PaintContext,
    w: f32,
    h: f32,
    r: [4]f32,
    cb: callbacks.ClickFn,
    ctx: ?*anyopaque,
) !void {
    std.debug.assert(w >= 0);
    std.debug.assert(h >= 0);
    const add = struct {
        fn one(
            p: *custom_paint.PaintContext,
            x: f32,
            y: f32,
            bw: f32,
            bh: f32,
            c: callbacks.ClickFn,
            cx: ?*anyopaque,
        ) !void {
            std.debug.assert(bw >= 0); // callers @max the side that can go negative
            std.debug.assert(bh >= 0);
            try p.add_hitbox(.{ .x = x, .y = y, .w = bw, .h = bh, .on_click = c, .ctx = cx });
        }
    };
    try add.one(pc, 0, 0, w, @max(0, r[1]), cb, ctx);
    try add.one(pc, 0, r[1] + r[3], w, @max(0, h - r[1] - r[3]), cb, ctx);
    try add.one(pc, 0, r[1], @max(0, r[0]), r[3], cb, ctx);
    try add.one(pc, r[0] + r[2], r[1], @max(0, w - r[0] - r[2]), r[3], cb, ctx);
}

const SelectOverlaySpec = struct {
    theme: *const Theme,
    o: SelectOverlay,
    fn measure(b: *RenderBuilder, ctx: *anyopaque) SizeF {
        _ = b;
        _ = ctx;
        return SizeF.init(0, 0); // fills the overlay; the panel anchors in draw
    }
    fn draw(b: *RenderBuilder, ctx: *anyopaque, r: BoundsF) RenderError!void {
        const self: *SelectOverlaySpec = @ptrCast(@alignCast(ctx));
        const o = self.o;
        const pc = o.paint orelse return;
        const theme = self.theme;
        std.debug.assert(o.max_height > 0);
        std.debug.assert(o.groups.len <= select_kit.MAX_GROUPS);
        std.debug.assert(r.size.width >= 0);
        const search_h: f32 = if (o.search) select_kit.SEARCH_H else 0;
        const max = @max(0, select_kit.measure_height(o.groups) - (o.max_height - search_h));
        o.scroll.* = std.math.clamp(o.scroll.* - pc.wheel_dy, 0, max);

        const tg = o.trigger.*;
        const query = if (o.search_field) |fld| fld.slice() else "";
        const body_end = b.sprites.items.len;
        const panel = try select_kit.content(b, o.state, .{
            .groups = o.groups,
            .selected_id = o.selected_id,
            .theme = theme,
            .paint = pc,
            .on_select = o.on_select,
            .ctx = o.ctx,
            .position = o.position,
            .trigger_x = tg[0],
            .trigger_y = tg[1],
            .trigger_w = tg[2],
            .max_height = o.max_height,
            .scroll = o.scroll.*,
            .on_scroll = o.on_scroll,
            .search = o.search,
            .query = query,
        });
        if (o.search) if (o.search_field) |fld| {
            const sr = select_kit.search_rect(panel);
            const shown = pc.show_text_field(
                sr[0],
                sr[1],
                sr[2],
                sr[3],
                fld.slice(),
                theme.font_size,
                theme.foreground,
                SELECT_SEARCH_ID,
            );
            if (shown) {
                pc.animating = true; // poll the native field while the combobox is open
                var tmp: [256]u8 = undefined;
                fld.set(pc.text_field_value(&tmp));
                if (!custom_shell.text_field_native_paint) {
                    try draw_field_overlay(
                        b,
                        pc,
                        sr[0],
                        sr[1],
                        sr[2],
                        sr[3],
                        fld.slice(),
                        theme,
                    );
                }
            }
        };
        if (o.on_dismiss) |cb|
            try dismiss_around(pc, r.size.width, r.size.height, panel, cb, o.ctx);
        mask_behind(b.sprites.items[0..body_end], panel);
    }
};

pub fn select_overlay(a: A, theme: *const Theme, o: SelectOverlay) *Node {
    const spec = a.create(SelectOverlaySpec) catch @panic("node arena oom");
    spec.* = .{ .theme = theme, .o = o };
    return node.leaf(a, SelectOverlaySpec.measure, SelectOverlaySpec.draw, spec);
}

// Charts are immediate-mode (draw at x/y/w/h); these leaves give them a fixed
// height and a flex-filled width so they sit in a col/row/grid like any node.
// The caller owns the kit options (theme + paint + data slices).

const LineChartSpec = struct {
    o: chart_kit.LineChartOptions,
    height: f32,
    fn measure(b: *RenderBuilder, ctx: *anyopaque) SizeF {
        _ = b;
        const self: *LineChartSpec = @ptrCast(@alignCast(ctx));
        return SizeF.init(0, self.height);
    }
    fn draw(b: *RenderBuilder, ctx: *anyopaque, r: BoundsF) RenderError!void {
        const self: *LineChartSpec = @ptrCast(@alignCast(ctx));
        if (r.size.width <= 0) return;
        try chart_kit.line_chart(b, r.origin.x, r.origin.y, r.size.width, self.height, self.o);
    }
};

pub fn line_chart(a: A, o: chart_kit.LineChartOptions, height: f32) *Node {
    const spec = a.create(LineChartSpec) catch @panic("node arena oom");
    spec.* = .{ .o = o, .height = height };
    return node.leaf(a, LineChartSpec.measure, LineChartSpec.draw, spec);
}

const BarChartSpec = struct {
    o: chart_kit.BarChartOptions,
    height: f32,
    fn measure(b: *RenderBuilder, ctx: *anyopaque) SizeF {
        _ = b;
        const self: *BarChartSpec = @ptrCast(@alignCast(ctx));
        return SizeF.init(0, self.height);
    }
    fn draw(b: *RenderBuilder, ctx: *anyopaque, r: BoundsF) RenderError!void {
        const self: *BarChartSpec = @ptrCast(@alignCast(ctx));
        if (r.size.width <= 0) return;
        try chart_kit.bar_chart(b, r.origin.x, r.origin.y, r.size.width, self.height, self.o);
    }
};

pub fn bar_chart(a: A, o: chart_kit.BarChartOptions, height: f32) *Node {
    const spec = a.create(BarChartSpec) catch @panic("node arena oom");
    spec.* = .{ .o = o, .height = height };
    return node.leaf(a, BarChartSpec.measure, BarChartSpec.draw, spec);
}

const DonutSpec = struct {
    o: chart_kit.DonutChartOptions,
    height: f32,
    fn measure(b: *RenderBuilder, ctx: *anyopaque) SizeF {
        _ = b;
        const self: *DonutSpec = @ptrCast(@alignCast(ctx));
        return SizeF.init(0, self.height);
    }
    fn draw(b: *RenderBuilder, ctx: *anyopaque, r: BoundsF) RenderError!void {
        const self: *DonutSpec = @ptrCast(@alignCast(ctx));
        // Fits the smaller dimension and centres: a wide cell leaves side gaps, a
        // narrow one shrinks below height. Neither is a layout bug.
        const size = @min(r.size.width, r.size.height);
        if (size <= 0) return;
        const cx = r.origin.x + r.size.width / 2;
        const cy = r.origin.y + r.size.height / 2;
        try chart_kit.donut(b, cx, cy, size, self.o);
    }
};

pub fn donut(a: A, o: chart_kit.DonutChartOptions, height: f32) *Node {
    const spec = a.create(DonutSpec) catch @panic("node arena oom");
    spec.* = .{ .o = o, .height = height };
    return node.leaf(a, DonutSpec.measure, DonutSpec.draw, spec);
}

// An overlay dialog. The leaf fills the overlay region; draw frosts everything
// already emitted (blur_modal), tints a scrim, centers the kit.dialog card, and
// adds an outside-dismiss hitbox. ctx is handed to every action + the dismiss.
pub const DialogAction = struct {
    label: []const u8,
    variant: Variant = .default,
    on_click: ?callbacks.ClickFn = null,
};

pub const Dialog = struct {
    title: []const u8,
    description: ?[]const u8 = null,
    actions: []const DialogAction = &.{},
    width: f32 = 420,
    height: f32 = 188,
    on_dismiss: ?callbacks.ClickFn = null,
    paint: ?*custom_paint.PaintContext = null,
    ctx: ?*anyopaque = null,
};

const MAX_DIALOG_ACTIONS = 4;

fn dialog_absorb(_: ?*anyopaque) void {}

const DialogSpec = struct {
    theme: *const Theme,
    o: Dialog,
    fn measure(b: *RenderBuilder, ctx: *anyopaque) SizeF {
        _ = b;
        _ = ctx;
        return SizeF.init(0, 0); // fills the overlay; the card centers in draw
    }
    fn draw(b: *RenderBuilder, ctx: *anyopaque, r: BoundsF) RenderError!void {
        const self: *DialogSpec = @ptrCast(@alignCast(ctx));
        const pc = self.o.paint orelse return;
        std.debug.assert(self.o.width > 0);
        std.debug.assert(self.o.height > 0);
        // Frost everything drawn so far (body + titlebar); the renderer keeps the
        // band crisp and draws this layer crisp on top.
        pc.blur_modal = true;
        pc.backdrop_prims = @intCast(b.prims.items.len);
        pc.backdrop_sprites = @intCast(b.sprites.items.len);
        pc.backdrop_color = @intCast(b.color_sprites.items.len);
        var tint = primitives.Quad.init(r.origin.x, r.origin.y, r.size.width, r.size.height);
        _ = tint.set_background(.{ .r = 0, .g = 0, .b = 0, .a = 0.4 });
        try b.append_quad(tint);
        if (self.o.on_dismiss) |cb| try pc.add_hitbox(.{
            .x = r.origin.x,
            .y = r.origin.y,
            .w = r.size.width,
            .h = r.size.height,
            .on_click = cb,
            .ctx = self.o.ctx,
        });
        const cx = r.origin.x + (r.size.width - self.o.width) / 2;
        const cy = r.origin.y + (r.size.height - self.o.height) / 2;
        // Absorb clicks on the card so they don't reach the dismiss behind it.
        try pc.add_hitbox(.{
            .x = cx,
            .y = cy,
            .w = self.o.width,
            .h = self.o.height,
            .on_click = dialog_absorb,
            .ctx = self.o.ctx,
        });
        var acts: [MAX_DIALOG_ACTIONS]dialog_kit.DialogAction = undefined;
        std.debug.assert(self.o.actions.len <= acts.len);
        const n = @min(self.o.actions.len, acts.len);
        for (self.o.actions[0..n], 0..) |act, i| acts[i] = .{
            .label = act.label,
            .variant = act.variant,
            .on_click = act.on_click,
            .ctx = self.o.ctx,
        };
        _ = try dialog_kit.render(b, cx, cy, .{
            .title = self.o.title,
            .description = self.o.description,
            .actions = acts[0..n],
            .width = self.o.width,
            .height = self.o.height,
            .theme = self.theme,
            .paint = pc,
        });
    }
};

// A zero-size leaf that lifts everything drawn AFTER it into the modal top layer:
// it records the current backdrop counts (so the renderer frosts the body+scrim
// drawn before it and draws the following content crisp on top) — the same
// mechanism kit.dialog uses internally, exposed so a facade-composed modal (with
// arbitrary children) can render above the body instead of losing the z-order to
// deeply-nested body nodes. Place it as the first child of the modal's root, after
// the scrim; the card follows and renders on top.
const ModalBackdropSpec = struct {
    paint: ?*custom_paint.PaintContext = null,
    fn measure(b: *RenderBuilder, ctx: *anyopaque) SizeF {
        _ = b;
        _ = ctx;
        return SizeF.init(0, 0);
    }
    fn draw(b: *RenderBuilder, ctx: *anyopaque, r: BoundsF) RenderError!void {
        _ = r;
        const self: *ModalBackdropSpec = @ptrCast(@alignCast(ctx));
        const pc = self.paint orelse return;
        pc.blur_modal = true;
        pc.backdrop_prims = @intCast(b.prims.items.len);
        pc.backdrop_sprites = @intCast(b.sprites.items.len);
        pc.backdrop_color = @intCast(b.color_sprites.items.len);
    }
};

pub fn modal_backdrop(a: A, pc: ?*custom_paint.PaintContext) *Node {
    const spec = a.create(ModalBackdropSpec) catch @panic("node arena oom");
    spec.* = .{ .paint = pc };
    return node.leaf(a, ModalBackdropSpec.measure, ModalBackdropSpec.draw, spec);
}

pub fn dialog(a: A, theme: *const Theme, o: Dialog) *Node {
    std.debug.assert(o.actions.len <= MAX_DIALOG_ACTIONS);
    // Copy actions into the arena: a `&.{...}` struct-array literal is a stack
    // temporary that dies when the caller's view() returns, but draw runs later.
    var oo = o;
    oo.actions = a.dupe(DialogAction, o.actions) catch @panic("node arena oom");
    const spec = a.create(DialogSpec) catch @panic("node arena oom");
    spec.* = .{ .theme = theme, .o = oo };
    return node.leaf(a, DialogSpec.measure, DialogSpec.draw, spec);
}

// The nav sidebar (disclosure tree, scroll, resize handle, mini-collapse). The
// caller owns the SidebarState + the scroll position (cross-frame); the leaf
// fills its column slot and consumes the wheel while hovered.
pub const Sidebar = struct {
    items: []const types.SidebarEntry,
    state: *sidebar_kit.SidebarState,
    scroll: *f32,
    width: f32 = 260,
    collapsed: bool = false,
    on_select: ?callbacks.SelectIdFn = null,
    on_disclose: ?callbacks.DiscloseFn = null,
    on_resize: ?callbacks.DragFn = null,
    paint: ?*custom_paint.PaintContext = null,
    ctx: ?*anyopaque = null,
};

const SidebarSpec = struct {
    theme: *const Theme,
    o: Sidebar,
    fn opts(self: *const SidebarSpec) sidebar_kit.SidebarOptions {
        return .{
            .items = self.o.items,
            .theme = self.theme,
            .paint = self.o.paint,
            .on_select = self.o.on_select,
            .on_disclose = self.o.on_disclose,
            .on_resize = self.o.on_resize,
            .ctx = self.o.ctx,
            .collapsed = self.o.collapsed,
            .scroll_y = self.o.scroll.*,
        };
    }
    fn measure(b: *RenderBuilder, ctx: *anyopaque) SizeF {
        _ = b;
        const self: *SidebarSpec = @ptrCast(@alignCast(ctx));
        const w = if (self.o.collapsed) sidebar_kit.COLLAPSED_W else self.o.width;
        return SizeF.init(w, 0); // width pins; height fills the row's cross axis
    }
    fn draw(b: *RenderBuilder, ctx: *anyopaque, r: BoundsF) RenderError!void {
        const self: *SidebarSpec = @ptrCast(@alignCast(ctx));
        const w = r.size.width;
        const h = r.size.height;
        if (self.o.paint) |pc| if (pc.is_hovered(r.origin.x, r.origin.y, w, h)) {
            const max = sidebar_kit.max_scroll(self.opts(), h);
            self.o.scroll.* = std.math.clamp(self.o.scroll.* - pc.wheel_dy, 0, max);
        };
        _ = try sidebar_kit.render(b, r.origin.x, r.origin.y, w, h, self.o.state, self.opts());
    }
};

// A live single-line text field: the caller owns the buffer; when focused the
// node drives the native editor over its rect and polls the typed value back.
pub const TextField = struct {
    buf: [256]u8 = undefined,
    len: usize = 0,

    pub fn slice(self: *const TextField) []const u8 {
        return self.buf[0..self.len];
    }
    pub fn set(self: *TextField, text: []const u8) void {
        std.debug.assert(text.len <= self.buf.len);
        const n = @min(text.len, self.buf.len);
        @memcpy(self.buf[0..n], text[0..n]);
        self.len = n;
    }
};

// Native editor height (the NSTextField overlaid on a focused input).
const EDITOR_H: f32 = 18;

// Drive the shared native editor over a focused field's rect and poll the value.
fn edit_native(
    b: *RenderBuilder,
    pc: *custom_paint.PaintContext,
    r: BoundsF,
    field: *TextField,
    theme: *const Theme,
    id: u32,
) RenderError!void {
    std.debug.assert(id != 0); // 0 is the native editor's inactive sentinel
    const ex = r.origin.x + input_kit.PAD; // editor text aligns with the box text
    const ey = r.origin.y + (r.size.height - EDITOR_H) / 2;
    const ew = @max(0, r.size.width - input_kit.PAD * 2);
    const shown = pc.show_text_field(
        ex,
        ey,
        ew,
        EDITOR_H,
        field.slice(),
        theme.font_size,
        theme.foreground,
        id,
    );
    // A background window does not own the editor, so it neither animates a caret
    // nor reads the value (that would pull the other window's text into this one).
    if (!shown) return;
    pc.animating = true;
    var tmp: [256]u8 = undefined;
    field.set(pc.text_field_value(&tmp));
    if (!custom_shell.text_field_native_paint)
        try draw_field_overlay(b, pc, ex, ey, ew, EDITOR_H, field.slice(), theme);
}

// On a backend whose editor is state-only (no native control to float), the
// overlay's pixels are drawn here, where the text tooling lives: the live
// value, the selection band, and a blinking caret, scrolled to keep the
// caret inside the box and clipped to it.
fn draw_field_overlay(
    b: *RenderBuilder,
    pc: *custom_paint.PaintContext,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    value: []const u8,
    theme: *const Theme,
) RenderError!void {
    std.debug.assert(!custom_shell.text_field_native_paint);
    // A secure field must never paint its plaintext; bullets carry the same
    // caret/selection offsets because the mask is per-codepoint.
    var mask_buf: [256 * 3]u8 = undefined;
    const shown_value = if (custom_shell.text_field_secure())
        field_mask(value, &mask_buf)
    else
        value;
    const sty = label_render.Style{ .font_size = theme.font_size, .color = theme.foreground };
    // An empty value measures zero; a reference glyph keeps the caret's
    // vertical metrics stable while the field is empty.
    const m = label_render.measure(b, if (shown_value.len == 0) "M" else shown_value, sty);
    const caret = @min(mask_offset(value, custom_shell.text_field_caret(), shown_value), shown_value.len);
    const raw_sel = custom_shell.text_field_selection();
    const sel = [2]usize{
        mask_offset(value, raw_sel[0], shown_value),
        mask_offset(value, raw_sel[1], shown_value),
    };
    const caret_x = label_render.measure(b, shown_value[0..caret], sty).width;
    const shift: f32 = if (caret_x > w) caret_x - w else 0;
    const top = label_render.centered_top(y, h, m);
    const line_h = @max(m.ascent + m.descent, theme.font_size);
    const clip: [4]f32 = .{ x, y - 2, w, h + 4 }; // caret may stand taller than glyphs

    if (sel[0] != sel[1] and sel[1] <= shown_value.len) {
        // The textarea's selection recipe, so the two editors read as one family.
        var band_color = theme_resolve.mix(theme.background, theme.ring, 0.5);
        band_color.a = 0.30;
        const ax = label_render.measure(b, shown_value[0..sel[0]], sty).width;
        const bx = label_render.measure(b, shown_value[0..sel[1]], sty).width;
        var band = primitives.Quad.init(x - shift + ax, top, bx - ax, line_h);
        _ = band.set_background(band_color).set_clip_bounds(clip);
        try b.append_quad(band);
    }

    const t0 = b.sprites.items.len;
    _ = try label_render.render(b, x - shift, top, shown_value, sty);
    for (b.sprites.items[t0..]) |*sp| {
        sp.clip_bounds = theme_resolve.clip_intersect(sp.clip_bounds, clip);
    }

    if (@mod(pc.now_s, 1.0) < 0.5) {
        var caret_q = primitives.Quad.init(x - shift + caret_x, top, 1.5, line_h);
        _ = caret_q.set_background(theme.foreground).set_clip_bounds(clip);
        try b.append_quad(caret_q);
    }
}

// One U+2022 (3 bytes) per codepoint; a 256-byte value caps the buffer.
fn field_mask(value: []const u8, buf: *[256 * 3]u8) []const u8 {
    const dot = "\u{2022}";
    const n = std.unicode.utf8CountCodepoints(value) catch value.len;
    const count = @min(n, 256);
    var i: usize = 0;
    while (i < count) : (i += 1) @memcpy(buf[i * 3 .. i * 3 + 3], dot);
    return buf[0 .. count * 3];
}

// Map a byte offset in the real value onto the shown string: identity when
// unmasked, codepoints-times-three when bullets replaced the text.
fn mask_offset(value: []const u8, at: usize, shown: []const u8) usize {
    if (shown.ptr == value.ptr) return @min(at, shown.len);
    const clamped = @min(at, value.len);
    const n = std.unicode.utf8CountCodepoints(value[0..clamped]) catch clamped;
    return @min(n * 3, shown.len);
}

pub const TextInputOpts = struct {
    placeholder: []const u8 = "",
    size: Size = .default,
    focused: bool = false,
    id: u32 = 1, // distinct per field so the singleton editor re-seeds on switch
    on_focus: ?callbacks.FocusFn = null,
    paint: ?*custom_paint.PaintContext = null,
    ctx: ?*anyopaque = null,
};

const TextInputSpec = struct {
    theme: *const Theme,
    field: *TextField,
    o: TextInputOpts,
    fn measure(b: *RenderBuilder, ctx: *anyopaque) SizeF {
        _ = b;
        const self: *TextInputSpec = @ptrCast(@alignCast(ctx));
        return SizeF.init(0, input_kit.height_for(self.o.size));
    }
    fn draw(b: *RenderBuilder, ctx: *anyopaque, r: BoundsF) RenderError!void {
        const self: *TextInputSpec = @ptrCast(@alignCast(ctx));
        if (r.size.width <= 0) return;
        _ = try input_kit.render(b, r.origin.x, r.origin.y, r.size.width, .{
            .value = self.field.slice(),
            .placeholder = self.o.placeholder,
            .size = self.o.size,
            .focused = self.o.focused,
            .theme = self.theme,
            .paint = self.o.paint,
            .on_focus = self.o.on_focus,
            .ctx = self.o.ctx,
        });
        if (self.o.focused) if (self.o.paint) |pc| {
            try edit_native(b, pc, r, self.field, self.theme, self.o.id);
        };
    }
};

pub fn text_input(a: A, theme: *const Theme, field: *TextField, o: TextInputOpts) *Node {
    const spec = a.create(TextInputSpec) catch @panic("node arena oom");
    spec.* = .{ .theme = theme, .field = field, .o = o };
    return node.leaf(a, TextInputSpec.measure, TextInputSpec.draw, spec);
}

// A click-to-edit text label: idle is a plain label, focused becomes an editable
// box driving the shared native editor. Shares TextField with text_input.
pub const EditableOpts = struct {
    placeholder: []const u8 = "",
    focused: bool = false,
    id: u32 = 1,
    on_focus: ?callbacks.FocusFn = null,
    paint: ?*custom_paint.PaintContext = null,
    ctx: ?*anyopaque = null,
};

const TextEditableSpec = struct {
    theme: *const Theme,
    field: *TextField,
    o: EditableOpts,
    fn measure(b: *RenderBuilder, ctx: *anyopaque) SizeF {
        _ = b;
        _ = ctx;
        return SizeF.init(0, editable_kit.height_for());
    }
    fn draw(b: *RenderBuilder, ctx: *anyopaque, r: BoundsF) RenderError!void {
        const self: *TextEditableSpec = @ptrCast(@alignCast(ctx));
        if (r.size.width <= 0) return;
        _ = try editable_kit.render(b, r.origin.x, r.origin.y, r.size.width, .{
            .value = self.field.slice(),
            .placeholder = self.o.placeholder,
            .focused = self.o.focused,
            .theme = self.theme,
            .paint = self.o.paint,
            .on_focus = self.o.on_focus,
            .ctx = self.o.ctx,
        });
        if (self.o.focused) if (self.o.paint) |pc| {
            try edit_native(b, pc, r, self.field, self.theme, self.o.id);
        };
    }
};

pub fn text_editable(a: A, theme: *const Theme, field: *TextField, o: EditableOpts) *Node {
    const spec = a.create(TextEditableSpec) catch @panic("node arena oom");
    spec.* = .{ .theme = theme, .field = field, .o = o };
    return node.leaf(a, TextEditableSpec.measure, TextEditableSpec.draw, spec);
}

pub fn sidebar(a: A, theme: *const Theme, o: Sidebar) *Node {
    // Dupe the top-level item list: a `&.{...}` literal is a stack temporary;
    // each entry's static `children` slice stays valid as-is.
    var oo = o;
    oo.items = a.dupe(types.SidebarEntry, o.items) catch @panic("node arena oom");
    const spec = a.create(SidebarSpec) catch @panic("node arena oom");
    spec.* = .{ .theme = theme, .o = oo };
    return node.leaf(a, SidebarSpec.measure, SidebarSpec.draw, spec);
}

// A horizontal tab strip (Postman/Insomnia style): closeable, reorderable tabs
// with an optional trailing + button. state is caller-owned and must keep a stable
// address (hitbox shims back-point into it); scroll_x is caller-owned too - the
// leaf clamps it and pans on a wheel-over.
pub const Tabbar = struct {
    tabs: []const tabbar_kit.TabItem,
    state: *tabbar_kit.TabBarState,
    scroll_x: *f32,
    active: usize = 0,
    height: f32 = 36,
    on_select: ?tabbar_kit.TabSelectFn = null,
    on_close: ?tabbar_kit.TabCloseFn = null,
    on_new: ?tabbar_kit.TabNewFn = null,
    on_move: ?tabbar_kit.TabMoveFn = null,
    on_pin: ?tabbar_kit.TabPinFn = null,
    paint: ?*custom_paint.PaintContext = null,
    ctx: ?*anyopaque = null,
};

const TabbarSpec = struct {
    theme: *const Theme,
    o: Tabbar,
    fn opts(self: *const TabbarSpec) tabbar_kit.TabBarOptions {
        return .{
            .tabs = self.o.tabs,
            .active = self.o.active,
            .theme = self.theme,
            .paint = self.o.paint,
            .on_select = self.o.on_select,
            .on_close = self.o.on_close,
            .on_new = self.o.on_new,
            .on_move = self.o.on_move,
            .on_pin = self.o.on_pin,
            .ctx = self.o.ctx,
            .height = self.o.height,
            .scroll_x = self.o.scroll_x.*,
        };
    }
    fn measure(b: *RenderBuilder, ctx: *anyopaque) SizeF {
        _ = b;
        const self: *TabbarSpec = @ptrCast(@alignCast(ctx));
        return SizeF.init(0, self.o.height); // width fills; height pins
    }
    fn draw(b: *RenderBuilder, ctx: *anyopaque, r: BoundsF) RenderError!void {
        const self: *TabbarSpec = @ptrCast(@alignCast(ctx));
        std.debug.assert(self.o.height > 0);
        std.debug.assert(self.o.tabs.len <= tabbar_kit.MAX_TABS);
        if (r.size.width <= 0) return;
        var o = self.opts();
        const max = tabbar_kit.max_scroll_x(o, r.size.width);
        if (self.o.paint) |pc| {
            if (pc.is_hovered(r.origin.x, r.origin.y, r.size.width, self.o.height)) {
                const pan = if (pc.wheel_dx != 0) pc.wheel_dx else pc.wheel_dy;
                self.o.scroll_x.* -= pan;
            }
        }
        // Clamp unconditionally so a null-paint caller's stale offset can't stick.
        self.o.scroll_x.* = std.math.clamp(self.o.scroll_x.*, 0, max);
        o.scroll_x = self.o.scroll_x.*;
        _ = try tabbar_kit.render(b, r.origin.x, r.origin.y, r.size.width, self.o.state, o);
    }
};

pub fn tabbar(a: A, theme: *const Theme, o: Tabbar) *Node {
    // Dupe the item list: a `&.{...}` / app-scratch slice may not outlive draw.
    var oo = o;
    oo.tabs = a.dupe(tabbar_kit.TabItem, o.tabs) catch @panic("node arena oom");
    const spec = a.create(TabbarSpec) catch @panic("node arena oom");
    spec.* = .{ .theme = theme, .o = oo };
    return node.leaf(a, TabbarSpec.measure, TabbarSpec.draw, spec);
}

const MENU_GAP: f32 = 6; // panel sits this far below the trigger

// The open dropdown menu, drawn in the overlay region, anchored below the trigger
// (its rect_out). The menu kit registers its own panel swallow-hitbox, so one
// full-window absorber underneath closes on an outside click (panel hitboxes are
// newer and win in their rect).
pub const MenuOverlay = struct {
    items: []const menu_kit.MenuEntry,
    state: *menu_kit.MenuState,
    trigger: *const [4]f32, // read at draw, after the trigger wrote it this frame
    view_y: f32 = 0, // body inset (content top) for edge-flip + clip
    view_h: f32 = 0, // content height; 0 disables vertical flip/clip
    on_select: ?callbacks.SelectIdFn = null,
    on_dismiss: ?callbacks.ClickFn = null,
    paint: ?*custom_paint.PaintContext = null,
    ctx: ?*anyopaque = null,
};

const MenuOverlaySpec = struct {
    theme: *const Theme,
    o: MenuOverlay,
    fn measure(b: *RenderBuilder, ctx: *anyopaque) SizeF {
        _ = b;
        _ = ctx;
        return SizeF.init(0, 0); // fills the overlay; the panel anchors in draw
    }
    fn draw(b: *RenderBuilder, ctx: *anyopaque, r: BoundsF) RenderError!void {
        const self: *MenuOverlaySpec = @ptrCast(@alignCast(ctx));
        const o = self.o;
        const pc = o.paint orelse return;
        std.debug.assert(o.items.len > 0);
        std.debug.assert(r.size.width >= 0);
        const tg = o.trigger.*;
        // Outside-click absorber first; the panel's own hitboxes are newer and win.
        if (o.on_dismiss) |cb| try pc.add_hitbox(.{
            .x = 0,
            .y = 0,
            .w = r.size.width,
            .h = r.size.height,
            .on_click = cb,
            .ctx = o.ctx,
        });
        const body_end = b.sprites.items.len;
        const mr = try menu_kit.render(b, tg[0], tg[1] + tg[3] + MENU_GAP, o.state, .{
            .items = o.items,
            .theme = self.theme,
            .paint = pc,
            .on_select = o.on_select,
            .ctx = o.ctx,
            .view_x = 0,
            .view_y = o.view_y,
            .view_w = r.size.width,
            .view_h = o.view_h,
        });
        mask_behind(b.sprites.items[0..body_end], mr);
    }
};

pub fn menu_overlay(a: A, theme: *const Theme, o: MenuOverlay) *Node {
    // Dupe the top-level entries: the page builds them on its stack each frame
    // (the .checked field reads live state). Submenu children, if any, are static.
    var oo = o;
    oo.items = a.dupe(menu_kit.MenuEntry, o.items) catch @panic("node arena oom");
    const spec = a.create(MenuOverlaySpec) catch @panic("node arena oom");
    spec.* = .{ .theme = theme, .o = oo };
    return node.leaf(a, MenuOverlaySpec.measure, MenuOverlaySpec.draw, spec);
}

// The whole Resizable demo as one leaf: a bordered card split left/right by a
// vertical divider, the right half split top/bottom by a horizontal one, a label
// centered in each region. One immediate-draw leaf is the faithful port - the
// T-junction tie-break needs sibling geometry the kit can't see on its own.
pub const ResizableSnap = struct {
    h_x: f32 = 0,
    h_w: f32 = 1,
    v_y: f32 = 0,
    v_h: f32 = 1,
};

pub const ResizableDemo = struct {
    h: *f32, // left/right split fraction (caller-owned)
    v: *f32, // top/bottom split of the right region
    snap: *ResizableSnap, // geometry the drag thunk maps a cursor point against
    height: f32 = 420,
    max_width: f32 = 640,
    on_resize_h: ?callbacks.DragFn = null,
    on_resize_v: ?callbacks.DragFn = null,
    paint: ?*custom_paint.PaintContext = null,
    ctx: ?*anyopaque = null,
};

const ResizableDemoSpec = struct {
    theme: *const Theme,
    o: ResizableDemo,
    fn measure(b: *RenderBuilder, ctx: *anyopaque) SizeF {
        _ = b;
        const self: *ResizableDemoSpec = @ptrCast(@alignCast(ctx));
        return SizeF.init(0, self.o.height); // width fills; height pins
    }
    fn rs_label(
        b: *RenderBuilder,
        theme: *const Theme,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        txt: []const u8,
    ) RenderError!void {
        std.debug.assert(w >= 0);
        std.debug.assert(h >= 0);
        const sty = label_render.Style{
            .font_size = 19,
            .weight = .semi_bold,
            .color = theme.foreground,
        };
        const m = label_render.measure(b, txt, sty);
        const lx = x + (w - m.width) / 2;
        const ly = y + (h - (m.ascent + m.descent)) / 2;
        _ = try label_render.render(b, lx, ly, txt, sty);
    }
    fn draw(b: *RenderBuilder, ctx: *anyopaque, r: BoundsF) RenderError!void {
        const self: *ResizableDemoSpec = @ptrCast(@alignCast(ctx));
        const o = self.o;
        if (r.size.width <= 0) return;
        const theme = self.theme;
        const aw = @min(r.size.width, o.max_width);
        const ah = o.height;
        const ax = r.origin.x;
        const ay = r.origin.y;
        std.debug.assert(aw > 0);
        std.debug.assert(ah > 0);
        var card = primitives.Quad.init(ax, ay, aw, ah);
        _ = card.set_background(theme.card)
            .set_corner_radius(theme.radius)
            .set_border_color(theme.border)
            .set_border_width(1);
        try b.append_quad(card);
        // Stash the area so the drag thunks can map a cursor point -> split.
        o.snap.* = .{ .h_x = ax, .h_w = aw, .v_y = ay, .v_h = ah };
        const sx = ax + aw * o.h.*;
        const rw = ax + aw - sx;
        const svy = ay + ah * o.v.*;
        try rs_label(b, theme, ax, ay, sx - ax, ah, "One");
        try rs_label(b, theme, sx, ay, rw, svy - ay, "Two");
        try rs_label(b, theme, sx, svy, rw, ay + ah - svy, "Three");
        // T-junction: the inner (vertical) divider wins; suppress the outer's hover.
        var outer_hov = false;
        if (o.paint) |p| {
            const inner_hov = resizable_kit.hovered(p, .vertical, sx, svy, rw);
            outer_hov = resizable_kit.hovered(p, .horizontal, sx, ay, ah) and !inner_hov;
        }
        _ = try resizable_kit.render(b, sx, ay, ah, .{
            .orientation = .horizontal,
            .kind = .line,
            .show_hover = outer_hov,
            .theme = theme,
            .paint = o.paint,
            .on_drag = o.on_resize_h,
            .ctx = o.ctx,
        });
        _ = try resizable_kit.render(b, sx, svy, rw, .{
            .orientation = .vertical,
            .kind = .line,
            .theme = theme,
            .paint = o.paint,
            .on_drag = o.on_resize_v,
            .ctx = o.ctx,
        });
    }
};

pub fn resizable_demo(a: A, theme: *const Theme, o: ResizableDemo) *Node {
    const spec = a.create(ResizableDemoSpec) catch @panic("node arena oom");
    spec.* = .{ .theme = theme, .o = o };
    return node.leaf(a, ResizableDemoSpec.measure, ResizableDemoSpec.draw, spec);
}

// One queued toast. The layer stamps start_s on first render (a click callback has
// no frame clock) and the slot self-expires by the wall clock.
pub const ToastSlot = struct {
    active: bool = false,
    started: bool = false,
    start_s: f64 = 0,
    text: []const u8 = "", // a static literal; the layer borrows it across frames
    variant: toast_kit.ToastVariant = .default,
};

const TOAST_W: f32 = 280;
const TOAST_GAP: f32 = 10;
const TOAST_MARGIN: f32 = 24;
const TOAST_ENTER: f64 = 0.18;
const TOAST_VIS: f64 = 2.6;
const TOAST_EXIT: f64 = 0.22;

fn toast_icon(v: toast_kit.ToastVariant) icon_render.Icon {
    return switch (v) {
        .success => .check_circle,
        .destructive => .close_circle,
        .default => .bell,
    };
}

// The floating toast stack (bottom-right), drawn in the non-modal hud region. No
// hitboxes - dismiss is timer-only; keeps the loop ticking while any toast lives.
pub const Toasts = struct {
    slots: []ToastSlot, // caller-owned, cross-frame
    paint: ?*custom_paint.PaintContext = null,
};

const ToastsSpec = struct {
    theme: *const Theme,
    o: Toasts,
    fn measure(b: *RenderBuilder, ctx: *anyopaque) SizeF {
        _ = b;
        _ = ctx;
        return SizeF.init(0, 0); // fills the hud region; positions in draw
    }
    fn draw(b: *RenderBuilder, ctx: *anyopaque, r: BoundsF) RenderError!void {
        const self: *ToastsSpec = @ptrCast(@alignCast(ctx));
        const pc = self.o.paint orelse return;
        std.debug.assert(self.o.slots.len <= 16);
        std.debug.assert(r.size.width >= 0);
        const th: f32 = toast_kit.HEIGHT_PLAIN;
        // Glyphs flush over every quad, so body text behind a toast bleeds through
        // its panel. Snapshot the body sprite count, then mask those glyphs per
        // toast rect (same fix as select/tooltip); toast glyphs land after body_end.
        const body_end = b.sprites.items.len;
        var stack: f32 = 0;
        var any = false;
        for (self.o.slots) |*t| {
            if (!t.active) continue;
            if (!t.started) {
                t.start_s = pc.now_s;
                t.started = true;
            }
            const el = pc.now_s - t.start_s;
            var opacity: f32 = 1;
            var off: f32 = 0;
            if (el < TOAST_ENTER) {
                const e: f32 = @floatCast(el / TOAST_ENTER);
                const s = e * (2 - e);
                opacity = s;
                off = (1 - s) * 16;
            } else if (el < TOAST_ENTER + TOAST_VIS) {
                opacity = 1;
            } else if (el < TOAST_ENTER + TOAST_VIS + TOAST_EXIT) {
                const e: f32 = @floatCast((el - TOAST_ENTER - TOAST_VIS) / TOAST_EXIT);
                const s = e * (2 - e);
                opacity = 1 - s;
                off = s * 8;
            } else {
                t.active = false;
                continue;
            }
            any = true;
            const tx = r.size.width - TOAST_W - TOAST_MARGIN;
            const ty = r.size.height - TOAST_MARGIN - th - stack * (th + TOAST_GAP) + off;
            const sz = try toast_kit.render(b, tx, ty, TOAST_W, .{
                .title = t.text,
                .variant = t.variant,
                .icon = toast_icon(t.variant),
                .theme = self.theme,
                .opacity = opacity,
            });
            mask_behind(b.sprites.items[0..body_end], .{ tx, ty, sz.width, sz.height });
            stack += 1;
        }
        if (any) pc.animating = true;
    }
};

pub fn toasts(a: A, theme: *const Theme, o: Toasts) *Node {
    const spec = a.create(ToastsSpec) catch @panic("node arena oom");
    spec.* = .{ .theme = theme, .o = o };
    return node.leaf(a, ToastsSpec.measure, ToastsSpec.draw, spec);
}

const TOOLTIP_DY: f32 = 34; // bubble baseline above the trigger
const TOOLTIP_PAD_X: f32 = 18; // matches the kit's horizontal padding (PAD_X * 2)

// A hover hint anchored above a trigger, drawn in the non-modal hud region. Shown
// only while the trigger rect is hovered; masks the body glyphs behind the bubble.
pub const TooltipOverlay = struct {
    text: []const u8,
    trigger: *const [4]f32, // the trigger's rect_out, read at draw
    paint: ?*custom_paint.PaintContext = null,
};

const TooltipOverlaySpec = struct {
    theme: *const Theme,
    o: TooltipOverlay,
    fn measure(b: *RenderBuilder, ctx: *anyopaque) SizeF {
        _ = b;
        _ = ctx;
        return SizeF.init(0, 0);
    }
    fn draw(b: *RenderBuilder, ctx: *anyopaque, r: BoundsF) RenderError!void {
        const self: *TooltipOverlaySpec = @ptrCast(@alignCast(ctx));
        std.debug.assert(self.o.text.len > 0);
        std.debug.assert(r.size.width >= 0);
        const pc = self.o.paint orelse return;
        const tg = self.o.trigger.*;
        if (tg[2] <= 0 or !pc.is_hovered(tg[0], tg[1], tg[2], tg[3])) return;
        const sty = label_render.Style{
            .font_size = self.theme.font_size - 2,
            .weight = .medium,
            .color = self.theme.foreground,
        };
        const m = label_render.measure(b, self.o.text, sty);
        const tw = m.width + TOOLTIP_PAD_X;
        const tx = tg[0] + (tg[2] - tw) / 2;
        const ty = tg[1] - TOOLTIP_DY;
        const body_end = b.sprites.items.len;
        const tip = try tooltip_kit.render(b, tx, ty, self.o.text, .{ .theme = self.theme });
        mask_behind(b.sprites.items[0..body_end], tip);
    }
};

pub fn tooltip_overlay(a: A, theme: *const Theme, o: TooltipOverlay) *Node {
    const spec = a.create(TooltipOverlaySpec) catch @panic("node arena oom");
    spec.* = .{ .theme = theme, .o = o };
    return node.leaf(a, TooltipOverlaySpec.measure, TooltipOverlaySpec.draw, spec);
}

const POPOVER_W: f32 = 300;
const POPOVER_H: f32 = 152;
const POPOVER_GAP: f32 = 6;
const POPOVER_PAD: f32 = 16;

// A floating panel anchored below a trigger (its rect_out), drawn in the overlay
// region. Like menu_overlay: a full-window dismiss absorber sits under the panel;
// an outside click closes. Draws its own title + description and masks the body.
pub const PopoverOverlay = struct {
    title: []const u8,
    description: []const u8 = "",
    trigger: *const [4]f32,
    view_y: f32 = 0, // body inset (content top) for the flip-above clamp
    view_h: f32 = 0, // content height; 0 disables the flip
    on_dismiss: ?callbacks.ClickFn = null,
    paint: ?*custom_paint.PaintContext = null,
    ctx: ?*anyopaque = null,
};

const PopoverOverlaySpec = struct {
    theme: *const Theme,
    o: PopoverOverlay,
    fn measure(b: *RenderBuilder, ctx: *anyopaque) SizeF {
        _ = b;
        _ = ctx;
        return SizeF.init(0, 0);
    }
    fn draw(b: *RenderBuilder, ctx: *anyopaque, r: BoundsF) RenderError!void {
        const self: *PopoverOverlaySpec = @ptrCast(@alignCast(ctx));
        const o = self.o;
        const pc = o.paint orelse return;
        std.debug.assert(o.title.len > 0);
        std.debug.assert(r.size.width >= 0);
        const tg = o.trigger.*;
        if (o.on_dismiss) |cb| try pc.add_hitbox(.{
            .x = 0,
            .y = 0,
            .w = r.size.width,
            .h = r.size.height,
            .on_click = cb,
            .ctx = o.ctx,
        });
        // Keep x on-screen; flip above the trigger if there's no room below.
        const margin: f32 = 12;
        const px = std.math.clamp(tg[0], margin, @max(margin, r.size.width - POPOVER_W - margin));
        var py = tg[1] + tg[3] + POPOVER_GAP;
        if (o.view_h > 0 and py + POPOVER_H > (o.view_y + o.view_h) - margin) {
            py = @max(o.view_y, tg[1] - POPOVER_H - POPOVER_GAP);
        }
        const body_end = b.sprites.items.len;
        const pr = try popover_kit.render(b, px, py, .{
            .theme = self.theme,
            .width = POPOVER_W,
            .height = POPOVER_H,
        });
        const title_sty = label_render.Style{
            .font_size = 14,
            .weight = .semi_bold,
            .color = self.theme.foreground,
        };
        const tx = pr[0] + POPOVER_PAD;
        _ = try label_render.render(b, tx, pr[1] + POPOVER_PAD, o.title, title_sty);
        if (o.description.len > 0) {
            const desc_sty = label_render.Style{
                .font_size = 12,
                .weight = .normal,
                .color = self.theme.muted_foreground,
            };
            _ = try label_render.render(b, tx, pr[1] + POPOVER_PAD + 22, o.description, desc_sty);
        }
        mask_behind(b.sprites.items[0..body_end], pr);
    }
};

pub fn popover_overlay(a: A, theme: *const Theme, o: PopoverOverlay) *Node {
    const spec = a.create(PopoverOverlaySpec) catch @panic("node arena oom");
    spec.* = .{ .theme = theme, .o = o };
    return node.leaf(a, PopoverOverlaySpec.measure, PopoverOverlaySpec.draw, spec);
}

// A modal panel sliding in from an edge, drawn in the overlay region. The caller
// owns the eased open_t; the leaf frosts the backdrop, scrims the body (the
// titlebar stays crisp via top_inset), and ticks the loop while mid-slide.
pub const Sheet = struct {
    side: sheet_kit.SheetSide = .right,
    size: f32 = 360,
    open_t: f32 = 1, // caller-eased slide progress 0..1
    top_inset: f32 = 0,
    title: []const u8 = "",
    description: []const u8 = "",
    scrim_alpha: f32 = 0.18,
    dismiss: bool = true, // wire the scrim outside-click only while opening/open
    on_close: ?callbacks.ClickFn = null,
    paint: ?*custom_paint.PaintContext = null,
    ctx: ?*anyopaque = null,
};

const SheetSpec = struct {
    theme: *const Theme,
    o: Sheet,
    fn measure(b: *RenderBuilder, ctx: *anyopaque) SizeF {
        _ = b;
        _ = ctx;
        return SizeF.init(0, 0);
    }
    fn draw(b: *RenderBuilder, ctx: *anyopaque, r: BoundsF) RenderError!void {
        const self: *SheetSpec = @ptrCast(@alignCast(ctx));
        const o = self.o;
        const pc = o.paint orelse return;
        std.debug.assert(o.size > 0);
        std.debug.assert(r.size.width >= 0);
        if (o.open_t <= 0.001) return;
        const inset = o.top_inset;
        if (r.size.height - inset <= 100) return; // the kit asserts a min body height
        // Frost everything drawn so far; the renderer keeps the band crisp.
        pc.blur_modal = true;
        pc.backdrop_prims = @intCast(b.prims.items.len);
        pc.backdrop_sprites = @intCast(b.sprites.items.len);
        pc.backdrop_color = @intCast(b.color_sprites.items.len);
        // Body-only scrim (the title strip stays crisp + live), fading with open_t.
        var scrim = primitives.Quad.init(0, inset, r.size.width, r.size.height - inset);
        _ = scrim.set_background(.{ .r = 0, .g = 0, .b = 0, .a = o.scrim_alpha * o.open_t });
        try b.append_quad(scrim);
        if (o.dismiss) if (o.on_close) |cb| try pc.add_hitbox(.{
            .x = 0,
            .y = inset,
            .w = r.size.width,
            .h = r.size.height - inset,
            .on_click = cb,
            .ctx = o.ctx,
        });
        _ = try sheet_kit.render(b, r.size.width, r.size.height, .{
            .side = o.side,
            .size = o.size,
            .open_t = o.open_t,
            .top_inset = inset,
            .title = o.title,
            .description = o.description,
            .theme = self.theme,
            .paint = pc,
            .on_close = o.on_close,
            .ctx = o.ctx,
        });
        if (o.open_t < 0.999) pc.animating = true; // keep ticking mid-slide
    }
};

pub fn sheet(a: A, theme: *const Theme, o: Sheet) *Node {
    const spec = a.create(SheetSpec) catch @panic("node arena oom");
    spec.* = .{ .theme = theme, .o = o };
    return node.leaf(a, SheetSpec.measure, SheetSpec.draw, spec);
}
