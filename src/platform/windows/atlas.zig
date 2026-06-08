// D3D11 glyph/icon atlas, the MetalAtlas analogue. One texture so every glyph
// draws from a single SRV bind (no per-glyph resource churn); a shelf allocator
// packs tiles since glyphs are added once and never freed.

const std = @import("std");
const win32 = @import("win32.zig");
const d3d11 = @import("d3d11.zig");
const dxgi = @import("dxgi.zig");
const com = @import("com.zig");
const text_system = @import("../../text_system.zig");
const geometry = @import("../../geometry.zig");

const Allocator = std.mem.Allocator;
const GlyphBitmap = text_system.GlyphBitmap;
const AtlasTile = text_system.AtlasTile;

pub fn WinAtlas(comptime format: u32, comptime bpp: u32) type {
    return struct {
        allocator: Allocator,
        device: *d3d11.ID3D11Device,
        context: *d3d11.ID3D11DeviceContext,

        // COM interfaces held opaque (released generically via com.release, never
        // re-cast): texture is ID3D11Texture2D, srv is ID3D11ShaderResourceView.
        texture: ?*anyopaque = null,
        srv: ?*anyopaque = null,
        size: u32 = INITIAL_SIZE,
        cur_x: u32 = 0,
        cur_y: u32 = 0,
        row_height: u32 = 0,

        tiles: std.AutoHashMapUnmanaged(u64, AtlasTile) = .empty,

        pub const INITIAL_SIZE: u32 = 1024;
        pub const BYTES_PER_PIXEL: u32 = bpp;

        const Self = @This();

        pub fn init(allocator: Allocator, device: *anyopaque) Self {
            const dev: *d3d11.ID3D11Device = @ptrCast(@alignCast(device));
            // D3D11: a live device always hands back its immediate context.
            const ctx = dev.get_immediate_context() orelse unreachable;
            return .{ .allocator = allocator, .device = dev, .context = ctx };
        }

        pub fn deinit(self: *Self) void {
            self.tiles.deinit(self.allocator);
            com.release(&self.srv);
            com.release(&self.texture);
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

            const desc = d3d11.D3D11_TEXTURE2D_DESC{
                .Width = self.size,
                .Height = self.size,
                .MipLevels = 1,
                .ArraySize = 1,
                .Format = format,
                .SampleDesc = .{ .Count = 1, .Quality = 0 },
                .Usage = d3d11.D3D11_USAGE_DEFAULT,
                .BindFlags = d3d11.D3D11_BIND_SHADER_RESOURCE,
                .CPUAccessFlags = 0,
                .MiscFlags = 0,
            };
            var tex: ?*anyopaque = null;
            if (com.failed(self.device.create_texture2d(&desc, null, &tex))) return;

            // Commit both only on full success; an SRV failure must not leave a
            // texture with no view (a permanent half-init that never retries).
            var srv: ?*anyopaque = null;
            if (com.failed(self.device.create_srv(tex.?, null, &srv))) {
                com.release(&tex);
                return;
            }
            self.texture = tex;
            self.srv = srv;
        }

        fn upload_region(self: *Self, bounds: geometry.Bounds(u32), bitmap: GlyphBitmap) void {
            const tex = self.texture orelse return;
            std.debug.assert(bitmap.width == bounds.size.width);
            std.debug.assert(bitmap.height == bounds.size.height);
            std.debug.assert(bitmap.data.len >= @as(usize, bitmap.width) * bitmap.height * bpp);

            const box = d3d11.D3D11_BOX{
                .left = bounds.origin.x,
                .top = bounds.origin.y,
                .front = 0,
                .right = bounds.origin.x + bitmap.width,
                .bottom = bounds.origin.y + bitmap.height,
                .back = 1,
            };
            self.context.update_subresource(tex, 0, &box, bitmap.data.ptr, bitmap.width * bpp, 0);
        }

        pub fn get_texture(self: *Self) ?*anyopaque {
            return self.srv;
        }

        pub fn get_texture_size(self: *Self) u32 {
            return self.size;
        }
    };
}

pub const WinMonoAtlas = WinAtlas(dxgi.DXGI_FORMAT_R8_UNORM, 1);
pub const WinColorAtlas = WinAtlas(dxgi.DXGI_FORMAT_R8G8B8A8_UNORM, 4);
