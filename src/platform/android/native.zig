// The NDK surface vocabulary, hand-declared (the house pattern; @cImport
// chokes on bionic nullability attributes). ANativeWindow is the surface the
// framework hands a NativeActivity; AndroidWindow is the per-window state the
// renderer's backend accessors read - the Android analogue of the wayland/x11
// ShellWindow slab entry.

const std = @import("std");

pub const ANativeWindow = opaque {};

pub extern fn ANativeWindow_getWidth(*ANativeWindow) c_int;
pub extern fn ANativeWindow_getHeight(*ANativeWindow) c_int;

pub const MAX_WINDOWS: u32 = 1; // one fullscreen surface per Activity

pub const AndroidWindow = struct {
    in_use: bool = false,
    native: ?*ANativeWindow = null,
    width_pt: i32 = 0,
    height_pt: i32 = 0,
    scale: i32 = 1,
    renderer_owned: bool = false,
    surface_ctx: ?*anyopaque = null,

    // Refresh the cached point extent from the live surface. Android has no
    // buffer-scale negotiation - the surface simply IS its pixel size - so
    // points equal pixels until the density scale lands with input.
    pub fn sync_extent(self: *AndroidWindow) void {
        const native = self.native orelse return;
        std.debug.assert(self.scale >= 1);
        const w = ANativeWindow_getWidth(native);
        const h = ANativeWindow_getHeight(native);
        self.width_pt = @max(@divTrunc(w, self.scale), 1);
        self.height_pt = @max(@divTrunc(h, self.scale), 1);
    }
};
