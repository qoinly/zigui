// Vulkan glyph/icon atlas (the WinAtlas analogue): one device-local image,
// shelf-packed, filled through a persistently mapped staging buffer with a
// synchronous one-shot copy per NEW glyph - a cold path; hits come from the
// tiles map. The `device` handed to init is the renderer's DeviceContext
// (what get_device() returns on this backend), not a bare VkDevice.

const std = @import("std");
const ts = @import("../../text_system.zig");
const geometry = @import("../../geometry.zig");
const vk = @import("vulkan.zig");
const renderer = @import("vulkan_renderer.zig");

const Allocator = std.mem.Allocator;
const GlyphBitmap = ts.GlyphBitmap;
const AtlasTile = ts.AtlasTile;

pub fn LinuxAtlas(comptime format: u32, comptime bpp: u32) type {
    return struct {
        allocator: Allocator,
        ctx: *renderer.DeviceContext,

        image: vk.Image = vk.NULL_HANDLE,
        memory: vk.DeviceMemory = vk.NULL_HANDLE,
        view: vk.ImageView = vk.NULL_HANDLE,
        staging: vk.Buffer = vk.NULL_HANDLE,
        staging_memory: vk.DeviceMemory = vk.NULL_HANDLE,
        staging_mapped: ?[*]u8 = null,
        layout_initialized: bool = false,

        size: u32 = INITIAL_SIZE,
        cur_x: u32 = 0,
        cur_y: u32 = 0,
        row_height: u32 = 0,

        tiles: std.AutoHashMapUnmanaged(u64, AtlasTile) = .empty,

        pub const INITIAL_SIZE: u32 = 1024;
        pub const BYTES_PER_PIXEL: u32 = bpp;
        // Staging covers the whole atlas (1MiB mono / 4MiB color of VIRTUAL
        // host-visible memory, mapped once); any glyph that fits the atlas
        // fits the staging buffer by construction.
        const STAGING_BYTES: usize = @as(usize, INITIAL_SIZE) * INITIAL_SIZE * bpp;

        const Self = @This();

        pub fn init(allocator: Allocator, device: *anyopaque) Self {
            comptime std.debug.assert(bpp == 1 or bpp == 4);
            std.debug.assert(@intFromPtr(device) != 0);
            const ctx: *renderer.DeviceContext = @ptrCast(@alignCast(device));
            return .{ .allocator = allocator, .ctx = ctx };
        }

        pub fn deinit(self: *Self) void {
            self.tiles.deinit(self.allocator);
            const ctx = self.ctx;
            _ = ctx.dfns.vkDeviceWaitIdle(ctx.device);
            if (self.view != vk.NULL_HANDLE)
                ctx.dfns.vkDestroyImageView(ctx.device, self.view, null);
            if (self.image != vk.NULL_HANDLE)
                ctx.dfns.vkDestroyImage(ctx.device, self.image, null);
            if (self.memory != vk.NULL_HANDLE)
                ctx.dfns.vkFreeMemory(ctx.device, self.memory, null);
            if (self.staging != vk.NULL_HANDLE)
                ctx.dfns.vkDestroyBuffer(ctx.device, self.staging, null);
            if (self.staging_memory != vk.NULL_HANDLE)
                ctx.dfns.vkFreeMemory(ctx.device, self.staging_memory, null);
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
            if (self.image == vk.NULL_HANDLE) return null;

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
            if (self.image != vk.NULL_HANDLE) return;
            const ctx = self.ctx;
            const info = vk.ImageCreateInfo{
                .format = format,
                .extent = .{ .width = self.size, .height = self.size, .depth = 1 },
            };
            if (ctx.dfns.vkCreateImage(ctx.device, &info, null, &self.image) != vk.SUCCESS) return;

            var requirements: vk.MemoryRequirements = undefined;
            ctx.dfns.vkGetImageMemoryRequirements(ctx.device, self.image, &requirements);
            const type_index = ctx.find_memory_type(
                requirements.memory_type_bits,
                vk.MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
            ) orelse return self.release_half_init();
            const alloc = vk.MemoryAllocateInfo{
                .allocation_size = requirements.size,
                .memory_type_index = type_index,
            };
            if (ctx.dfns.vkAllocateMemory(ctx.device, &alloc, null, &self.memory) != vk.SUCCESS)
                return self.release_half_init();
            if (ctx.dfns.vkBindImageMemory(ctx.device, self.image, self.memory, 0) != vk.SUCCESS)
                return self.release_half_init();

            const view_info = vk.ImageViewCreateInfo{ .image = self.image, .format = format };
            if (ctx.dfns.vkCreateImageView(ctx.device, &view_info, null, &self.view) != vk.SUCCESS)
                return self.release_half_init();

            if (!self.create_staging()) return self.release_half_init();
        }

        // Commit nothing on failure: a permanent half-init would never retry.
        fn release_half_init(self: *Self) void {
            const ctx = self.ctx;
            if (self.view != vk.NULL_HANDLE)
                ctx.dfns.vkDestroyImageView(ctx.device, self.view, null);
            if (self.image != vk.NULL_HANDLE)
                ctx.dfns.vkDestroyImage(ctx.device, self.image, null);
            if (self.memory != vk.NULL_HANDLE)
                ctx.dfns.vkFreeMemory(ctx.device, self.memory, null);
            self.view = vk.NULL_HANDLE;
            self.image = vk.NULL_HANDLE;
            self.memory = vk.NULL_HANDLE;
        }

        fn create_staging(self: *Self) bool {
            const ctx = self.ctx;
            std.debug.assert(self.staging == vk.NULL_HANDLE);
            const info = vk.BufferCreateInfo{
                .size = STAGING_BYTES,
                .usage = vk.BUFFER_USAGE_TRANSFER_SRC_BIT,
            };
            if (ctx.dfns.vkCreateBuffer(ctx.device, &info, null, &self.staging) != vk.SUCCESS)
                return false;
            var requirements: vk.MemoryRequirements = undefined;
            ctx.dfns.vkGetBufferMemoryRequirements(ctx.device, self.staging, &requirements);
            const wanted =
                vk.MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.MEMORY_PROPERTY_HOST_COHERENT_BIT;
            const type_index = ctx.find_memory_type(requirements.memory_type_bits, wanted) orelse
                return false;
            const alloc = vk.MemoryAllocateInfo{
                .allocation_size = requirements.size,
                .memory_type_index = type_index,
            };
            const dev = ctx.device;
            if (ctx.dfns.vkAllocateMemory(dev, &alloc, null, &self.staging_memory) != vk.SUCCESS)
                return false;
            const bind_rc = ctx.dfns.vkBindBufferMemory(dev, self.staging, self.staging_memory, 0);
            if (bind_rc != vk.SUCCESS) return false;
            var mapped: *anyopaque = undefined;
            if (ctx.dfns.vkMapMemory(dev, self.staging_memory, 0, STAGING_BYTES, 0, &mapped) !=
                vk.SUCCESS) return false;
            self.staging_mapped = @ptrCast(@alignCast(mapped));
            return true;
        }

        fn upload_region(self: *Self, bounds: geometry.Bounds(u32), bitmap: GlyphBitmap) void {
            const ctx = self.ctx;
            const dst = self.staging_mapped orelse return;
            std.debug.assert(bitmap.width == bounds.size.width);
            std.debug.assert(bitmap.height == bounds.size.height);
            const byte_count = @as(usize, bitmap.width) * bitmap.height * bpp;
            std.debug.assert(bitmap.data.len >= byte_count);
            std.debug.assert(byte_count <= STAGING_BYTES);
            @memcpy(dst[0..byte_count], bitmap.data[0..byte_count]);

            const cmd = ctx.upload_cmd;
            _ = ctx.dfns.vkResetCommandBuffer(cmd, 0);
            const begin = vk.CommandBufferBeginInfo{};
            _ = ctx.dfns.vkBeginCommandBuffer(cmd, &begin);
            self.barrier(cmd, true);
            const copy = vk.BufferImageCopy{
                .image_offset = .{
                    .x = @intCast(bounds.origin.x),
                    .y = @intCast(bounds.origin.y),
                },
                .image_extent = .{ .width = bitmap.width, .height = bitmap.height, .depth = 1 },
            };
            ctx.dfns.vkCmdCopyBufferToImage(
                cmd,
                self.staging,
                self.image,
                vk.IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                1,
                @ptrCast(&copy),
            );
            self.barrier(cmd, false);
            _ = ctx.dfns.vkEndCommandBuffer(cmd);

            const submit = vk.SubmitInfo{ .command_buffers = @ptrCast(&ctx.upload_cmd) };
            // Synchronous wait: acceptable because this runs once per new glyph,
            // never per frame; hits come straight from the tiles map.
            if (ctx.dfns.vkQueueSubmit(ctx.queue, 1, @ptrCast(&submit), vk.NULL_HANDLE) ==
                vk.SUCCESS)
            {
                _ = ctx.dfns.vkQueueWaitIdle(ctx.queue);
            }
            self.layout_initialized = true;
        }

        fn barrier(self: *Self, cmd: *vk.CommandBuffer, to_transfer: bool) void {
            std.debug.assert(self.image != vk.NULL_HANDLE);
            const old_layout: u32 = if (!to_transfer)
                vk.IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL
            else if (self.layout_initialized)
                vk.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
            else
                vk.IMAGE_LAYOUT_UNDEFINED;
            const transfer_stage = vk.PIPELINE_STAGE_TRANSFER_BIT;
            const b = vk.ImageMemoryBarrier{
                .src_access_mask = if (to_transfer) 0 else vk.ACCESS_TRANSFER_WRITE_BIT,
                .dst_access_mask = if (to_transfer)
                    vk.ACCESS_TRANSFER_WRITE_BIT
                else
                    vk.ACCESS_SHADER_READ_BIT,
                .old_layout = old_layout,
                .new_layout = if (to_transfer)
                    vk.IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL
                else
                    vk.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                .image = self.image,
            };
            const src_stage = if (to_transfer)
                vk.PIPELINE_STAGE_TOP_OF_PIPE_BIT | vk.PIPELINE_STAGE_FRAGMENT_SHADER_BIT
            else
                transfer_stage;
            const dst_stage = if (to_transfer)
                transfer_stage
            else
                vk.PIPELINE_STAGE_FRAGMENT_SHADER_BIT;
            const dfns = self.ctx.dfns;
            const one: [*]const vk.ImageMemoryBarrier = @ptrCast(&b);
            dfns.vkCmdPipelineBarrier(cmd, src_stage, dst_stage, 0, 0, null, 0, null, 1, one);
        }

        // The renderer reads the VkImageView through this stable pointer; null
        // until the first glyph creates the texture.
        pub fn get_texture(self: *Self) ?*anyopaque {
            if (self.view == vk.NULL_HANDLE) return null;
            return @ptrCast(&self.view);
        }

        pub fn get_texture_size(self: *Self) u32 {
            std.debug.assert(self.size > 0);
            return self.size;
        }
    };
}

pub const LinuxMonoAtlas = LinuxAtlas(vk.FORMAT_R8_UNORM, 1);
pub const LinuxColorAtlas = LinuxAtlas(vk.FORMAT_R8G8B8A8_UNORM, 4);
