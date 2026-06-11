// Display-link surface for the facade, the windows/window.zig precedent: the
// types exist so root and the test build compile on Linux. No vsync source
// backs this file - init reports Unsupported, so no paint loop ever starts.

const std = @import("std");

pub const dispatch_function_t = *const fn (?*anyopaque) callconv(.c) void;
pub const CGDirectDisplayID = u32;

pub const Error = error{Unsupported};

pub fn get_main_display_id() CGDirectDisplayID {
    return 0;
}

pub const DisplayLink = struct {
    token: usize = 0,

    pub fn init(
        display_id: CGDirectDisplayID,
        context: ?*anyopaque,
        callback: dispatch_function_t,
    ) Error!DisplayLink {
        std.debug.assert(display_id == 0);
        std.debug.assert(@intFromPtr(callback) != 0);
        _ = context;
        return error.Unsupported;
    }

    pub fn start(self: *DisplayLink) Error!void {
        _ = self;
        return error.Unsupported;
    }

    pub fn stop(self: *DisplayLink) void {
        _ = self;
    }

    pub fn deinit(self: *DisplayLink) void {
        std.debug.assert(self.token == 0);
    }
};
