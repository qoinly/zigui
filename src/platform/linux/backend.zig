// The one runtime fork on Linux: Wayland when a compositor answers, X11
// otherwise (the GDK/winit convention). Resolved once at App.init; the
// cross-platform facade stays comptime and custom_shell.zig branches here
// per operation - one predictable branch per event, never per pixel.

const std = @import("std");
const vk = @import("vulkan.zig");
const wl = @import("wayland.zig");
const xcb = @import("xcb.zig");
const wayland_shell = @import("wayland_shell.zig");
const x11_shell = @import("x11_shell.zig");
const shell_types = @import("shell_types.zig");

pub const Kind = enum { wayland, x11 };

pub var active: Kind = .wayland;

pub fn resolve() shell_types.Error!void {
    if (wl.connect()) {
        active = .wayland;
        return;
    } else |_| {}
    xcb.connect() catch return error.ConnectFailed;
    active = .x11;
}

// ---- the renderer's window accessors (it must not import either shell:
// the window behind metal_layer is whichever backend opened it) ----

fn wl_win(target: *anyopaque) *wayland_shell.ShellWindow {
    std.debug.assert(active == .wayland);
    return @ptrCast(@alignCast(target));
}

fn x11_win(target: *anyopaque) *x11_shell.X11Window {
    std.debug.assert(active == .x11);
    return @ptrCast(@alignCast(target));
}

pub fn window_in_use(target: *anyopaque) bool {
    return switch (active) {
        .wayland => wl_win(target).in_use,
        .x11 => x11_win(target).in_use,
    };
}

pub fn window_size_pt(target: *anyopaque) [2]i32 {
    return switch (active) {
        .wayland => .{ wl_win(target).width_pt, wl_win(target).height_pt },
        .x11 => .{ x11_win(target).width_pt, x11_win(target).height_pt },
    };
}

pub fn window_scale(target: *anyopaque) i32 {
    return switch (active) {
        .wayland => wl_win(target).scale,
        .x11 => x11_win(target).scale,
    };
}

// Desktop surfaces never rotate, so the renderer's display extent already equals
// its layout size; the Android arm caches it, this one has nothing to publish.
pub fn publish_logical_extent(_: *anyopaque, _: vk.Extent2D) void {}

pub fn renderer_takeover(target: *anyopaque) void {
    switch (active) {
        .wayland => wayland_shell.renderer_takeover(wl_win(target)),
        .x11 => x11_shell.renderer_takeover(x11_win(target)),
    }
}

// Declares the buffer scale on the surface; X11 has no such double-buffered
// state (the buffer simply IS its pixel size), so only Wayland acts.
pub fn apply_buffer_scale(target: *anyopaque, scale: i32) void {
    std.debug.assert(scale >= 1);
    switch (active) {
        .wayland => wl.surface_set_buffer_scale(wl_win(target).surface.?, scale),
        .x11 => {},
    }
}

pub fn vk_surface_extension() [*:0]const u8 {
    return switch (active) {
        .wayland => "VK_KHR_wayland_surface",
        .x11 => "VK_KHR_xcb_surface",
    };
}

pub const WaylandTarget = struct { display: *anyopaque, surface: *anyopaque };
pub const XcbTarget = struct { connection: *anyopaque, window: u32 };

pub fn wayland_target(target: *anyopaque) ?WaylandTarget {
    const win = wl_win(target);
    const display = wl.conn.display orelse return null;
    const surface = win.surface orelse return null;
    return .{ .display = @ptrCast(display), .surface = @ptrCast(surface) };
}

pub fn xcb_target(target: *anyopaque) ?XcbTarget {
    const win = x11_win(target);
    const connection = xcb.conn orelse return null;
    if (win.window == 0) return null;
    return .{ .connection = @ptrCast(connection), .window = win.window };
}

// Build the window-system VkSurfaceKHR for the active arm. The constructors
// are backend-specific instance extensions, fetched by name (they cannot live
// in the strict InstanceFns table - loading the inactive one would fail).
pub fn create_vk_surface(instance: *vk.Instance, target: *anyopaque) ?vk.SurfaceKHR {
    var surface: vk.SurfaceKHR = vk.NULL_HANDLE;
    switch (active) {
        .wayland => {
            const t = wayland_target(target) orelse return null;
            const create: vk.CreateWaylandSurfaceFn = @ptrCast(
                vk.get_instance_proc_addr(instance, "vkCreateWaylandSurfaceKHR") orelse return null,
            );
            const info = vk.WaylandSurfaceCreateInfoKHR{
                .display = t.display,
                .surface = t.surface,
            };
            if (create(instance, &info, null, &surface) != vk.SUCCESS) return null;
        },
        .x11 => {
            const t = xcb_target(target) orelse return null;
            const create: vk.CreateXcbSurfaceFn = @ptrCast(
                vk.get_instance_proc_addr(instance, "vkCreateXcbSurfaceKHR") orelse return null,
            );
            const info = vk.XcbSurfaceCreateInfoKHR{
                .connection = t.connection,
                .window = t.window,
            };
            if (create(instance, &info, null, &surface) != vk.SUCCESS) return null;
        },
    }
    return surface;
}
