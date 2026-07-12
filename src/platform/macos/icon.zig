const std = @import("std");
const objc = @import("objc.zig");
const c = @import("core_text.zig");
const icon_system = @import("../../icon.zig");
const text_system = @import("../../text_system.zig");

const Allocator = std.mem.Allocator;
const IconParams = icon_system.IconParams;
const IconWeight = icon_system.IconWeight;
const Icon = icon_system.Icon;
const PlatformIconSystem = icon_system.PlatformIconSystem;
const GlyphBitmap = text_system.GlyphBitmap;

const NSRect = objc.NSRect;
const CGFloat = c.CGFloat;

pub const MacIconSystem = struct {
    allocator: Allocator,
    bitmap_buffer: std.ArrayListUnmanaged(u8) = .empty,

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        self.bitmap_buffer.deinit(self.allocator);
    }

    pub fn platform_icon_system(self: *Self) PlatformIconSystem {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn name_for(self: *Self, ic: Icon) []const u8 {
        _ = self;
        return sf_name(ic);
    }

    // The SF Symbol name for an Icon, callable without an instance (the native
    // toolbar / sidebar paths resolve symbols straight from the enum).
    pub fn sf_name(ic: Icon) []const u8 {
        return switch (ic) {
            .close => "xmark",
            .close_circle => "xmark.circle",
            .close_circle_fill => "xmark.circle.fill",
            .check => "checkmark",
            .check_circle => "checkmark.circle",
            .check_circle_fill => "checkmark.circle.fill",
            .plus => "plus",
            .plus_square => "plus.square",
            .minus => "minus",
            .chevron_up => "chevron.up",
            .chevron_down => "chevron.down",
            .chevron_left => "chevron.left",
            .chevron_right => "chevron.right",
            .chevron_up_down => "chevron.up.chevron.down",
            .arrow_right => "arrow.right",
            .arrow_clockwise => "arrow.clockwise",
            .arrow_down_circle => "arrow.down.circle",
            .arrow_down_to_line => "arrow.down.to.line",
            .search => "magnifyingglass",
            .sidebar => "sidebar.left",
            .gear => "gearshape",
            .gear_fill => "gearshape.fill",
            .info => "info.circle",
            .warning => "exclamationmark.triangle",
            .bold => "bold",
            .italic => "italic",
            .underline => "underline",
            .align_left => "text.alignleft",
            .align_center => "text.aligncenter",
            .align_right => "text.alignright",
            .share => "square.and.arrow.up",
            .save => "square.and.arrow.down",
            .copy => "square.on.square",
            .grid => "square.grid.2x2",
            .layout_grid => "square.grid.3x3",
            .bell => "bell.fill",
            .bell_badge => "bell.badge",
            .pin => "pin.fill",
            .eye => "eye",
            .eye_slash => "eye.slash",
            .calendar => "calendar",
            .folder => "folder",
            .trash => "trash",
            .doc => "doc.text",
            .envelope => "envelope",
            .message => "message",
            .person => "person",
            .people => "person.2",
            .people_fill => "person.2.fill",
            .creditcard => "creditcard",
            .creditcard_fill => "creditcard.fill",
            .heart => "heart.fill",
            .moon => "moon",
            .sun => "sun.max",
            .chart_bar => "chart.bar",
            .dollar_sign => "dollarsign",
            .bolt => "bolt.fill",
            .archive => "archivebox",
            .battery => "battery.100",
            .cpu => "cpu",
            .wifi => "wifi",
            .hard_drive => "internaldrive",
            .package => "shippingbox",
            .wrench => "wrench.and.screwdriver",
            .ellipsis => "ellipsis",
            .pencil => "pencil",
            .star => "star",
            .corner_down_left => "arrow.turn.down.left",
        };
    }

    fn rasterize_impl(ptr: *anyopaque, params: IconParams) ?GlyphBitmap {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.rasterize(params);
    }

    const vtable = PlatformIconSystem.VTable{
        .rasterize = rasterize_impl,
    };

    fn rasterize(self: *Self, params: IconParams) ?GlyphBitmap {
        const pool = objc.autorelease_pool_push();
        defer objc.autorelease_pool_pop(pool);

        const NSImage = objc.get_class("NSImage") orelse return null;
        const NSImageSymbolConfiguration =
            objc.get_class("NSImageSymbolConfiguration") orelse return null;

        const cf_name = c.CFStringCreateWithBytes(
            null,
            params.name.ptr,
            @intCast(params.name.len),
            c.kCFStringEncodingUTF8,
            0,
        ) orelse return null;
        defer c.CFRelease(cf_name);

        const image: ?objc.Id = objc.msg_send(
            ?objc.Id,
            NSImage,
            "imageWithSystemSymbolName:accessibilityDescription:",
            .{
                @as(?*anyopaque, @ptrCast(@constCast(cf_name))),
                @as(?objc.Id, null),
            },
        );
        const img = image orelse return null;

        const config: ?objc.Id = objc.msg_send(
            ?objc.Id,
            NSImageSymbolConfiguration,
            "configurationWithPointSize:weight:scale:",
            .{
                @as(CGFloat, params.point_size),
                @as(CGFloat, weight_to_ns_font_weight(params.weight)),
                @as(objc.NSInteger, @intCast(@intFromEnum(params.scale))),
            },
        );
        const cfg = config orelse return null;

        // AppKit selector; UIKit's is imageByApplyingSymbolConfiguration:.
        const configured: ?objc.Id =
            objc.msg_send(?objc.Id, img, "imageWithSymbolConfiguration:", .{cfg});
        const final = configured orelse img;

        const point_size: objc.NSSize = objc.msg_send(objc.NSSize, final, "size", .{});
        if (point_size.width <= 0 or point_size.height <= 0) return null;

        const px_w_f: f64 = @ceil(point_size.width * params.scale_factor);
        const px_h_f: f64 = @ceil(point_size.height * params.scale_factor);
        if (px_w_f <= 0 or px_h_f <= 0) return null;

        const px_w: u32 = @intFromFloat(px_w_f);
        const px_h: u32 = @intFromFloat(px_h_f);
        const byte_count: usize = @as(usize, px_w) * @as(usize, px_h);

        self.bitmap_buffer.clearRetainingCapacity();
        self.bitmap_buffer.resize(self.allocator, byte_count) catch return null;
        @memset(self.bitmap_buffer.items, 0);

        const cg_ctx = c.CGBitmapContextCreate(
            self.bitmap_buffer.items.ptr,
            @intCast(px_w),
            @intCast(px_h),
            8,
            @intCast(px_w),
            null,
            c.kCGImageAlphaOnly,
        ) orelse return null;
        defer c.CGContextRelease(cg_ctx);

        c.CGContextSetShouldAntialias(cg_ctx, 1);
        c.CGContextSetAllowsAntialiasing(cg_ctx, 1);
        c.CGContextScaleCTM(cg_ctx, params.scale_factor, params.scale_factor);

        var rect = c.CGRect{
            .origin = .{ .x = 0, .y = 0 },
            .size = .{ .width = point_size.width, .height = point_size.height },
        };
        const cg_image: c.CGImageRef = objc.msg_send(
            c.CGImageRef,
            final,
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
            .width = px_w,
            .height = px_h,
            .data = self.bitmap_buffer.items,
            .is_colored = false,
        };
    }
};

// NSFont.Weight is CGFloat, NOT NSInteger - passing an int crashes.
// Values mirror AppKit's NSFontWeight globals.
fn weight_to_ns_font_weight(weight: IconWeight) CGFloat {
    return switch (weight) {
        .ultra_light => -0.8,
        .thin => -0.6,
        .light => -0.4,
        .regular => 0.0,
        .medium => 0.23,
        .semi_bold => 0.3,
        .bold => 0.4,
        .heavy => 0.56,
        .black => 0.62,
    };
}
