// The renderer's window accessors for Android, the third arm beside the Linux
// backend's wayland/x11 (vulkan_renderer.zig imports this one when the target
// is Android). The renderer stays backend-neutral; everything Android-specific
// about the surface lives here. The erased `target` is always an
// *AndroidWindow (the renderer holds it as *anyopaque).

const std = @import("std");
const vk = @import("../linux/vulkan.zig");
const native = @import("native.zig");

const AndroidWindow = native.AndroidWindow;

fn win(target: *anyopaque) *AndroidWindow {
    return @ptrCast(@alignCast(target));
}

pub fn window_in_use(target: *anyopaque) bool {
    return win(target).in_use;
}

pub fn window_size_pt(target: *anyopaque) [2]i32 {
    const w = win(target);
    return .{ w.width_pt, w.height_pt };
}

pub fn window_scale(target: *anyopaque) i32 {
    return win(target).scale;
}

// The renderer publishes its caps-derived display extent here so sync_extent drives
// layout from it, not the ANativeWindow whose dims are unreliable under rotation.
pub fn publish_logical_extent(target: *anyopaque, ext: vk.Extent2D) void {
    const w = win(target);
    w.disp_w = @intCast(ext.width);
    w.disp_h = @intCast(ext.height);
}

pub fn renderer_takeover(target: *anyopaque) void {
    const w = win(target);
    std.debug.assert(w.in_use);
    w.renderer_owned = true;
}

// No double-buffered surface scale on Android (the surface is its pixel size),
// so this is the no-op arm the wayland path is not.
pub fn apply_buffer_scale(target: *anyopaque, scale: i32) void {
    std.debug.assert(scale >= 1);
    _ = target;
}

pub fn vk_surface_extension() [*:0]const u8 {
    return "VK_KHR_android_surface";
}

// Build the swapchain surface from the ANativeWindow. The constructor is an
// instance extension fetched by name, the wayland/xcb precedent.
pub fn create_vk_surface(instance: *vk.Instance, target: *anyopaque) ?vk.SurfaceKHR {
    const w = win(target);
    const handle = w.native orelse return null;
    const create: vk.CreateAndroidSurfaceFn = @ptrCast(
        vk.get_instance_proc_addr(instance, "vkCreateAndroidSurfaceKHR") orelse return null,
    );
    const info = vk.AndroidSurfaceCreateInfoKHR{ .window = @ptrCast(handle) };
    var surface: vk.SurfaceKHR = vk.NULL_HANDLE;
    if (create(instance, &info, null, &surface) != vk.SUCCESS) return null;
    return surface;
}
