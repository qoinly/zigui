const std = @import("std");
const builtin = @import("builtin");
const primitives = @import("primitives.zig");
const text_system = @import("text_system.zig");

const Allocator = std.mem.Allocator;
const PolychromeSprite = primitives.PolychromeSprite;
const AtlasTile = text_system.AtlasTile;

pub const ColorAtlas = switch (builtin.os.tag) {
    .macos => @import("platform/macos/mono_atlas.zig").MetalColorAtlas,
    .windows => @import("platform/windows/atlas.zig").WinColorAtlas,
    else => @compileError("zigui: AppIconResolver requires macOS or Windows"),
};

pub const AppIconParams = struct {
    pid: i32,
    point_size: f32,
    scale_factor: f32 = 2.0,
};

const IconKey = struct {
    pid: i32,
    point_size_bits: u32,
    scale_bits: u32,

    fn from_params(p: AppIconParams) IconKey {
        return .{
            .pid = p.pid,
            .point_size_bits = @bitCast(p.point_size),
            .scale_bits = @bitCast(p.scale_factor),
        };
    }

    // Seed 2 = app-icon domain (glyphs use 0, SF Symbols 1) so keys don't
    // collide in the shared key space across atlases.
    fn hash(self: IconKey) u64 {
        return std.hash.Wyhash.hash(2, std.mem.asBytes(&self));
    }
};

pub const PlatformAppIcons = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        rasterize: *const fn (ptr: *anyopaque, params: AppIconParams) ?text_system.GlyphBitmap,
    };

    pub fn rasterize(self: PlatformAppIcons, params: AppIconParams) ?text_system.GlyphBitmap {
        return self.vtable.rasterize(self.ptr, params);
    }
};

const NativeImpl = switch (builtin.os.tag) {
    .macos => @import("platform/macos/app_icon.zig").MacAppIcons,
    .windows => @import("platform/windows/app_icon.zig").WinAppIcons,
    else => @compileError("zigui: AppIconResolver requires macOS or Windows"),
};

pub const AppIconResolver = struct {
    native: NativeImpl,
    atlas: *ColorAtlas,

    pub fn init(allocator: Allocator, atlas: *ColorAtlas) AppIconResolver {
        return .{
            .native = NativeImpl.init(allocator),
            .atlas = atlas,
        };
    }

    pub fn deinit(self: *AppIconResolver) void {
        self.native.deinit();
    }

    pub fn platform(self: *AppIconResolver) PlatformAppIcons {
        return self.native.platform_app_icons();
    }

    pub fn tile(self: *AppIconResolver, params: AppIconParams) ?AtlasTile {
        const key = IconKey.from_params(params).hash();
        if (self.atlas.get(key)) |t| return t;
        const bitmap = self.platform().rasterize(params);
        return self.atlas.get_or_insert(key, bitmap, .{ .x = 0, .y = 0 });
    }

    pub fn sprite(self: *AppIconResolver, params: AppIconParams, x: f32, y: f32) ?PolychromeSprite {
        const t = self.tile(params) orelse return null;
        const atlas_size_px: f32 = @floatFromInt(self.atlas.get_texture_size());

        const tw_px: f32 = @floatFromInt(t.bounds.size.width);
        const th_px: f32 = @floatFromInt(t.bounds.size.height);
        const ox_px: f32 = @floatFromInt(t.bounds.origin.x);
        const oy_px: f32 = @floatFromInt(t.bounds.origin.y);

        const w_pt = tw_px / params.scale_factor;
        const h_pt = th_px / params.scale_factor;

        return .{
            .position = .{ x, y },
            .size = .{ w_pt, h_pt },
            .uv_origin = .{ ox_px / atlas_size_px, oy_px / atlas_size_px },
            .uv_size = .{ tw_px / atlas_size_px, th_px / atlas_size_px },
        };
    }
};
