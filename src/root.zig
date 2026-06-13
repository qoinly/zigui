const std = @import("std");
const builtin = @import("builtin");

// Android has no main(): the framework calls the exported
// ANativeActivity_onCreate. Zig emits an export only when it is reachable, so
// force-reference it here - importing zigui from an Android app pulls the entry
// into the binary.
comptime {
    if (builtin.abi.isAndroid()) {
        _ = &@import("platform/android/app.zig").ANativeActivity_onCreate;
    }
}

const color = @import("color.zig");
const node = @import("node.zig");
const kit_nodes = @import("kit_nodes.zig");
const window = @import("window.zig");
const frame_ctx = @import("frame_ctx.zig");
const frame_mod = @import("frame.zig");
const input_mod = @import("input.zig");
const custom_shell = @import("custom_shell.zig");
const renderer = @import("renderer.zig");
const app_runtime = @import("app_runtime.zig");
const callbacks = @import("callbacks.zig");

pub const Node = node.Node;
pub const Config = node.Cfg;
pub const TextOpts = node.Txt;
// A clickable container without an explicit ctx gets the run state, same as
// button - so on_click = on(State, f) just works. An explicit click_ctx (a
// per-item record) still wins.
fn with_state_ctx(fc: *frame_ctx.FrameCtx, cfg: node.Cfg) node.Cfg {
    var c = cfg;
    if (c.on_click != null and c.click_ctx == null) c.click_ctx = fc.state;
    return c;
}
pub fn col(cfg: node.Cfg, kids: []const *node.Node) *node.Node {
    const fc = frame_ctx.get();
    return node.col(fc.arena, with_state_ctx(fc, cfg), kids);
}
pub fn row(cfg: node.Cfg, kids: []const *node.Node) *node.Node {
    const fc = frame_ctx.get();
    return node.row(fc.arena, with_state_ctx(fc, cfg), kids);
}
pub fn grid(cfg: node.Cfg, kids: []const *node.Node) *node.Node {
    const fc = frame_ctx.get();
    return node.grid(fc.arena, with_state_ctx(fc, cfg), kids);
}
pub fn grid_cols(spec: theme.GridCols, cfg: node.Cfg, kids: []const *node.Node) *node.Node {
    const fc = frame_ctx.get();
    return node.grid_cols(fc.arena, spec, with_state_ctx(fc, cfg), kids);
}
pub fn text(s: []const u8, o: node.Txt) *node.Node {
    return node.text(frame_ctx.get().arena, s, o);
}
pub fn spacer() *node.Node {
    return node.spacer(frame_ctx.get().arena);
}
pub fn scroll(state: *node.ScrollState, o: node.ScrollOpts, child: *node.Node) *node.Node {
    return node.scroll(frame_ctx.get().arena, state, o, child);
}
pub const ScrollState = node.ScrollState;
pub const ScrollOpts = node.ScrollOpts;
pub const ScrollBar = node.ScrollBar;

// Keep the render loop ticking next frame. Call it from a view that animates
// (a loading spinner, a toast countdown) - otherwise the loop idles after a
// frame with no input and the animation freezes.
pub fn animate() void {
    frame_ctx.get().paint.animating = true;
}
pub const render_tree = node.render;
pub const render_tree_at = node.render_at;

pub const theme = @import("theme.zig");
pub const Spacing = theme.Spacing;
pub const Breakpoint = theme.Breakpoint;
pub const Width = theme.Width;
pub const GridCols = theme.GridCols;
pub const bp = theme.bp;
pub const fluid = theme.fluid;

pub fn button(label: []const u8, o: kit_nodes.Btn) *node.Node {
    const fc = frame_ctx.get();
    var oo = o;
    oo.paint = fc.paint;
    oo.ctx = fc.state;
    return kit_nodes.button(fc.arena, fc.theme, label, oo);
}

// Wrap a typed callback (fn(*State)) as the erased ClickFn the kit stores. The
// state pointer comes back from run; the one cast is generated here, not the
// caller's to write.
pub fn on(comptime State: type, comptime f: fn (*State) void) callbacks.ClickFn {
    return struct {
        fn call(ctx: ?*anyopaque) void {
            f(@ptrCast(@alignCast(ctx.?)));
        }
    }.call;
}
// The erased handler type `on` returns; name it to forward a click through a
// helper (e.g. a nav_item that takes a handler argument).
pub const ClickFn = callbacks.ClickFn;
pub fn badge(label: []const u8, variant: kit.Variant) *node.Node {
    const fc = frame_ctx.get();
    return kit_nodes.badge(fc.arena, fc.theme, label, variant);
}
pub fn avatar(initials: []const u8, size: f32) *node.Node {
    const fc = frame_ctx.get();
    return kit_nodes.avatar(fc.arena, fc.theme, initials, size);
}

// Live external frame (remote screen / video) - draws `source`'s current texture
// into the layout. The decoder/app owns `source` (long-lived); feed it each frame.
pub const FrameSource = frame_mod.FrameSource;
pub const FrameOpts = frame_mod.FrameOpts;
pub const FrameFit = frame_mod.Fit;
pub const FrameMeta = frame_mod.FrameMeta;
pub const Colorspace = frame_mod.Colorspace;
pub const Range = frame_mod.Range;
pub fn frame(source: *FrameSource, opts: FrameOpts) *node.Node {
    const fc = frame_ctx.get();
    // A frame node is a live surface with no input to wake the loop, so keep
    // presenting while it is on screen. Gating on "has a frame arrived yet" instead
    // would race the decode thread at startup and wedge the loop; the source drops
    // stale frames so this never queues latency and acquire() is cheap when idle.
    fc.paint.animating = true;
    return kit_nodes.frame(fc.arena, source, opts);
}

// The backend handle a FrameSource needs to allocate its textures. Reachable only
// during a render pass (the render context owns the renderer).
pub const Renderer = renderer.Renderer;
pub const ClearColor = renderer.ClearColor;
pub const FrameSurface = renderer.FrameSurface;
pub fn renderer_handle() *Renderer {
    return &frame_ctx.get().paint.renderer;
}

// Raw input capture for a remote-control loop. grab() enters relative capture (the
// cursor hides + decouples, Escape releases); while grabbed, input arrives through
// input_events() instead of the widgets, for the app to forward. zigui owns the
// capture; the app owns what to send.
pub const InputEvent = input_mod.InputEvent;
pub const InputButton = input_mod.Button;
pub const InputMods = input_mod.Mods;
pub fn grab(enable: bool) void {
    frame_ctx.get().paint.set_grab(enable);
}
pub fn grabbed() bool {
    return frame_ctx.get().paint.grabbed();
}
pub fn input_events() []const InputEvent {
    return frame_ctx.get().paint.raw_inputs();
}

// Clipboard. Read/write plain text, plus an external-change poll: clipboard_changed
// returns true once each time something outside this app changes the clipboard (our
// own set_clipboard_text writes are not reported), so a remote-control loop can
// forward it. The clipboard is one per app (every window shares it), and the poll
// is edge-triggered, so call clipboard_changed once a frame from a single window.
pub fn clipboard_text(buf: []u8) []const u8 {
    return custom_shell.pasteboard_read_into(buf);
}
pub fn set_clipboard_text(s: []const u8) void {
    custom_shell.pasteboard_write_string(s);
}
pub fn clipboard_changed() bool {
    return custom_shell.clipboard_changed_external();
}

// Fullscreen + displays. set_fullscreen toggles native fullscreen on the app
// window; display_bounds(i) gives monitor i's frame in points so the app can size a
// stream or place a window per screen.
pub fn set_fullscreen(enable: bool) void {
    frame_ctx.get().paint.handle.set_fullscreen(enable);
}
pub fn fullscreen() bool {
    return frame_ctx.get().paint.handle.is_fullscreen();
}
// Whether the window rendering this frame holds keyboard focus. A multi-window
// app gates its focused input on this so only the key window drives the editor.
pub fn window_is_key() bool {
    return frame_ctx.get().paint.handle.is_key();
}
// Identity of the window rendering this frame, so one shared view can branch on
// which window it is drawing. The first window is 1; opened windows get their
// WindowOptions id (or an engine-assigned one).
pub fn window_id() u32 {
    return frame_ctx.get().window_id;
}
pub fn window_title() []const u8 {
    return frame_ctx.get().window_title;
}
pub fn display_count() u32 {
    return custom_shell.display_count();
}
pub fn display_bounds(index: u32) BoundsF {
    return custom_shell.display_bounds(index);
}
pub fn checkbox(checked: bool, label: []const u8, w: kit_nodes.Wire) *node.Node {
    const fc = frame_ctx.get();
    var ww = w;
    ww.paint = fc.paint;
    ww.ctx = fc.state;
    return kit_nodes.checkbox(fc.arena, fc.theme, checked, label, ww);
}
pub fn radio(selected: bool, label: []const u8, w: kit_nodes.Wire) *node.Node {
    const fc = frame_ctx.get();
    var ww = w;
    ww.paint = fc.paint;
    ww.ctx = fc.state;
    return kit_nodes.radio(fc.arena, fc.theme, selected, label, ww);
}
pub fn toggle(on_: bool, label: []const u8, w: kit_nodes.Wire) *node.Node {
    const fc = frame_ctx.get();
    var ww = w;
    ww.paint = fc.paint;
    ww.ctx = fc.state;
    return kit_nodes.toggle(fc.arena, fc.theme, on_, label, ww);
}
pub fn kbd(keys: []const []const u8) *node.Node {
    const fc = frame_ctx.get();
    return kit_nodes.kbd(fc.arena, fc.theme, keys);
}
// Platform-aware modifier-key labels for kbd combos / shortcut hints.
pub const key_command = @import("kit/kbd.zig").command;
pub const key_shift = @import("kit/kbd.zig").shift;
pub const key_option = @import("kit/kbd.zig").option;
pub fn toggle_button(label: []const u8, o: kit_nodes.ToggleBtn) *node.Node {
    const fc = frame_ctx.get();
    var oo = o;
    oo.paint = fc.paint;
    oo.ctx = fc.state;
    return kit_nodes.toggle_button(fc.arena, fc.theme, label, oo);
}
pub fn icon(ic: @import("icon.zig").Icon, opts: kit_nodes.IconOpts) *node.Node {
    return kit_nodes.icon(frame_ctx.get().arena, ic, opts);
}
pub const IconOpts = kit_nodes.IconOpts;
pub const Icon = @import("icon.zig").Icon;
pub const IconSource = @import("icon.zig").IconSource;
pub fn separator(orientation: kit.separator.Orientation) *node.Node {
    const fc = frame_ctx.get();
    return kit_nodes.separator(fc.arena, fc.theme, orientation);
}
pub fn skeleton(w: f32, h: f32, radius: f32) *node.Node {
    const fc = frame_ctx.get();
    return kit_nodes.skeleton(fc.arena, fc.theme, w, h, radius);
}
pub fn progress(value: f32, height: f32) *node.Node {
    const fc = frame_ctx.get();
    return kit_nodes.progress(fc.arena, fc.theme, value, height);
}
pub fn progress_indeterminate(height: f32) *node.Node {
    const fc = frame_ctx.get();
    return kit_nodes.progress_indeterminate(fc.arena, fc.theme, height, fc.paint);
}
pub fn spinner(radius: f32, c: color.Rgba) *node.Node {
    const fc = frame_ctx.get();
    return kit_nodes.spinner(fc.arena, fc.paint, radius, c);
}
pub fn input(
    value: []const u8,
    placeholder: []const u8,
    size: kit.Size,
    w: kit_nodes.InputWire,
) *node.Node {
    const fc = frame_ctx.get();
    var ww = w;
    ww.paint = fc.paint;
    ww.ctx = fc.state;
    return kit_nodes.input(fc.arena, fc.theme, value, placeholder, size, ww);
}
pub const TextField = kit_nodes.TextField;
pub const TextInputOpts = kit_nodes.TextInputOpts;
pub fn text_input(field: *kit_nodes.TextField, o: kit_nodes.TextInputOpts) *node.Node {
    const fc = frame_ctx.get();
    var oo = o;
    oo.paint = fc.paint;
    oo.ctx = fc.state;
    return kit_nodes.text_input(fc.arena, fc.theme, field, oo);
}
pub const EditableOpts = kit_nodes.EditableOpts;
pub fn text_editable(field: *kit_nodes.TextField, o: kit_nodes.EditableOpts) *node.Node {
    const fc = frame_ctx.get();
    var oo = o;
    oo.paint = fc.paint;
    oo.ctx = fc.state;
    return kit_nodes.text_editable(fc.arena, fc.theme, field, oo);
}
pub fn editable_text(
    value: []const u8,
    placeholder: []const u8,
    w: kit_nodes.InputWire,
) *node.Node {
    const fc = frame_ctx.get();
    var ww = w;
    ww.paint = fc.paint;
    ww.ctx = fc.state;
    return kit_nodes.editable_text(fc.arena, fc.theme, value, placeholder, ww);
}
pub fn textarea(state: *kit.textarea.TextAreaState, o: kit_nodes.Ta) *node.Node {
    const fc = frame_ctx.get();
    var oo = o;
    oo.paint = fc.paint;
    oo.ctx = fc.state;
    return kit_nodes.textarea(fc.arena, fc.theme, state, oo);
}
pub fn alert(title: []const u8, o: kit_nodes.AlertOpt) *node.Node {
    const fc = frame_ctx.get();
    return kit_nodes.alert(fc.arena, fc.theme, title, o);
}
pub fn tabs(
    labels: []const []const u8,
    state: *kit.tabs.TabsState,
    o: kit_nodes.Tabs,
) *node.Node {
    const fc = frame_ctx.get();
    var oo = o;
    oo.paint = fc.paint;
    oo.ctx = fc.state;
    return kit_nodes.tabs(fc.arena, fc.theme, labels, state, oo);
}
pub fn toggle_group(
    items: []const kit.toggle_group.ToggleGroupItem,
    o: kit_nodes.ToggleGrp,
) *node.Node {
    const fc = frame_ctx.get();
    var oo = o;
    oo.paint = fc.paint;
    return kit_nodes.toggle_group(fc.arena, fc.theme, items, oo);
}
pub fn slider(
    values: []const f32,
    state: *kit.slider.SliderState,
    o: kit_nodes.Slider,
) *node.Node {
    const fc = frame_ctx.get();
    var oo = o;
    oo.paint = fc.paint;
    oo.ctx = fc.state;
    return kit_nodes.slider(fc.arena, fc.theme, values, state, oo);
}
pub fn select(label: []const u8, o: kit_nodes.Sel) *node.Node {
    const fc = frame_ctx.get();
    var oo = o;
    oo.paint = fc.paint;
    oo.ctx = fc.state;
    return kit_nodes.select(fc.arena, fc.theme, label, oo);
}

// The open dropdown for a select: put it in the overlay region. Anchored to the
// trigger's rect_out, dismisses on an outside click.
pub fn select_overlay(o: kit_nodes.SelectOverlay) *node.Node {
    const fc = frame_ctx.get();
    var oo = o;
    oo.paint = fc.paint;
    oo.ctx = fc.state;
    return kit_nodes.select_overlay(fc.arena, fc.theme, oo);
}
// Charts take paint for the hover tooltip; the facade injects it (the caller sets
// theme + data). A mouse-move redraws, so no animate() is needed.
pub fn line_chart(o: kit.chart.LineChartOptions, height: f32) *node.Node {
    const fc = frame_ctx.get();
    var oo = o;
    oo.paint = fc.paint;
    return kit_nodes.line_chart(fc.arena, oo, height);
}
pub fn bar_chart(o: kit.chart.BarChartOptions, height: f32) *node.Node {
    const fc = frame_ctx.get();
    var oo = o;
    oo.paint = fc.paint;
    return kit_nodes.bar_chart(fc.arena, oo, height);
}
pub fn donut(o: kit.chart.DonutChartOptions, height: f32) *node.Node {
    const fc = frame_ctx.get();
    var oo = o;
    oo.paint = fc.paint;
    return kit_nodes.donut(fc.arena, oo, height);
}
pub const ButtonOpts = kit_nodes.Btn;
pub const ToggleButtonOpts = kit_nodes.ToggleBtn;
pub const TextAreaOpts = kit_nodes.Ta;
pub const TabsOpts = kit_nodes.Tabs;
pub const ToggleGroupOpts = kit_nodes.ToggleGrp;
pub const SliderOpts = kit_nodes.Slider;
pub const SelectOpts = kit_nodes.Sel;
pub const SelectOverlayOpts = kit_nodes.SelectOverlay;
pub const AlertOpts = kit_nodes.AlertOpt;
pub const DialogOpts = kit_nodes.Dialog;
pub const DialogAction = kit_nodes.DialogAction;

// An overlay component: put it in the overlay region. It frosts the backdrop
// (blur_modal), scrims, centers the kit.dialog card, and dismisses on an
// outside click.
pub fn dialog(o: kit_nodes.Dialog) *node.Node {
    const fc = frame_ctx.get();
    var oo = o;
    oo.paint = fc.paint;
    oo.ctx = fc.state;
    return kit_nodes.dialog(fc.arena, fc.theme, oo);
}
pub fn sidebar(o: kit_nodes.Sidebar) *node.Node {
    const fc = frame_ctx.get();
    var oo = o;
    oo.paint = fc.paint;
    oo.ctx = fc.state;
    return kit_nodes.sidebar(fc.arena, fc.theme, oo);
}
pub const SidebarOpts = kit_nodes.Sidebar;
pub const SidebarState = @import("kit/sidebar.zig").SidebarState;
pub const SidebarEntry = window.SidebarEntry;
pub const SidebarKind = window.SidebarKind;

pub fn tabbar(o: kit_nodes.Tabbar) *node.Node {
    const fc = frame_ctx.get();
    var oo = o;
    oo.paint = fc.paint;
    oo.ctx = fc.state;
    return kit_nodes.tabbar(fc.arena, fc.theme, oo);
}
pub const TabbarOpts = kit_nodes.Tabbar;
pub const TabItem = kit.tabbar.TabItem;
pub const TabBarState = kit.tabbar.TabBarState;

// The open dropdown menu: put it in the overlay region. Anchored to the trigger's
// rect_out, dismisses on an outside click.
pub fn menu_overlay(o: kit_nodes.MenuOverlay) *node.Node {
    const fc = frame_ctx.get();
    var oo = o;
    oo.paint = fc.paint;
    oo.ctx = fc.state;
    return kit_nodes.menu_overlay(fc.arena, fc.theme, oo);
}
pub const MenuOverlayOpts = kit_nodes.MenuOverlay;
pub const MenuEntry = kit.menu.MenuEntry;
pub const MenuState = kit.menu.MenuState;

// The full Resizable demo as one node (card + 3 region labels + 2 draggable dividers).
pub fn resizable_demo(o: kit_nodes.ResizableDemo) *node.Node {
    const fc = frame_ctx.get();
    var oo = o;
    oo.paint = fc.paint;
    oo.ctx = fc.state;
    return kit_nodes.resizable_demo(fc.arena, fc.theme, oo);
}
pub const ResizableDemoOpts = kit_nodes.ResizableDemo;
pub const ResizableSnap = kit_nodes.ResizableSnap;

// The floating toast stack: put it in the non-modal hud region. Self-times off the
// frame clock; the caller owns the slot array.
pub fn toasts(o: kit_nodes.Toasts) *node.Node {
    const fc = frame_ctx.get();
    var oo = o;
    oo.paint = fc.paint;
    return kit_nodes.toasts(fc.arena, fc.theme, oo);
}
pub const ToastsOpts = kit_nodes.Toasts;
pub const ToastSlot = kit_nodes.ToastSlot;
pub const ToastVariant = kit.toast.ToastVariant;

// A hover hint: put it in the non-modal hud region. Anchored above the trigger's
// rect_out, shown only while the trigger is hovered.
pub fn tooltip_overlay(o: kit_nodes.TooltipOverlay) *node.Node {
    const fc = frame_ctx.get();
    var oo = o;
    oo.paint = fc.paint;
    return kit_nodes.tooltip_overlay(fc.arena, fc.theme, oo);
}
pub const TooltipOverlayOpts = kit_nodes.TooltipOverlay;

// A floating panel: put it in the overlay region. Anchored below the trigger's
// rect_out, dismisses on an outside click, draws its own title + description.
pub fn popover_overlay(o: kit_nodes.PopoverOverlay) *node.Node {
    const fc = frame_ctx.get();
    var oo = o;
    oo.paint = fc.paint;
    oo.ctx = fc.state;
    return kit_nodes.popover_overlay(fc.arena, fc.theme, oo);
}
pub const PopoverOverlayOpts = kit_nodes.PopoverOverlay;

// A modal edge sheet: put it in the overlay region. The caller eases open_t.
pub fn sheet(o: kit_nodes.Sheet) *node.Node {
    const fc = frame_ctx.get();
    var oo = o;
    oo.paint = fc.paint;
    oo.ctx = fc.state;
    return kit_nodes.sheet(fc.arena, fc.theme, oo);
}
pub const SheetOpts = kit_nodes.Sheet;
pub const SheetSide = kit.sheet.SheetSide;

// Typed id / disclosure / drag callbacks - like `on`, but for the kit callbacks
// that carry an id (sidebar select, group disclose) or a drag point (resize).
pub fn on_id(comptime State: type, comptime f: fn (*State, []const u8) void) callbacks.SelectIdFn {
    return struct {
        fn call(ctx: ?*anyopaque, id: []const u8) void {
            f(@ptrCast(@alignCast(ctx.?)), id);
        }
    }.call;
}
pub fn on_disclose(
    comptime State: type,
    comptime f: fn (*State, []const u8, bool) void,
) callbacks.DiscloseFn {
    return struct {
        fn call(ctx: ?*anyopaque, id: []const u8, open: bool) void {
            f(@ptrCast(@alignCast(ctx.?)), id, open);
        }
    }.call;
}
pub fn on_drag(comptime State: type, comptime f: fn (*State, f32, f32) void) callbacks.DragFn {
    return struct {
        fn call(ctx: ?*anyopaque, x: f32, y: f32) void {
            f(@ptrCast(@alignCast(ctx.?)), x, y);
        }
    }.call;
}
// Index + value callback, for a slider thumb moving (the caller writes values[i]).
pub fn on_at(comptime State: type, comptime f: fn (*State, usize, f32) void) kit.slider.ChangeAtFn {
    return struct {
        fn call(ctx: ?*anyopaque, i: usize, v: f32) void {
            f(@ptrCast(@alignCast(ctx.?)), i, v);
        }
    }.call;
}
// Single-delta callback, for a select dropdown's chevron-band scroll step.
pub fn on_delta(comptime State: type, comptime f: fn (*State, f32) void) kit.select.ScrollDeltaFn {
    return struct {
        fn call(ctx: ?*anyopaque, d: f32) void {
            f(@ptrCast(@alignCast(ctx.?)), d);
        }
    }.call;
}
// Index callback, for the tabbar select/close/pin (fn(ctx, index)).
pub fn on_index(comptime State: type, comptime f: fn (*State, usize) void) kit.tabbar.TabSelectFn {
    return struct {
        fn call(ctx: ?*anyopaque, i: usize) void {
            f(@ptrCast(@alignCast(ctx.?)), i);
        }
    }.call;
}
// From/to callback, for the tabbar drag-reorder (fn(ctx, from, to)).
pub fn on_move2(
    comptime State: type,
    comptime f: fn (*State, usize, usize) void,
) kit.tabbar.TabMoveFn {
    return struct {
        fn call(ctx: ?*anyopaque, from: usize, to: usize) void {
            f(@ptrCast(@alignCast(ctx.?)), from, to);
        }
    }.call;
}

pub const kit = @import("kit/root.zig");

pub const app = @import("app.zig");
// Android's high-level App owns a different lifecycle (the surface arrives async
// via onNativeWindowCreated, the framework owns the run loop), so it gets a
// parallel App that reuses the render bridge + paint machinery but forks the
// loop ownership. The desktop App.init/run stays byte-for-byte. Select the
// module first (the app.zig facade pattern) so the Android file stays out of
// non-Android analysis - its NativeActivity export must never reach a desktop
// binary.
const app_runtime_impl = if (builtin.abi.isAndroid())
    @import("platform/android/app_runtime.zig")
else
    app_runtime;
pub const App = app_runtime_impl.App;
pub const WindowOptions = app_runtime.App.WindowOptions;
pub const Frame = app_runtime.Frame;
pub const Theme = window.Theme;
pub const ActivationPolicy = app.ActivationPolicy;

pub const Window = struct {
    pub const Handle = window.Handle;
    pub const SimpleOptions = window.SimpleOptions;
    pub const MetalHandle = window.MetalHandle;
    pub const MetalOptions = window.MetalOptions;
    pub const PanelHandle = window.PanelHandle;
    pub const PanelOptions = window.PanelOptions;
    pub const PanelMaterial = window.PanelMaterial;
    pub const NativeShellHandle = window.NativeShellHandle;
    pub const NativeShellOptions = window.NativeShellOptions;
    pub const ShellOptions = window.ShellOptions;
    pub const ChromeKind = window.ChromeKind;
    pub const Feel = window.Feel;
    pub const Theme = window.Theme;
    pub const Variant = window.Variant;
    pub const Size = window.Size;
    pub const ToolbarSeparator = window.ToolbarSeparator;
    pub const SidebarKind = window.SidebarKind;
    pub const SidebarEntry = window.SidebarEntry;
    pub const SidebarSelectFn = window.SidebarSelectFn;
    pub const ToolbarItemKind = window.ToolbarItemKind;
    pub const ToolbarEntry = window.ToolbarEntry;
    pub const ToolbarSubItem = window.ToolbarSubItem;
    pub const ToolbarMenuItem = window.ToolbarMenuItem;
    pub const ToolbarSelectFn = window.ToolbarSelectFn;
    pub const ToolbarSearchFn = window.ToolbarSearchFn;
    pub const Error = window.Error;
    pub const open_simple = window.open_simple;
    pub const open_metal = window.open_metal;
    pub const open_panel = window.open_panel;
    pub const open_native_shell = window.open_native_shell;
    pub const CustomShellHandle = window.CustomShellHandle;
    pub const open_custom_shell = window.open_custom_shell;
    pub const show_text_field = window.show_text_field;
    pub const hide_text_field = window.hide_text_field;
    pub const text_field_value = window.text_field_value;
    pub const PaintContext = window.PaintContext;
    pub const Frame = window.Frame;
    pub const PaintCallback = window.PaintCallback;
    pub const start_paint_loop = window.start_paint_loop;
    pub const set_sidebar_items = window.set_sidebar_items;
    pub const set_sidebar_on_select = window.set_sidebar_on_select;
    pub const set_sidebar_on_reorder = window.set_sidebar_on_reorder;
    pub const SidebarReorderFn = window.SidebarReorderFn;
    pub const set_sidebar_selection = window.set_sidebar_selection;
    pub const set_native_shell_title = window.set_native_shell_title;
    pub const ScrollEvent = window.ScrollEvent;
    pub const ScrollFn = window.ScrollFn;
    pub const set_native_shell_on_scroll = window.set_native_shell_on_scroll;
    pub const BodyMouseEvent = window.BodyMouseEvent;
    pub const BodyMouseFn = window.BodyMouseFn;
    pub const BodyExitFn = window.BodyExitFn;
    pub const set_native_shell_on_body_move = window.set_native_shell_on_body_move;
    pub const set_native_shell_on_body_click = window.set_native_shell_on_body_click;
    pub const set_native_shell_on_body_exit = window.set_native_shell_on_body_exit;
    pub const set_toolbar_items = window.set_toolbar_items;
    pub const set_toolbar_on_select = window.set_toolbar_on_select;
    pub const set_toolbar_on_search = window.set_toolbar_on_search;
    pub const AlertStyle = window.AlertStyle;
    pub const AlertOptions = window.AlertOptions;
    pub const AlertFn = window.AlertFn;
    pub const FilePickerOptions = window.FilePickerOptions;
    pub const FilePickerFn = window.FilePickerFn;
    pub const run_alert = window.run_alert;
    pub const native_image_named = window.native_image_named;
    pub const open_file = window.open_file;
    pub const save_file = window.save_file;
};

pub const Rgba = color.Rgba;
pub const Hsla = color.Hsla;
// Blend a toward b by t, keeping a's alpha. Mix a surface toward the theme
// foreground for a hover/elevated shade that tracks light and dark themes.
pub const mix = @import("kit/theme_resolve.zig").mix;

// Value types only; the engine-side bounds math stays internal.
pub const geometry = @import("geometry.zig");
pub const SizeF = geometry.SizeF;
pub const BoundsF = geometry.BoundsF;
pub const PointF = geometry.PointF;
pub const SizeProposal = geometry.SizeProposal;
pub const Size = geometry.Size;
pub const Bounds = geometry.Bounds;
pub const Point = geometry.Point;

// Transitional escape hatches: the examples still drive the render backend by
// hand, so these stay reachable until the facade wraps every call.
pub const render = @import("render/root.zig");
pub const RenderBuilder = render.RenderBuilder;
pub const layout = @import("layout.zig");
pub const style = @import("style.zig");
pub const text_system = @import("text_system.zig");

const primitives = @import("primitives.zig");
pub const Quad = primitives.Quad;
pub const Primitive = primitives.Primitive;
pub const MonochromeSprite = primitives.MonochromeSprite;
pub const PolychromeSprite = primitives.PolychromeSprite;

test {
    std.testing.refAllDecls(@This());
    _ = @import("kit/textarea.zig"); // refAllDecls is non-recursive; pull kit/* tests in explicitly
}
