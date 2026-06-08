const std = @import("std");
const geometry = @import("geometry.zig");
const events = @import("events.zig");

const Bounds = geometry.Bounds;
const MouseDownEvent = events.MouseDownEvent;
const MouseUpEvent = events.MouseUpEvent;
const MouseMoveEvent = events.MouseMoveEvent;
const KeyDownEvent = events.KeyDownEvent;
const KeyUpEvent = events.KeyUpEvent;

pub const HitboxId = u32;
pub const FocusId = u32;
pub const ScrollId = u32;

pub const InputModality = enum { keyboard, mouse };

pub const FocusHandle = struct {
    id: FocusId,
    tab_index: i32 = 0,
    tab_stop: bool = true,

    pub fn with_tab_index(self: FocusHandle, index: i32) FocusHandle {
        var h = self;
        h.tab_index = index;
        return h;
    }

    pub fn with_tab_stop(self: FocusHandle, enabled: bool) FocusHandle {
        var h = self;
        h.tab_stop = enabled;
        return h;
    }
};

pub const ScrollHandle = struct {
    id: ScrollId,

    // Negative offset = content scrolled past the origin in that axis.
    offset_x: f32 = 0,
    offset_y: f32 = 0,

    max_offset_x: f32 = 0,
    max_offset_y: f32 = 0,

    content_width: f32 = 0,
    content_height: f32 = 0,

    viewport_width: f32 = 0,
    viewport_height: f32 = 0,

    pub fn scroll_to(self: *ScrollHandle, x: f32, y: f32) void {
        std.debug.assert(self.max_offset_x >= 0); // clamp lo=-max must be <= 0
        std.debug.assert(self.max_offset_y >= 0);
        self.offset_x = std.math.clamp(x, -self.max_offset_x, 0);
        self.offset_y = std.math.clamp(y, -self.max_offset_y, 0);
    }

    pub fn scroll_by(self: *ScrollHandle, dx: f32, dy: f32) void {
        self.scroll_to(self.offset_x + dx, self.offset_y + dy);
    }

    pub fn update_layout(
        self: *ScrollHandle,
        viewport_w: f32,
        viewport_h: f32,
        content_w: f32,
        content_h: f32,
    ) void {
        self.viewport_width = viewport_w;
        self.viewport_height = viewport_h;
        self.content_width = content_w;
        self.content_height = content_h;
        self.max_offset_x = @max(0, content_w - viewport_w);
        self.max_offset_y = @max(0, content_h - viewport_h);
        self.offset_x = std.math.clamp(self.offset_x, -self.max_offset_x, 0);
        self.offset_y = std.math.clamp(self.offset_y, -self.max_offset_y, 0);
    }

    pub fn is_scrolled_to_top(self: *const ScrollHandle) bool {
        return self.offset_y >= 0;
    }

    pub fn is_scrolled_to_bottom(self: *const ScrollHandle) bool {
        return self.offset_y <= -self.max_offset_y;
    }

    pub fn can_scroll_x(self: *const ScrollHandle) bool {
        return self.max_offset_x > 0;
    }

    pub fn can_scroll_y(self: *const ScrollHandle) bool {
        return self.max_offset_y > 0;
    }
};

pub const MouseDownHandler = *const fn (*MouseDownEvent, *anyopaque) void;
pub const MouseUpHandler = *const fn (*MouseUpEvent, *anyopaque) void;
pub const MouseMoveHandler = *const fn (*MouseMoveEvent, *anyopaque) void;
pub const HoverHandler = *const fn (hovered: bool, *anyopaque) void;
pub const KeyDownHandler = *const fn (*KeyDownEvent, *anyopaque) void;
pub const KeyUpHandler = *const fn (*KeyUpEvent, *anyopaque) void;

pub const Interactivity = struct {
    on_mouse_down: ?MouseDownHandler = null,
    on_mouse_up: ?MouseUpHandler = null,
    on_mouse_move: ?MouseMoveHandler = null,
    on_hover: ?HoverHandler = null,
    on_key_down: ?KeyDownHandler = null,
    on_key_up: ?KeyUpHandler = null,
    // Caller-owned context handed back to every handler; null means handlers no-op.
    user_data: ?*anyopaque = null,
    focus_handle: ?FocusHandle = null,
    scroll_handle: ?*ScrollHandle = null,

    pub fn has_listeners(self: Interactivity) bool {
        return self.on_mouse_down != null or
            self.on_mouse_up != null or
            self.on_mouse_move != null or
            self.on_hover != null or
            self.on_key_down != null or
            self.on_key_up != null;
    }

    pub fn is_focusable(self: Interactivity) bool {
        return self.focus_handle != null;
    }

    pub fn handle_mouse_down(self: *Interactivity, event: *MouseDownEvent) bool {
        const handler = self.on_mouse_down orelse return false;
        const data = self.user_data orelse return false;
        handler(event, data);
        return true;
    }

    pub fn handle_mouse_up(self: *Interactivity, event: *MouseUpEvent) bool {
        const handler = self.on_mouse_up orelse return false;
        const data = self.user_data orelse return false;
        handler(event, data);
        return true;
    }

    pub fn handle_mouse_move(self: *Interactivity, event: *MouseMoveEvent) bool {
        const handler = self.on_mouse_move orelse return false;
        const data = self.user_data orelse return false;
        handler(event, data);
        return true;
    }

    pub fn handle_hover(self: *Interactivity, hovered: bool) void {
        const handler = self.on_hover orelse return;
        const data = self.user_data orelse return;
        handler(hovered, data);
    }

    pub fn handle_key_down(self: *Interactivity, event: *KeyDownEvent) bool {
        const handler = self.on_key_down orelse return false;
        const data = self.user_data orelse return false;
        handler(event, data);
        return true;
    }

    pub fn handle_key_up(self: *Interactivity, event: *KeyUpEvent) bool {
        const handler = self.on_key_up orelse return false;
        const data = self.user_data orelse return false;
        handler(event, data);
        return true;
    }
};

pub const Hitbox = struct {
    id: HitboxId,
    bounds: Bounds(f32),
    interactivity: *Interactivity,

    pub fn contains_point(self: Hitbox, x: f32, y: f32) bool {
        std.debug.assert(self.bounds.size.width >= 0);
        std.debug.assert(self.bounds.size.height >= 0);
        return x >= self.bounds.origin.x and
            x <= self.bounds.origin.x + self.bounds.size.width and
            y >= self.bounds.origin.y and
            y <= self.bounds.origin.y + self.bounds.size.height;
    }
};

pub const HitTest = struct {
    pub const MAX_HITS = 16;

    ids: [MAX_HITS]HitboxId = undefined,
    len: usize = 0,
    hover_count: usize = 0,

    pub fn append(self: *HitTest, id: HitboxId) void {
        // Bounded by design: 16 hitboxes stacked under one point is already deep;
        // the hit walk only needs the topmost few, so extras are dropped.
        if (self.len < MAX_HITS) {
            self.ids[self.len] = id;
            self.len += 1;
        }
        std.debug.assert(self.len <= MAX_HITS);
    }

    pub fn slice(self: *const HitTest) []const HitboxId {
        return self.ids[0..self.len];
    }

    pub fn contains(self: *const HitTest, id: HitboxId) bool {
        for (self.slice()) |hid| {
            if (hid == id) return true;
        }
        return false;
    }

    pub fn clear(self: *HitTest) void {
        self.len = 0;
        self.hover_count = 0;
    }
};

test "ScrollHandle clamps to range" {
    var h: ScrollHandle = .{ .id = 0 };
    h.update_layout(100, 100, 300, 200);
    try std.testing.expect(h.max_offset_x == 200);
    try std.testing.expect(h.max_offset_y == 100);

    h.scroll_by(-50, -50);
    try std.testing.expect(h.offset_x == -50 and h.offset_y == -50);

    h.scroll_by(-1000, -1000);
    try std.testing.expect(h.offset_x == -200 and h.offset_y == -100);

    h.scroll_by(1000, 1000);
    try std.testing.expect(h.offset_x == 0 and h.offset_y == 0);
}

test "HitTest bounded append + contains" {
    var t: HitTest = .{};
    var i: u32 = 0;
    while (i < HitTest.MAX_HITS + 4) : (i += 1) {
        t.append(i);
    }
    try std.testing.expect(t.len == HitTest.MAX_HITS);
    try std.testing.expect(t.contains(0));
    try std.testing.expect(t.contains(HitTest.MAX_HITS - 1));
    try std.testing.expect(!t.contains(HitTest.MAX_HITS + 1));
}
