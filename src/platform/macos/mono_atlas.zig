const std = @import("std");
const objc = @import("objc.zig");
const metal = @import("metal.zig");
const text_system = @import("../../text_system.zig");
const geometry = @import("../../geometry.zig");

const Allocator = std.mem.Allocator;
const GlyphBitmap = text_system.GlyphBitmap;
const AtlasTile = text_system.AtlasTile;

const Id = objc.Id;
const NSUInteger = objc.NSUInteger;

pub const MTLPixelFormat = struct {
    pub const R8Unorm: NSUInteger = 10;
    pub const RGBA8Unorm: NSUInteger = 70;
};

pub const MTLTextureUsage = struct {
    pub const ShaderRead: NSUInteger = 0x0001;
};

pub const MTLStorageMode = struct {
    pub const Managed: NSUInteger = 1;
};

const MTLRegion = extern struct {
    origin: extern struct { x: NSUInteger, y: NSUInteger, z: NSUInteger },
    size: extern struct { width: NSUInteger, height: NSUInteger, depth: NSUInteger },
};

pub fn MetalAtlas(comptime fmt: NSUInteger, comptime bpp: u32) type {
    return struct {
        allocator: Allocator,
        device: Id,

        texture: ?Id = null,
        size: u32 = INITIAL_SIZE,
        cur_x: u32 = 0,
        cur_y: u32 = 0,
        row_height: u32 = 0,

        tiles: std.AutoHashMapUnmanaged(u64, AtlasTile) = .empty,

        pub const INITIAL_SIZE: u32 = 1024;
        pub const PIXEL_FORMAT: NSUInteger = fmt;
        pub const BYTES_PER_PIXEL: u32 = bpp;

        const Self = @This();

        pub fn init(allocator: Allocator, device: *anyopaque) Self {
            return .{
                .allocator = allocator,
                .device = metal.Renderer.device_from_opaque(device),
            };
        }

        pub fn deinit(self: *Self) void {
            self.tiles.deinit(self.allocator);
        }

        pub fn get(self: *Self, key: u64) ?AtlasTile {
            return self.tiles.get(key);
        }

        pub fn get_or_insert(
            self: *Self,
            key: u64,
            bitmap: ?GlyphBitmap,
            raster_origin: geometry.Point(i32),
        ) ?AtlasTile {
            if (self.tiles.get(key)) |tile| return tile;

            const bmp = bitmap orelse return null;
            if (bmp.width == 0 or bmp.height == 0) return null;
            // bpp fixes this atlas's stride; a mismatched payload corrupts the upload math.
            if (bpp == 1 and bmp.is_colored) return null;
            if (bpp != 1 and !bmp.is_colored) return null;

            const padding: u32 = 1;
            const padded_width = bmp.width + padding;
            const padded_height = bmp.height + padding;

            if (self.cur_x + padded_width > self.size) {
                self.cur_x = 0;
                self.cur_y += self.row_height;
                self.row_height = 0;
            }
            if (self.cur_y + padded_height > self.size) return null;

            self.ensure_texture();

            const tile = AtlasTile{
                .texture_id = 0,
                .bounds = geometry.Bounds(u32).init(self.cur_x, self.cur_y, bmp.width, bmp.height),
                .raster_origin = raster_origin,
                .is_colored = bpp != 1,
            };

            self.upload_region(tile.bounds, bmp);

            self.cur_x += padded_width;
            self.row_height = @max(self.row_height, padded_height);

            self.tiles.put(self.allocator, key, tile) catch return null;
            return tile;
        }

        fn ensure_texture(self: *Self) void {
            if (self.texture != null) return;

            const MTLTextureDescriptor = objc.get_class("MTLTextureDescriptor") orelse return;

            const desc_selector = "texture2DDescriptorWithPixelFormat:width:height:mipmapped:";
            const desc = objc.msg_send(Id, MTLTextureDescriptor, desc_selector, .{
                fmt,
                @as(NSUInteger, self.size),
                @as(NSUInteger, self.size),
                objc.NO,
            });

            objc.msg_send(void, desc, "setUsage:", .{MTLTextureUsage.ShaderRead});
            objc.msg_send(void, desc, "setStorageMode:", .{MTLStorageMode.Managed});

            self.texture = objc.msg_send(?Id, self.device, "newTextureWithDescriptor:", .{desc});
        }

        fn upload_region(self: *Self, bounds: geometry.Bounds(u32), bitmap: GlyphBitmap) void {
            const tex = self.texture orelse return;

            const region = MTLRegion{
                .origin = .{ .x = bounds.origin.x, .y = bounds.origin.y, .z = 0 },
                .size = .{ .width = bitmap.width, .height = bitmap.height, .depth = 1 },
            };

            objc.msg_send(void, tex, "replaceRegion:mipmapLevel:withBytes:bytesPerRow:", .{
                region,
                @as(NSUInteger, 0),
                @as(*const anyopaque, bitmap.data.ptr),
                @as(NSUInteger, bitmap.width * bpp),
            });
        }

        pub fn get_texture(self: *Self) ?*anyopaque {
            if (self.texture) |tex| return @ptrCast(tex);
            return null;
        }

        pub fn get_texture_size(self: *Self) u32 {
            return self.size;
        }
    };
}

pub const MetalMonoAtlas = MetalAtlas(MTLPixelFormat.R8Unorm, 1);
pub const MetalColorAtlas = MetalAtlas(MTLPixelFormat.RGBA8Unorm, 4);
