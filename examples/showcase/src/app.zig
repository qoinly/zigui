const std = @import("std");
const zigui = @import("zigui");
const Node = zigui.Node;
const Frame = zigui.Frame;
const sidebar = @import("scaffold/sidebar.zig");
const router = @import("router.zig");

// Single source of truth: the view is a pure function of this, handlers mutate it.
// No allocator/engine/theme here - the runtime owns those and hands them back on
// the Frame, so caller state is just data. Each page namespaces its own sub-state.
pub const App = struct {
    nav: zigui.SidebarState = .{ .selected_id = "dashboard" },
    nav_scroll: f32 = 0,
    sidebar_w: f32 = 260,
    sidebar_collapsed: bool = false,
    groups: Groups = .{},
    content_scroll: zigui.ScrollState = .{},
    dialog_open: bool = false,
    forms: Forms = .{},
    sel: Select = .{},
    tabbar: Tabbar = .{},
    menu: Menu = .{},
    workspace: Workspace = .{},
    resizable: Resizable = .{},
    toasts: [3]zigui.ToastSlot = .{ .{}, .{}, .{} },
    tip: Tooltip = .{},
    popover: Popover = .{},
    sheet: Sheet = .{},
    tabs: Tabs = .{},

    // Push a toast into the first free slot; if all full, overwrite slot 0.
    // text must be a static literal - the slot borrows it across frames.
    pub fn toast(self: *App, text: []const u8, variant: zigui.ToastVariant) void {
        for (&self.toasts) |*s| {
            if (!s.active) {
                s.* = .{ .active = true, .text = text, .variant = variant };
                return;
            }
        }
        self.toasts[0] = .{ .active = true, .text = text, .variant = variant };
    }

    pub const SelKind = enum { flat, scroll, group, search };

    // Select demos. vals seed each trigger; the dropdown panel renders in the
    // overlay region. fg/fg_items back the combobox's filtered view so the slices
    // outlive the per-frame tree.
    pub const Select = struct {
        open: ?SelKind = null,
        rects: [4][4]f32 = [_][4]f32{.{ 0, 0, 0, 0 }} ** 4,
        vals: [4][]const u8 = .{ "apple", "tyo", "carrot", "" },
        scroll: f32 = 0,
        state: zigui.kit.select.SelectState = .{},
        search: zigui.TextField = .{},
        fg: [8]zigui.kit.select.SelectGroup = undefined,
        fg_items: [40]zigui.kit.select.SelectItem = undefined,
    };

    // One open API tab per record; the kit reads `items` (rebuilt each frame from
    // recs). state must keep a stable address - hitbox shims back-point into it.
    pub const TabRec = struct {
        id: []const u8,
        title: []const u8,
        prefix: []const u8 = "",
        pcolor: u24 = 0,
        dirty: bool = false,
        pinned: bool = false,
    };
    pub const Tabbar = struct {
        state: zigui.kit.tabbar.TabBarState = .{},
        recs: [zigui.kit.tabbar.MAX_TABS]TabRec = undefined,
        recs_len: usize = 0,
        active: usize = 0,
        scroll: f32 = 0,
        seeded: bool = false,
        items: [zigui.kit.tabbar.MAX_TABS]zigui.kit.tabbar.TabItem = undefined,
        new_n: usize = 0,
        new_bufs: [zigui.kit.tabbar.MAX_TABS][12]u8 = undefined,
    };
    pub const Menu = struct {
        open: bool = false,
        notify: bool = false, // the checkbox item's live state
        rect: [4]f32 = .{ 0, 0, 0, 0 }, // trigger rect_out
        state: zigui.kit.menu.MenuState = .{},
    };
    pub const Workspace = struct {
        open: bool = false,
        selected: []const u8 = "community", // active workspace id (static literal)
        rect: [4]f32 = .{ 0, 0, 0, 0 }, // chip rect_out, anchors the dropdown
        state: zigui.kit.menu.MenuState = .{},
    };
    pub const Resizable = struct {
        h: f32 = 0.4, // left/right split fraction
        v: f32 = 0.36, // top/bottom split of the right region
        snap: zigui.ResizableSnap = .{}, // geometry the drag thunk reads
    };
    pub const Tooltip = struct {
        rect: [4]f32 = .{ 0, 0, 0, 0 }, // trigger rect_out
    };
    pub const Popover = struct {
        open: bool = false,
        rect: [4]f32 = .{ 0, 0, 0, 0 }, // trigger rect_out
    };
    pub const Sheet = struct {
        open: bool = false,
        side: zigui.kit.sheet.SheetSide = .right,
        t: f32 = 0, // eased slide progress 0..1
    };
    pub const Tabs = struct {
        state: zigui.kit.tabs.TabsState = .{}, // stable address - shims back-point
        sel: usize = 0,
    };

    // Forms open by default, matching the reference showcase.
    pub const Groups = struct {
        forms: bool = true,
        display: bool = false,
        chart: bool = false,
        feedback: bool = false,
    };

    pub const Forms = struct {
        counter: i32 = 0,
        in_focus: u32 = 0, // which text field holds the native editor (0 = none)
        inputs: [3]zigui.TextField = .{ .{}, .{}, .{} },
        editable: zigui.TextField = .{},
        editable_seeded: bool = false,
        cb_terms: bool = true,
        cb_news: bool = false,
        sw_airplane: bool = true,
        sw_wifi: bool = false,
        tg_bold: bool = true,
        tg_italic: bool = false,
        tg_b: bool = true,
        tg_i: bool = false,
        tg_u: bool = false,
        radio: u8 = 0,
        tgg_align: u8 = 1,
        tgg_bold: bool = true,
        tgg_italic: bool = false,
        tgg_underline: bool = false,

        // Sliders: value slices + a per-slider geometry snapshot the drag reads.
        sl_single: [1]f32 = .{0.5},
        sl_range: [2]f32 = .{ 0.2, 0.7 },
        sl_step: [1]f32 = .{0.4},
        sl_disabled: [1]f32 = .{0.3},
        st_single: zigui.kit.slider.SliderState = .{},
        st_range: zigui.kit.slider.SliderState = .{},
        st_step: zigui.kit.slider.SliderState = .{},
        st_disabled: zigui.kit.slider.SliderState = .{},

        // Textarea: caller-owned states + buffers, seeded lazily on first render
        // (a by-value App can't hold a buffer self-pointer at init).
        ta_plain: zigui.kit.textarea.TextAreaState = undefined,
        ta_json: zigui.kit.textarea.TextAreaState = undefined,
        ta_plain_buf: [1024]u8 = undefined,
        ta_json_buf: [1024]u8 = undefined,
        ta_spans: [256]zigui.kit.textarea.TextSpan = undefined,
        ta_span_n: usize = 0,
        ta_span_seq: u64 = std.math.maxInt(u64), // != edit_seq(0) so the first tokenise runs
        ta_seeded: bool = false,
    };

    pub fn view(f: *Frame, app: *App) *Node {
        // Fill the body so the content sits on the opaque theme background, not the
        // translucent liquid-glass material (the sidebar paints its own bg on top).
        return zigui.row(.{ .grow = 1, .bg = f.theme.background }, &.{
            sidebar.view(f, app),
            zigui.scroll(&app.content_scroll, .{ .grow = 1 }, router.view(f, app)),
        });
    }
};
