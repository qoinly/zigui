// Client-side-decoration geometry shared by the Wayland and X11 arms: which
// caption button a point hits, which resize border it grazes, and the
// desktop's button layout in shell slot order. Pure math over scalars so
// neither arm's window type leaks into the other.

const std = @import("std");
const shell_types = @import("shell_types.zig");
const desktop_theme = @import("desktop_theme.zig");

const CaptionButton = shell_types.CaptionButton;
const CaptionSlots = shell_types.CaptionSlots;
const CAPTION_BTN_W = shell_types.CAPTION_BTN_W;
const CAPTION_CLUSTER_W = shell_types.CAPTION_CLUSTER_W;

pub const RESIZE_BORDER: f32 = 6;

// Slot 0 is the rightmost button, matching the paint layer's centre formula.
pub fn caption_slots() CaptionSlots {
    const layout = desktop_theme.caption_layout();
    std.debug.assert(layout.count >= 1);
    std.debug.assert(layout.count <= 3);
    var out = CaptionSlots{ .kinds = .{ .none, .none, .none }, .count = layout.count };
    var i: u8 = 0;
    while (i < layout.count) : (i += 1) {
        out.kinds[i] = switch (layout.kinds[layout.count - 1 - i]) {
            .minimize => .minimize,
            .maximize => .maximize,
            .close => .close,
        };
    }
    return out;
}

pub fn caption_button_at(width_pt: f32, titlebar_h: f32, x: f32, y: f32) CaptionButton {
    std.debug.assert(width_pt > 0);
    std.debug.assert(titlebar_h > 0);
    if (y < 0 or y >= titlebar_h) return .none;
    // Slots end right_margin short of the edge, mirroring the paint layer's
    // centre formula; the margin itself stays draggable band.
    const right = width_pt - (CAPTION_CLUSTER_W - CAPTION_BTN_W * 3);
    // Inclusive lower edge: the exact left-boundary pixel is representable
    // in wl_fixed and must land in the outermost slot, not past it.
    if (x >= right or x <= right - CAPTION_BTN_W * 3) return .none;
    const slot: u8 = @intFromFloat((right - x) / CAPTION_BTN_W);
    std.debug.assert(slot < 3);
    const slots = caption_slots();
    if (slot >= slots.count) return .none;
    return slots.kinds[slot];
}

// xdg resize-edge codes: top=1 bottom=2 left=4 right=8, corners are their OR.
// The X11 arm maps these onto _NET_WM_MOVERESIZE directions at the call site.
pub fn resize_edge_at(width_pt: f32, height_pt: f32, immobile: bool, x: f32, y: f32) u32 {
    std.debug.assert(width_pt > 0);
    std.debug.assert(height_pt > 0);
    if (immobile) return 0;
    var edge: u32 = 0;
    if (y < RESIZE_BORDER) edge |= 1;
    if (y >= height_pt - RESIZE_BORDER) edge |= 2;
    if (x < RESIZE_BORDER) edge |= 4;
    if (x >= width_pt - RESIZE_BORDER) edge |= 8;
    // A window thinner than two borders satisfies opposite edges at once; the
    // min-size floor prevents it, but a protocol value past 10 must never ship.
    if (edge & 3 == 3 or edge & 12 == 12) return 0;
    std.debug.assert(edge <= 10);
    return edge;
}
