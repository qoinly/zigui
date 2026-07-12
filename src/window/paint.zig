const std = @import("std");
const builtin = @import("builtin");
const custom_shell = @import("../custom_shell.zig");
const types = @import("types.zig");
const renderer = @import("../renderer.zig");
const text_system = @import("../text_system.zig");
const icon_system = @import("../icon.zig");
const app_icon = @import("../app_icon.zig");
const primitives = @import("../primitives.zig");
const render = @import("../render/root.zig");
const display_link = @import("../display_link.zig");
const geometry = @import("../geometry.zig");
const color = @import("../color.zig");
const label = @import("../render/label.zig");
const input = @import("../input.zig");
const background = @import("../background.zig");

pub const CustomShellHandle = custom_shell.CustomShellHandle;
pub const RenderBuilder = render.RenderBuilder;
pub const HitBox = types.HitBox;
const Quad = primitives.Quad;
const BoundsF = geometry.BoundsF;

// The pinned 0.16.0 std has no Timer/Instant/nanoTimestamp, so read the platform
// monotonic clock directly. darwin: clock_gettime CLOCK_MONOTONIC_RAW (=4),
// vDSO-backed and not NTP-slewed. windows: QueryPerformanceCounter (no libc).
const timespec = extern struct { tv_sec: isize, tv_nsec: isize };
extern "c" fn clock_gettime(clk: c_int, tp: *timespec) c_int;
extern "kernel32" fn QueryPerformanceCounter(count: *i64) callconv(.winapi) i32;
extern "kernel32" fn QueryPerformanceFrequency(freq: *i64) callconv(.winapi) i32;
fn monotonic_seconds() f64 {
    if (builtin.os.tag == .windows) {
        var freq: i64 = 0;
        var count: i64 = 0;
        _ = QueryPerformanceFrequency(&freq);
        _ = QueryPerformanceCounter(&count);
        if (freq == 0) return 0;
        return @as(f64, @floatFromInt(count)) / @as(f64, @floatFromInt(freq));
    }
    var ts: timespec = undefined;
    _ = clock_gettime(4, &ts);
    return @as(f64, @floatFromInt(ts.tv_sec)) + @as(f64, @floatFromInt(ts.tv_nsec)) * 1e-9;
}

// Per-frame key queue depth. Generous for human typing + key-repeat between two
// vsync ticks; excess is dropped (a stuck flood, not real input).
pub const MAX_KEY_EVENTS = 32;

// Per-frame raw-capture queue depth (grab mode). Mouse motion alone can fire many
// times between two vsync ticks, so this is larger than the key queue; excess is
// dropped.
pub const MAX_RAW_EVENTS = 256;

// Width (points) of the macOS traffic-light cluster (3 buttons + gaps), reserved
// after content_left so the titlebar content region clears them.
const TRAFFIC_CLUSTER_W: f32 = 72;

// Point size for the Windows caption-button glyphs (Segoe Fluent Icons).
const CAPTION_GLYPH_PT: f32 = 10;

pub const Frame = struct {
    builder: RenderBuilder,
    width: f32, // full drawable, in points
    height: f32,
    // Content area below the titlebar band. With the titlebar enabled,
    // origin.y = band height and size.height = height - band. Titlebar
    // disabled => body == {0,0,width,height}.
    body: BoundsF,
    // Titlebar content region: the band minus the traffic-light gutter on the
    // left. The library paints the band chrome (bg + separator) itself; the
    // consumer fills this rect with its own bar content. Zero-size when the
    // titlebar is disabled.
    titlebar: BoundsF,
};

pub const PaintContext = struct {
    handle: CustomShellHandle,
    allocator: std.mem.Allocator,
    renderer: renderer.Renderer,
    text_system: text_system.TextSystem,
    icon_system: icon_system.IconSystem,
    color_atlas: app_icon.ColorAtlas,
    app_icon_resolver: app_icon.AppIconResolver,
    prims: std.ArrayListUnmanaged(primitives.Primitive) = .empty,
    sprites: std.ArrayListUnmanaged(primitives.MonochromeSprite) = .empty,
    color_sprites: std.ArrayListUnmanaged(primitives.PolychromeSprite) = .empty,
    hitboxes: std.ArrayListUnmanaged(HitBox) = .empty,
    prev_hover_ctx: ?*anyopaque = null,
    // The topmost hovered box's stable id, refreshed each frame from the hitboxes.
    // A view reads it (via the frame) to reveal-on-hover.
    hovered_id: []const u8 = "",
    mouse_x: f32 = -1,
    mouse_y: f32 = -1,
    mouse_inside: bool = false,
    // Drag capture: a hitbox with on_point grabs the mouse on press, so a
    // press-hold-drag keeps feeding it raw points until release (slider rail).
    drag_cb: ?*const fn (ctx: ?*anyopaque, x: f32, y: f32) void = null,
    drag_ctx: ?*anyopaque = null,
    // Fired once on release if the captured hitbox had one (drop / click-end).
    drag_end_cb: ?*const fn (ctx: ?*anyopaque) void = null,
    // Vertical scroll offset (points). The consumer sets max_scroll_y each
    // frame from its content height; onScroll accumulates + clamps here.
    scroll_y: f32 = 0,
    max_scroll_y: f32 = 0,
    // Raw wheel delta since the consumer last read it; lets the app route the
    // wheel to a transient surface (e.g. an open dropdown) instead of the body.
    // Consumer drains it each frame. dx drives horizontal surfaces, dy vertical.
    wheel_dy: f32 = 0,
    wheel_dx: f32 = 0,
    // A queue (not one-shot) because an editor can see several keys per frame
    // and key-repeat fires fast. Drained by the paint callback, cleared after.
    key_events: [MAX_KEY_EVENTS]custom_shell.KeyEvent = undefined,
    key_len: u32 = 0,
    // Raw input captured this frame while grabbed (relative motion, raw keys/
    // buttons/wheel). Drained by the paint callback, cleared after, same as keys.
    raw_events: [MAX_RAW_EVENTS]input.InputEvent = undefined,
    raw_len: u32 = 0,
    // Cursor the consumer wants this frame (resets to .default each frame; set it
    // while hovering a resize edge etc). Applied after the paint callback.
    cursor: custom_shell.CursorKind = .default,
    // Set by the consumer each frame: keep redrawing at vsync while true
    // (drives time-based animation; drawFrame otherwise clears dirty and the
    // loop idles until the next input event).
    animating: bool = false,
    // Monotonic seconds since init, for frame-rate-independent time-based
    // animation (e.g. a caret blink).
    now_s: f64 = 0,
    base_s: f64 = 0, // clock value at init; now_s stays small for f64 precision
    // A one-shot redraw deadline (in now_s seconds). Lets a view schedule a wakeup
    // far cheaper than animating() every vsync: the loop idles until now_s hits it,
    // fires one redraw, and clears it. Re-arm each frame for a periodic refresh.
    redraw_at: ?f64 = null,
    // When set, the renderer blurs all prims/sprites up to the backdrop_* split
    // and draws the rest crisp on top. Set before emitting the modal layer.
    blur_modal: bool = false,
    backdrop_prims: u32 = 0,
    backdrop_sprites: u32 = 0,
    backdrop_color: u32 = 0,
    // The iOS frosted bars: each is x, y, w, h, corner in points the kit marks; the
    // backdrop (up to the backdrop_* split) blurs under them, items crisp on top. Holds
    // a nav bar + a tab bar in one frame.
    frost_rects: [6][6]f32 = undefined,
    frost_count: u32 = 0,
    // Set while drawing a modal's backdrop so is_hovered reports false there: the
    // frosted layer behind a modal must be inert (no hover), not just blurred.
    block_hover: bool = false,
    // A focused text input sets this while showing the native editor; the runtime
    // hides the singleton editor on a frame where nobody claims it (blur / nav away).
    text_field_active: bool = false,
    // Back navigation: the navigator publishes its stack depth each frame so the
    // Android backend knows whether a Back press should pop (consume it) or
    // background the app (depth 1). back_pressed is set by that backend on a Back
    // it consumed; Esc on desktop arrives through the normal key queue instead.
    nav_depth: u32 = 1,
    back_pressed: bool = false,
    scale_factor: f32 = 2.0,
    last_pane_w: f32 = 0,
    last_pane_h: f32 = 0,
    run_state: ?*RunState = null,

    pub fn init(
        self: *PaintContext,
        handle: CustomShellHandle,
        allocator: std.mem.Allocator,
    ) !void {
        self.handle = handle;
        self.allocator = allocator;
        self.renderer = try renderer.Renderer.init(handle.metal_layer);
        self.text_system = text_system.TextSystem.init(allocator, self.renderer.get_device());
        self.icon_system = icon_system.IconSystem.init(allocator, self.text_system.mono_atlas());
        self.color_atlas = app_icon.ColorAtlas.init(allocator, self.renderer.get_device());
        self.app_icon_resolver = app_icon.AppIconResolver.init(allocator, &self.color_atlas);
        self.prims = .empty;
        self.sprites = .empty;
        self.color_sprites = .empty;
        self.hitboxes = .empty;
        self.mouse_x = -1;
        self.mouse_y = -1;
        self.mouse_inside = false;
        self.drag_cb = null;
        self.drag_ctx = null;
        self.drag_end_cb = null;
        self.scroll_y = 0;
        self.max_scroll_y = 0;
        self.wheel_dy = 0;
        self.wheel_dx = 0;
        self.key_len = 0;
        self.raw_len = 0;
        self.cursor = .default;
        self.animating = false;
        self.base_s = monotonic_seconds();
        self.now_s = 0;
        self.blur_modal = false;
        self.backdrop_prims = 0;
        self.backdrop_sprites = 0;
        self.backdrop_color = 0;
        self.frost_count = 0;
        self.block_hover = false;
        self.text_field_active = false;
        // Rasterize glyphs at the real device scale: a 1x surface fed 2x
        // rasters is a permanent linear downsample (soft text). macOS pins the
        // 2x default - its shell exposes no scale query on the handle and
        // Retina is the configuration the Metal backend is verified on.
        self.scale_factor = if (builtin.os.tag == .macos)
            2.0
        else
            handle.backing_scale_factor();
        self.last_pane_w = 0;
        self.last_pane_h = 0;
        self.prev_hover_ctx = null;
    }

    pub fn request_redraw(self: *PaintContext) void {
        self.renderer.request_redraw();
    }

    // Schedule one redraw ~seconds from now. Cheaper than animating every vsync
    // for a slow refresh (a clock, a resource meter); re-arm each frame to repeat.
    // The earliest request wins, so independent schedulers in one frame (e.g. a 1 s
    // meter and a 0.5 s caret blink) compose instead of the last one clobbering the rest.
    pub fn request_redraw_after(self: *PaintContext, seconds: f64) void {
        const at = self.now_s + seconds;
        self.redraw_at = if (self.redraw_at) |cur| @min(cur, at) else at;
    }

    // Record the topmost hover-id box under the pointer. Call once per frame after
    // every hitbox is registered; ids are stable (caller literals), so the value
    // survives to the next frame's build where a view reveals its hovered row.
    pub fn refresh_hover(self: *PaintContext) void {
        var id: []const u8 = "";
        if (self.mouse_inside) {
            var i: usize = self.hitboxes.items.len;
            while (i > 0) {
                i -= 1;
                const hb = self.hitboxes.items[i];
                if (hb.hover_id.len == 0) continue;
                if (self.mouse_x >= hb.x and self.mouse_x < hb.x + hb.w and
                    self.mouse_y >= hb.y and self.mouse_y < hb.y + hb.h)
                {
                    id = hb.hover_id;
                    break;
                }
            }
        }
        if (std.mem.eql(u8, id, self.hovered_id)) return;
        self.hovered_id = id;
        self.renderer.request_redraw();
    }

    pub fn add_hitbox(self: *PaintContext, hb: HitBox) !void {
        try self.hitboxes.append(self.allocator, hb);
    }

    pub fn is_hovered(self: *const PaintContext, x: f32, y: f32, w: f32, h: f32) bool {
        if (!self.mouse_inside or self.block_hover) return false;
        return self.mouse_x >= x and self.mouse_x < x + w and
            self.mouse_y >= y and self.mouse_y < y + h;
    }

    // Whether a point (in points) hits an interactive titlebar component
    // CONTAINED within the band. The Windows custom shell uses this so a click on
    // a titlebar component reaches it (HTCLIENT) while empty band area drags the
    // window (HTCAPTION). Band-containment (hb fits in [0, band_h]) excludes any
    // full-window backstop hitbox the consumer registers, so drag still works.
    pub fn point_over_titlebar_control(
        self: *const PaintContext,
        x: f32,
        y: f32,
        band_h: f32,
    ) bool {
        for (self.hitboxes.items) |hb| {
            if (hb.y + hb.h > band_h + 2) continue;
            if (x >= hb.x and x < hb.x + hb.w and y >= hb.y and y < hb.y + hb.h) return true;
        }
        return false;
    }

    pub fn on_mouse_moved(self: *PaintContext, x: f32, y: f32) void {
        self.mouse_x = x;
        self.mouse_y = y;
        self.mouse_inside = true;
        self.renderer.request_redraw();
    }

    pub fn on_mouse_exited(self: *PaintContext) void {
        self.mouse_inside = false;
        self.renderer.request_redraw();
    }

    // AppKit scrollingDeltaY > 0 = swipe down = content moves down = top of
    // content revealed, so the offset decreases toward 0.
    pub fn on_scroll(self: *PaintContext, dx: f32, dy: f32) void {
        self.scroll_y = std.math.clamp(self.scroll_y - dy, 0, self.max_scroll_y);
        self.wheel_dy += dy;
        self.wheel_dx += dx;
        self.renderer.request_redraw();
    }

    pub fn on_key(self: *PaintContext, ev: custom_shell.KeyEvent) void {
        if (self.key_len < self.key_events.len) {
            self.key_events[self.key_len] = ev;
            self.key_len += 1;
        }
        self.renderer.request_redraw();
    }

    pub fn keys(self: *const PaintContext) []const custom_shell.KeyEvent {
        return self.key_events[0..self.key_len];
    }

    // Whether a back-navigation was requested this frame: Esc on desktop (through
    // the key queue) or the platform Back button (the back_pressed flag, cleared
    // here). The navigator calls it once per frame to pop the route stack.
    pub fn take_back(self: *PaintContext) bool {
        var requested = self.back_pressed;
        self.back_pressed = false;
        for (self.keys()) |ke| {
            if (ke.code == .escape) requested = true;
        }
        return requested;
    }

    pub fn on_raw_event(self: *PaintContext, ev: input.InputEvent) void {
        std.debug.assert(self.raw_len <= self.raw_events.len);
        if (self.raw_len < self.raw_events.len) {
            self.raw_events[self.raw_len] = ev;
            self.raw_len += 1;
        }
        self.renderer.request_redraw();
    }

    pub fn raw_inputs(self: *const PaintContext) []const input.InputEvent {
        return self.raw_events[0..self.raw_len];
    }

    // Enter/leave relative capture; while grabbed, input arrives via raw_inputs()
    // instead of the UI, and Escape releases it.
    pub fn set_grab(self: *PaintContext, on: bool) void {
        _ = self;
        custom_shell.set_grab(on);
    }

    pub fn grabbed(self: *const PaintContext) bool {
        _ = self;
        return custom_shell.is_grabbed();
    }

    pub fn set_cursor(self: *PaintContext, kind: custom_shell.CursorKind) void {
        self.cursor = kind;
    }

    // The native editor (a shared singleton NSTextField); the focused input shows
    // it over its rect and polls the value. Claiming it keeps the runtime from
    // hiding it this frame.
    // Returns whether the editor was actually shown for this window. It is not,
    // and the caller should skip its caret/value poll, when another window owns
    // the shared editor (only the key window may host it).
    pub fn show_text_field(
        self: *PaintContext,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        initial: []const u8,
        font_size: f32,
        rgba: types.Rgba,
        id: u32,
    ) bool {
        const shown = custom_shell.show_text_field(
            self.handle,
            x,
            y,
            w,
            h,
            initial,
            font_size,
            rgba,
            false,
            false,
            id,
        );
        if (shown) self.text_field_active = true;
        return shown;
    }
    pub fn text_field_value(self: *PaintContext, buf: []u8) []const u8 {
        _ = self;
        return custom_shell.text_field_value(buf);
    }
    pub fn hide_text_field(self: *PaintContext) void {
        custom_shell.hide_text_field(self.handle);
    }

    pub fn on_mouse_down(self: *PaintContext, x: f32, y: f32) void {
        self.mouse_x = x;
        self.mouse_y = y;
        self.mouse_inside = true;
        var i: usize = self.hitboxes.items.len;
        while (i > 0) {
            i -= 1;
            const hb = self.hitboxes.items[i];
            if (x >= hb.x and x < hb.x + hb.w and y >= hb.y and y < hb.y + hb.h) {
                if (hb.on_point) |cb| {
                    cb(hb.ctx, x, y);
                    self.drag_cb = cb;
                    self.drag_ctx = hb.ctx;
                    self.drag_end_cb = hb.on_drag_end;
                } else if (hb.on_click) |cb| {
                    cb(hb.ctx);
                }
                self.renderer.request_redraw();
                return;
            }
        }
    }

    pub fn on_right_mouse_down(self: *PaintContext, x: f32, y: f32) void {
        self.mouse_x = x;
        self.mouse_y = y;
        self.mouse_inside = true;
        var i: usize = self.hitboxes.items.len;
        while (i > 0) {
            i -= 1;
            const hb = self.hitboxes.items[i];
            if (x >= hb.x and x < hb.x + hb.w and y >= hb.y and y < hb.y + hb.h) {
                if (hb.on_context) |cb| {
                    cb(hb.ctx, x, y);
                    self.renderer.request_redraw();
                    return;
                }
            }
        }
    }

    pub fn on_mouse_dragged(self: *PaintContext, x: f32, y: f32) void {
        self.mouse_x = x;
        self.mouse_y = y;
        self.mouse_inside = true;
        if (self.drag_cb) |cb| cb(self.drag_ctx, x, y);
        self.renderer.request_redraw();
    }

    pub fn on_mouse_up(self: *PaintContext) void {
        if (self.drag_end_cb) |cb| cb(self.drag_ctx);
        self.drag_cb = null;
        self.drag_ctx = null;
        self.drag_end_cb = null;
        self.renderer.request_redraw();
    }

    // Touch has no separate wheel: a finger drag scrolls the region under it,
    // UNLESS the press captured a draggable control (a slider rail), which then
    // drags instead. The mouse backends keep wheel and drag as distinct inputs and
    // never call this; only the touch backend routes a move through here.
    pub fn on_touch_move(self: *PaintContext, x: f32, y: f32) void {
        const dy = y - self.mouse_y; // delta before the position update
        self.mouse_x = x;
        self.mouse_y = y;
        self.mouse_inside = true;
        if (self.drag_cb) |cb| {
            cb(self.drag_ctx, x, y);
        } else {
            self.on_scroll(0, dy); // feeds wheel_dy; the hovered scroll region consumes it
        }
        self.renderer.request_redraw();
    }

    pub fn tick(self: *PaintContext) ?Frame {
        // A minimized window has a degenerate client; skip painting it entirely
        // (its tiny titlebar band would underflow widths and assert in the kit).
        if (builtin.os.tag == .windows) {
            if (self.handle.is_minimized()) return null;
        }

        const size = self.handle.sync_drawable_size();
        const pane_w: f32 = @floatCast(size.width);
        const pane_h: f32 = @floatCast(size.height);

        // The scale is dynamic on non-macOS: Wayland learns it from a surface
        // enter AFTER init, and a Windows window dragged onto a different-DPI
        // monitor changes scale mid-run.
        if (builtin.os.tag != .macos) {
            const live_scale = self.handle.backing_scale_factor();
            if (live_scale != self.scale_factor) {
                self.scale_factor = live_scale;
                self.renderer.request_redraw();
            }
        }

        // Skip degenerate frames (minimized / closing window): laying the node
        // tree out into a zero-size rect underflows widths and asserts in the kit.
        if (pane_w < 1 or pane_h < 1) return null;

        if (pane_w != self.last_pane_w or pane_h != self.last_pane_h) {
            self.last_pane_w = pane_w;
            self.last_pane_h = pane_h;
            self.renderer.request_redraw();
        }
        if (self.animating) self.renderer.request_redraw();
        // A background job finished: render once so the view's poll() picks up the
        // result. The edge is consumed here, on the loop's own thread.
        if (background.took_completion()) self.renderer.request_redraw();
        self.now_s = monotonic_seconds() - self.base_s;
        if (self.redraw_at) |deadline| {
            if (self.now_s >= deadline) {
                self.redraw_at = null;
                self.renderer.request_redraw();
            }
        }
        if (!self.renderer.dirty) return null;

        self.prims.clearRetainingCapacity();
        self.sprites.clearRetainingCapacity();
        self.color_sprites.clearRetainingCapacity();
        self.hitboxes.clearRetainingCapacity();

        const tbar = self.handle.titlebar;
        // Fullscreen hides the window chrome, so drop our custom band too and let the
        // body fill the whole screen.
        const band_on = tbar.enabled and !self.handle.is_fullscreen();
        const top: f32 = if (band_on) @floatCast(tbar.height) else 0;
        // macOS reserves a left gutter for the repositioned traffic lights;
        // Windows and Linux draw their window controls in the band's right
        // cluster, so their content starts at content_left with no gutter.
        const tb_content_x: f32 = if (builtin.os.tag == .macos)
            @floatCast(tbar.content_left + TRAFFIC_CLUSTER_W)
        else
            @floatCast(tbar.content_left);
        // Band chrome first (bg + separator) so the consumer's titlebar content
        // draws on top. The library owns only the band and the traffic lights.
        if (band_on) {
            const th = self.handle.theme;
            var band = Quad.init(0, 0, pane_w, top);
            _ = band.set_background(th.background);
            self.prims.append(self.allocator, .{ .quad = band }) catch {};
            if (tbar.separator) {
                var sep = Quad.init(0, top - 1, pane_w, 1);
                _ = sep.set_background(th.border);
                self.prims.append(self.allocator, .{ .quad = sep }) catch {};
            }
            // Windows and Linux draw their window controls into the band; macOS
            // uses native traffic lights repositioned by the platform layer.
            if (builtin.os.tag != .macos) self.draw_caption_buttons(pane_w, top);
        }
        // Safe-area insets carve the body in from the surface edges (the mobile
        // system bars); zero on desktop, so the body math below is unchanged there.
        const insets = custom_shell.safe_area_insets();
        return .{
            .builder = .{
                .prims = &self.prims,
                .sprites = &self.sprites,
                .color_sprites = &self.color_sprites,
                .text_system = &self.text_system,
                .icon_system = &self.icon_system,
                .app_icon_resolver = &self.app_icon_resolver,
                .allocator = self.allocator,
                .scale_factor = self.scale_factor,
            },
            .width = pane_w,
            .height = pane_h,
            .body = .{
                .origin = .{ .x = insets.left, .y = top + insets.top },
                .size = .{
                    .width = pane_w - insets.left - insets.right,
                    .height = pane_h - top - insets.top - insets.bottom,
                },
            },
            // Windows reserves the right cluster for the window-control buttons so
            // consumer titlebar content does not draw under them.
            .titlebar = if (band_on) .{
                .origin = .{ .x = tb_content_x, .y = 0 },
                .size = .{
                    .width = @max(pane_w - tb_content_x - custom_shell.CAPTION_CLUSTER_W, 0),
                    .height = top,
                },
            } else .{ .origin = .{}, .size = .{} },
        };
    }

    pub fn draw_frame(self: *PaintContext, frame: Frame) void {
        _ = frame;
        // macOS clears transparent so the glass chrome shows through; the other
        // backends have no glass, so they clear to the opaque theme background.
        const clear = if (builtin.os.tag == .macos)
            renderer.ClearColor.init(0, 0, 0, 0)
        else blk: {
            const bg = self.handle.theme.background;
            break :blk renderer.ClearColor.init(bg.r, bg.g, bg.b, 1);
        };
        const color_atlas_tex: ?*anyopaque = self.color_atlas.get_texture();
        if (self.frost_count > 0) {
            // The iOS bars marked frosted regions: the backdrop (up to the backdrop_*
            // split) blurs under them, the bars' items draw crisp on top.
            self.renderer.draw_frame_frost(
                clear,
                self.prims.items,
                self.sprites.items,
                self.text_system.mono_atlas_texture(),
                self.color_sprites.items,
                color_atlas_tex,
                @intCast(self.backdrop_prims),
                @intCast(self.backdrop_sprites),
                @intCast(self.backdrop_color),
                self.frost_rects[0..self.frost_count],
            );
        } else if (self.blur_modal) {
            const tbar = self.handle.titlebar;
            const crisp_top: f32 = if (tbar.enabled) @floatCast(tbar.height) else 0;
            self.renderer.draw_frame_modal(
                clear,
                self.prims.items,
                self.sprites.items,
                self.text_system.mono_atlas_texture(),
                self.color_sprites.items,
                color_atlas_tex,
                @intCast(self.backdrop_prims),
                @intCast(self.backdrop_sprites),
                @intCast(self.backdrop_color),
                crisp_top,
            );
        } else {
            self.renderer.draw_frame(
                clear,
                self.prims.items,
                self.sprites.items,
                self.text_system.mono_atlas_texture(),
                self.color_sprites.items,
                color_atlas_tex,
            );
        }
    }

    // Draws the minimize / maximize / close controls right-aligned in the band
    // (Windows + Linux custom chrome). Clicks route through the platform shell
    // (WM_NCHITTEST / the wl_pointer handler); here we only draw the glyphs +
    // hover highlight.
    fn draw_caption_buttons(self: *PaintContext, pane_w: f32, top: f32) void {
        const fg = self.handle.theme.foreground;
        const hovered = custom_shell.hovered_caption_button();
        const bw = custom_shell.CAPTION_BTN_W;
        // Windows packs the slots flush to the edge (margin 0); Linux keeps the
        // Adwaita-style gap. One formula serves both, and the shell's hit slots
        // mirror it.
        const right_margin = custom_shell.CAPTION_CLUSTER_W - bw * 3;
        const cy = top / 2;
        // Segoe Fluent Icons caption glyphs (same codepoints as Segoe MDL2):
        // minimize E921, maximize E922, restore E923, close E8BB.
        const fid = self.text_system.get_font_id("Segoe Fluent Icons", .normal);
        const max_glyph: u21 = if (self.handle.is_maximized()) 0xE923 else 0xE922;
        const Btn = struct { kind: custom_shell.CaptionButton, cx: f32, glyph: u21 };
        const slots = custom_shell.caption_slots();
        std.debug.assert(slots.count >= 1);
        std.debug.assert(slots.count <= 3);
        var buttons: [3]Btn = undefined;
        for (slots.kinds[0..slots.count], 0..) |kind, i| {
            buttons[i] = .{
                .kind = kind,
                .cx = pane_w - right_margin - bw * (@as(f32, @floatFromInt(i)) + 0.5),
                .glyph = switch (kind) {
                    .close => 0xE8BB,
                    .maximize => max_glyph,
                    .minimize => 0xE921,
                    .none => 0,
                },
            };
        }
        for (buttons[0..slots.count]) |btn| {
            const is_hover = hovered == btn.kind;
            if (builtin.os.tag == .linux) {
                // The Yaru/GNOME idiom: close keeps a permanent circle in the
                // DESKTOP accent (the user's setting; app theme primary only
                // when no desktop accent resolves), the other buttons get a
                // circle only while hovered.
                const accent = custom_shell.desktop_accent_color() orelse
                    self.handle.theme.primary;
                const maybe_bg: ?color.Rgba = if (btn.kind == .close)
                    (if (is_hover) lerp_rgba(accent, fg, 0.25) else accent)
                else if (is_hover)
                    color.Rgba.init(1, 1, 1, 0.14)
                else
                    null;
                if (maybe_bg) |bg| {
                    var q = Quad.init(
                        self.snap_pt(btn.cx - CAPTION_CIRCLE_D / 2),
                        self.snap_pt(cy - CAPTION_CIRCLE_D / 2),
                        CAPTION_CIRCLE_D,
                        CAPTION_CIRCLE_D,
                    );
                    _ = q.set_background(bg);
                    _ = q.set_corner_radius(CAPTION_CIRCLE_D / 2);
                    self.prims.append(self.allocator, .{ .quad = q }) catch {};
                }
            } else if (is_hover) {
                // Win11 feel: subtle light wash for min/max, red for close.
                const bg = if (btn.kind == .close)
                    color.Rgba.init(0.79, 0.16, 0.12, 1.0)
                else
                    color.Rgba.init(1, 1, 1, 0.08);
                var q = Quad.init(btn.cx - bw / 2, 0, bw, top);
                _ = q.set_background(bg);
                self.prims.append(self.allocator, .{ .quad = q }) catch {};
            }
            // Mint-Y draws the close icon near-white on any accent (its
            // C_icon_close_bg constant); the app fallback keeps its own pair.
            const col = if (builtin.os.tag == .linux and btn.kind == .close)
                (if (custom_shell.desktop_accent_color() != null)
                    color.Rgba.init(0.97, 0.97, 0.97, 1)
                else
                    self.handle.theme.primary_foreground)
            else if (is_hover and btn.kind == .close)
                color.Rgba.init(1, 1, 1, 1)
            else
                fg;
            if (builtin.os.tag == .linux) {
                self.draw_caption_glyph_quads(btn.kind, btn.cx, cy, col);
                continue;
            }
            var ubuf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(btn.glyph, &ubuf) catch continue;
            const line = self.text_system.shape_text(ubuf[0..n], CAPTION_GLYPH_PT, fid);
            if (line.runs.len == 0 or line.runs[0].glyphs.len == 0) continue;
            // Center on the glyph's real ink box, not the font ascent/descent -
            // Fluent symbol glyphs sit centered in the em box, not on the text
            // baseline, so the metric centering leaves them riding high.
            const rb = self.text_system.platform().glyph_raster_bounds(.{
                .font_id = fid,
                .glyph_id = line.runs[0].glyphs[0].id,
                .font_size = CAPTION_GLYPH_PT,
                .subpixel_variant = .{ .x = 0, .y = 0 },
                .scale_factor = self.scale_factor,
                .is_emoji = false,
            });
            const ink_oy = @as(f32, @floatFromInt(rb.origin.y));
            const ink_h = @as(f32, @floatFromInt(rb.size.height));
            const ink_cy = (ink_oy + ink_h / 2.0) / self.scale_factor;
            const ox = btn.cx - line.width / 2;
            const oy = cy - ink_cy;
            self.text_system.sprites_for_line(
                line,
                ox,
                oy,
                col,
                self.scale_factor,
                &self.sprites,
                self.allocator,
            ) catch {};
        }
    }

    fn lerp_rgba(a: color.Rgba, b: color.Rgba, t: f32) color.Rgba {
        std.debug.assert(t >= 0);
        std.debug.assert(t <= 1);
        return .{
            .r = a.r + (b.r - a.r) * t,
            .g = a.g + (b.g - a.g) * t,
            .b = a.b + (b.b - a.b) * t,
            .a = a.a + (b.a - a.a) * t,
        };
    }

    // A glyph rect off the device-pixel grid feathers its 1px edges across two
    // rows at half intensity (the band centre sits at .5 for odd band heights),
    // so every caption rect snaps before drawing.
    fn snap_pt(self: *const PaintContext, v: f32) f32 {
        std.debug.assert(self.scale_factor > 0);
        return @round(v * self.scale_factor) / self.scale_factor;
    }

    // Pinned to the Mint-Y/Adwaita button-bg asset (16px); do not size by feel.
    const CAPTION_CIRCLE_D: f32 = 16;

    // Linux caption glyphs as plain quads (no symbol font exists there): a bar,
    // a bordered square (doubled for restore), and two thin rotated bars.
    fn draw_caption_glyph_quads(
        self: *PaintContext,
        kind: custom_shell.CaptionButton,
        cx: f32,
        cy: f32,
        col: color.Rgba,
    ) void {
        std.debug.assert(kind != .none);
        std.debug.assert(cy > 0);
        switch (kind) {
            .minimize => {
                var q = Quad.init(self.snap_pt(cx - 3.5), self.snap_pt(cy - 0.5), 7, 1);
                _ = q.set_background(col);
                self.prims.append(self.allocator, .{ .quad = q }) catch {};
            },
            .maximize => {
                if (self.handle.is_maximized()) {
                    var back = Quad.init(self.snap_pt(cx - 1.5), self.snap_pt(cy - 3.5), 5, 5);
                    _ = back.set_border_color(col);
                    _ = back.set_border_widths(1, 1, 1, 1);
                    _ = back.set_corner_radius(1);
                    self.prims.append(self.allocator, .{ .quad = back }) catch {};
                    var front = Quad.init(self.snap_pt(cx - 3.5), self.snap_pt(cy - 1.5), 5, 5);
                    _ = front.set_background(self.handle.theme.background);
                    _ = front.set_border_color(col);
                    _ = front.set_border_widths(1, 1, 1, 1);
                    _ = front.set_corner_radius(1);
                    self.prims.append(self.allocator, .{ .quad = front }) catch {};
                } else {
                    var q = Quad.init(self.snap_pt(cx - 3.5), self.snap_pt(cy - 3.5), 7, 7);
                    _ = q.set_border_color(col);
                    _ = q.set_border_widths(1, 1, 1, 1);
                    _ = q.set_corner_radius(1);
                    self.prims.append(self.allocator, .{ .quad = q }) catch {};
                }
            },
            .close => {
                // The quad transform rotates in unit space BEFORE the bounds
                // scale, so a true diagonal needs square bounds with the bar
                // thinned via scale_y, not an elongated quad rotated.
                const angles = [_]f32{ std.math.pi / 4.0, -std.math.pi / 4.0 };
                for (angles) |angle| {
                    var q = Quad.init(self.snap_pt(cx - 4), self.snap_pt(cy - 4), 8, 8);
                    _ = q.set_background(col);
                    q.transform = .{ angle, 1, 1.2 / 8.0, 0 };
                    self.prims.append(self.allocator, .{ .quad = q }) catch {};
                }
            },
            .none => {},
        }
    }

    pub fn deinit(self: *PaintContext) void {
        custom_shell.set_grab(false); // never tear down with the cursor hidden/decoupled
        self.prims.deinit(self.allocator);
        self.sprites.deinit(self.allocator);
        self.color_sprites.deinit(self.allocator);
        self.hitboxes.deinit(self.allocator);
        // Release the GPU/text subsystems (reverse init order). macOS never
        // returns from run_forever so this only runs on Windows, but it is
        // correct on both - it frees the shape cache + atlas maps.
        self.app_icon_resolver.deinit();
        self.color_atlas.deinit();
        self.icon_system.deinit();
        self.text_system.deinit();
        self.renderer.deinit();
    }
};

// The only failure the per-frame callback can surface is the render pass running
// the arena out of memory; keep the boundary a closed set, not anyerror.
pub const PaintError = error{OutOfMemory};
pub const PaintCallback = *const fn (
    ctx: *anyopaque,
    paint: *PaintContext,
    frame: Frame,
) PaintError!void;

pub const RunState = struct {
    paint_ctx: *PaintContext,
    user_ctx: *anyopaque,
    user_cb: PaintCallback,
};

// Fallback for the old single-window Windows path before an HWND has bound its
// paint context. Normal Windows WM_SIZE now arrives with the per-window context.
var g_resize_state: ?*RunState = null;

fn paint_tick_thunk(p: ?*anyopaque) callconv(.c) void {
    // The RunState arrives as the display-link callback's type-erased context.
    const s: *RunState = @ptrCast(@alignCast(p orelse return));
    custom_shell.release_grab_if_blurred();
    const frame = s.paint_ctx.tick() orelse return;
    s.paint_ctx.cursor = .default; // consumer re-requests it while hovering an edge
    s.user_cb(s.user_ctx, s.paint_ctx, frame) catch return;
    s.paint_ctx.key_len = 0;
    s.paint_ctx.raw_len = 0;
    s.paint_ctx.wheel_dy = 0; // per-frame delta; consumer reads it in the callback above
    s.paint_ctx.wheel_dx = 0;
    custom_shell.apply_cursor(s.paint_ctx.cursor);
    s.paint_ctx.draw_frame(frame);
}

fn mouse_move_thunk(ctx: *anyopaque, x: f32, y: f32) void {
    const paint: *PaintContext = @ptrCast(@alignCast(ctx));
    paint.on_mouse_moved(x, y);
}

fn raw_event_thunk(ctx: *anyopaque, ev: input.InputEvent) void {
    const paint: *PaintContext = @ptrCast(@alignCast(ctx));
    paint.on_raw_event(ev);
}

fn mouse_exit_thunk(ctx: *anyopaque) void {
    const paint: *PaintContext = @ptrCast(@alignCast(ctx));
    paint.on_mouse_exited();
}

fn mouse_down_thunk(ctx: *anyopaque, x: f32, y: f32) void {
    const paint: *PaintContext = @ptrCast(@alignCast(ctx));
    paint.on_mouse_down(x, y);
}

fn mouse_drag_thunk(ctx: *anyopaque, x: f32, y: f32) void {
    const paint: *PaintContext = @ptrCast(@alignCast(ctx));
    paint.on_mouse_dragged(x, y);
}

fn touch_move_thunk(ctx: *anyopaque, x: f32, y: f32) void {
    const paint: *PaintContext = @ptrCast(@alignCast(ctx));
    paint.on_touch_move(x, y);
}

// The platform Back button (Android): consume it (and request a pop) only when a
// route is pushed; at the root, return false so the OS backgrounds the app.
fn back_thunk(ctx: *anyopaque) bool {
    const paint: *PaintContext = @ptrCast(@alignCast(ctx));
    if (paint.nav_depth <= 1) return false;
    paint.back_pressed = true;
    paint.request_redraw();
    return true;
}

fn right_mouse_down_thunk(ctx: *anyopaque, x: f32, y: f32) void {
    const paint: *PaintContext = @ptrCast(@alignCast(ctx));
    paint.on_right_mouse_down(x, y);
}

fn mouse_up_thunk(ctx: *anyopaque) void {
    const paint: *PaintContext = @ptrCast(@alignCast(ctx));
    paint.on_mouse_up();
}

fn scroll_thunk(ctx: *anyopaque, dx: f32, dy: f32) void {
    const paint: *PaintContext = @ptrCast(@alignCast(ctx));
    paint.on_scroll(dx, dy);
}

fn key_thunk(ctx: *anyopaque, ev: custom_shell.KeyEvent) void {
    const paint: *PaintContext = @ptrCast(@alignCast(ctx));
    paint.on_key(ev);
}

fn hit_test_thunk(ctx: *anyopaque, x: f32, y: f32, band_h: f32) bool {
    const paint: *PaintContext = @ptrCast(@alignCast(ctx));
    return paint.point_over_titlebar_control(x, y, band_h);
}

fn redraw_thunk(ctx: *anyopaque) void {
    const paint: *PaintContext = @ptrCast(@alignCast(ctx));
    paint.request_redraw();
}

// Full paint cycle, run synchronously from WM_SIZE so a live resize re-renders
// at each step instead of stretching the last frame.
fn paint_now_thunk(ctx: *anyopaque) void {
    std.debug.assert(@intFromPtr(ctx) != 0);
    const paint: *PaintContext = @ptrCast(@alignCast(ctx));
    const s = paint.run_state orelse (g_resize_state orelse return);
    std.debug.assert(s.paint_ctx == paint);
    paint_tick_thunk(@ptrCast(s));
}

pub fn start_paint_loop(
    run_state: *RunState,
    paint: *PaintContext,
    ctx: *anyopaque,
    cb: PaintCallback,
) !display_link.DisplayLink {
    std.debug.assert(@intFromPtr(run_state) != 0);
    std.debug.assert(@intFromPtr(paint) != 0);
    run_state.* = .{ .paint_ctx = paint, .user_ctx = ctx, .user_cb = cb };
    paint.run_state = run_state;
    if (builtin.os.tag == .windows) g_resize_state = run_state;
    custom_shell.register_hit_test(hit_test_thunk, redraw_thunk, @ptrCast(paint));
    if (builtin.os.tag != .macos) custom_shell.register_paint_now(paint_now_thunk);
    custom_shell.register_mouse_dispatch(.{
        .on_move = mouse_move_thunk,
        .on_exit = mouse_exit_thunk,
        .on_down = mouse_down_thunk,
        .on_right_down = right_mouse_down_thunk,
        .on_drag = mouse_drag_thunk,
        .on_up = mouse_up_thunk,
        .on_scroll = scroll_thunk,
        .on_key = key_thunk,
        .ctx = @ptrCast(paint),
    });
    custom_shell.register_raw_dispatch(.{ .on_event = raw_event_thunk, .ctx = @ptrCast(paint) });
    custom_shell.register_touch_move(touch_move_thunk, @ptrCast(paint));
    custom_shell.register_back(back_thunk, @ptrCast(paint));
    custom_shell.bind_surface_ctx(paint.handle, @ptrCast(paint));
    var dl = try display_link.DisplayLink.init(
        display_link.get_main_display_id(),
        @ptrCast(run_state),
        paint_tick_thunk,
    );
    errdefer dl.deinit();
    try dl.start();
    return dl;
}
