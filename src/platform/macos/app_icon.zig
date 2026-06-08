// NSRunningApplication.icon returns nil for non-app processes (daemons,
// CLI tools) - propagated as null for caller fallback.

const std = @import("std");
const objc = @import("objc.zig");
const c = @import("core_text.zig");
const app_icon = @import("../../app_icon.zig");
const text_system = @import("../../text_system.zig");

const Allocator = std.mem.Allocator;
const AppIconParams = app_icon.AppIconParams;
const PlatformAppIcons = app_icon.PlatformAppIcons;
const GlyphBitmap = text_system.GlyphBitmap;

const CGFloat = c.CGFloat;

pub const MacAppIcons = struct {
    allocator: Allocator,
    bake_buffer: std.ArrayListUnmanaged(u8) = .empty,

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        self.bake_buffer.deinit(self.allocator);
    }

    pub fn platform_app_icons(self: *Self) PlatformAppIcons {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn rasterize_impl(ptr: *anyopaque, params: AppIconParams) ?GlyphBitmap {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.rasterize(params);
    }

    const vtable = PlatformAppIcons.VTable{
        .rasterize = rasterize_impl,
    };

    fn rasterize(self: *Self, params: AppIconParams) ?GlyphBitmap {
        const pool = objc.autorelease_pool_push();
        defer objc.autorelease_pool_pop(pool);

        const NSRunningApplication = objc.get_class("NSRunningApplication") orelse return null;
        const running: ?objc.Id = objc.msg_send(
            ?objc.Id,
            NSRunningApplication,
            "runningApplicationWithProcessIdentifier:",
            .{@as(c_int, params.pid)},
        );
        const app = running orelse return null;

        const image: ?objc.Id = objc.msg_send(?objc.Id, app, "icon", .{});
        const img = image orelse return null;

        const px_size_f: f64 = @ceil(@as(f64, params.point_size) * @as(f64, params.scale_factor));
        if (px_size_f <= 0 or px_size_f > 1024) return null;
        const px_size: u32 = @intFromFloat(px_size_f);

        const stride: usize = @as(usize, px_size) * 4;
        const byte_count: usize = stride * @as(usize, px_size);

        self.bake_buffer.clearRetainingCapacity();
        self.bake_buffer.resize(self.allocator, byte_count) catch return null;
        @memset(self.bake_buffer.items, 0);

        const cs = c.CGColorSpaceCreateDeviceRGB();
        defer c.CGColorSpaceRelease(cs);

        const cg_ctx = c.CGBitmapContextCreate(
            self.bake_buffer.items.ptr,
            @intCast(px_size),
            @intCast(px_size),
            8,
            stride,
            cs,
            c.kCGImageAlphaPremultipliedLast | c.kCGBitmapByteOrder32Big,
        ) orelse return null;
        defer c.CGContextRelease(cg_ctx);

        const point_size: objc.NSSize = objc.msg_send(objc.NSSize, img, "size", .{});
        if (point_size.width <= 0 or point_size.height <= 0) return null;

        const draw_w = @as(f64, params.point_size);
        const draw_h = @as(f64, params.point_size);
        const sx: CGFloat = @as(CGFloat, params.scale_factor);
        c.CGContextScaleCTM(cg_ctx, sx, sx);

        var rect = c.CGRect{
            .origin = .{ .x = 0, .y = 0 },
            .size = .{ .width = draw_w, .height = draw_h },
        };
        const cg_image: c.CGImageRef = objc.msg_send(
            c.CGImageRef,
            img,
            "CGImageForProposedRect:context:hints:",
            .{
                &rect,
                @as(?objc.Id, null),
                @as(?objc.Id, null),
            },
        );
        if (cg_image == null) return null;

        c.CGContextDrawImage(cg_ctx, rect, cg_image);

        return .{
            .width = px_size,
            .height = px_size,
            .data = self.bake_buffer.items,
            .is_colored = true,
        };
    }
};
