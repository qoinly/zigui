const std = @import("std");
const builtin = @import("builtin");
const color = @import("color.zig");
const primitives = @import("primitives.zig");
const text_system = @import("text_system.zig");
const icon_bundled = @import("icon_bundled.zig");

const Allocator = std.mem.Allocator;
const MonochromeSprite = primitives.MonochromeSprite;
const GlyphBitmap = text_system.GlyphBitmap;
const AtlasTile = text_system.AtlasTile;
const MonoAtlas = text_system.MonoAtlas;

pub const IconWeight = enum(u8) {
    ultra_light = 1,
    thin = 2,
    light = 3,
    regular = 4,
    medium = 5,
    semi_bold = 6,
    bold = 7,
    heavy = 8,
    black = 9,
};

pub const IconScale = enum(u8) {
    small = 1,
    medium = 2,
    large = 3,
};

// Where an Icon's glyph comes from. native = the OS icon set (SF Symbols on
// macOS, ...). bundled = a set zigui ships (not built yet). The caller picks per
// call (or a default); the same Icon resolves through whichever is active.
pub const IconSource = enum { native, bundled };

// The portable icon set, and the only way to name an icon. Each member maps to
// a per-platform glyph in the active provider; *_fill members are native-only
// (Lucide is stroke-only) and fall back to skip under the bundled source.
pub const Icon = enum {
    close,
    close_circle,
    close_circle_fill,
    check,
    check_circle,
    check_circle_fill,
    plus,
    plus_square,
    minus,
    chevron_up,
    chevron_down,
    chevron_left,
    chevron_right,
    chevron_up_down,
    arrow_right,
    arrow_clockwise,
    arrow_down_circle,
    arrow_down_to_line,
    search,
    sidebar,
    gear,
    gear_fill,
    info,
    warning,
    bold,
    italic,
    underline,
    align_left,
    align_center,
    align_right,
    share,
    save,
    copy,
    grid,
    layout_grid,
    bell,
    bell_badge,
    pin,
    eye,
    eye_slash,
    calendar,
    folder,
    trash,
    doc,
    envelope,
    message,
    person,
    people,
    people_fill,
    creditcard,
    creditcard_fill,
    heart,
    moon,
    sun,
    chart_bar,
    dollar_sign,
    bolt,
    archive,
    battery,
    cpu,
    wifi,
    hard_drive,
    package,
    wrench,
    ellipsis,
    pencil,
    star,
    corner_down_left,
};

pub const IconParams = struct {
    name: []const u8,
    point_size: f32,
    weight: IconWeight = .regular,
    scale: IconScale = .medium,
    scale_factor: f32 = 2.0,
};

const IconKey = struct {
    name_hash: u64,
    point_size_bits: u32,
    weight: u8,
    scale: u8,

    fn from_params(params: IconParams) IconKey {
        const px = params.point_size * params.scale_factor;
        return .{
            .name_hash = std.hash.Wyhash.hash(0x10C0FFEE, params.name),
            .point_size_bits = @bitCast(px),
            .weight = @intFromEnum(params.weight),
            .scale = @intFromEnum(params.scale),
        };
    }

    // Seed 1 = icon domain (GlyphKey uses 0); no collision in shared atlas.
    fn hash(self: IconKey) u64 {
        return std.hash.Wyhash.hash(1, std.mem.asBytes(&self));
    }
};

pub const PlatformIconSystem = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        rasterize: *const fn (ptr: *anyopaque, params: IconParams) ?GlyphBitmap,
    };

    pub fn rasterize(self: PlatformIconSystem, params: IconParams) ?GlyphBitmap {
        return self.vtable.rasterize(self.ptr, params);
    }
};

const NativeIcons = switch (builtin.os.tag) {
    .macos => @import("platform/macos/icon.zig").MacIconSystem,
    .ios => @import("platform/ios/icon.zig").IOSIconSystem,
    .windows => @import("platform/windows/icon.zig").WinIconSystem,
    .linux => @import("platform/linux/icon.zig").LinuxIconSystem,
    else => @compileError("zigui: unsupported OS for IconSystem"),
};

const WarnBits = std.StaticBitSet(@typeInfo(Icon).@"enum".fields.len);

pub const IconSystem = struct {
    allocator: Allocator,
    native: NativeIcons,
    bundled: icon_bundled.BundledIcons,
    atlas: *MonoAtlas,
    default_source: IconSource = .native,
    // one missing-glyph warning per (Icon, source); render is per-frame, so a
    // raw log would flood. Indexed [native, bundled] by @intFromEnum(source).
    warned: [2]WarnBits = .{ WarnBits.initEmpty(), WarnBits.initEmpty() },

    pub fn init(allocator: Allocator, atlas: *MonoAtlas) IconSystem {
        return .{
            .allocator = allocator,
            .native = NativeIcons.init(allocator),
            .bundled = icon_bundled.BundledIcons.init(allocator),
            .atlas = atlas,
        };
    }

    pub fn deinit(self: *IconSystem) void {
        self.native.deinit();
        self.bundled.deinit();
    }

    pub fn set_source(self: *IconSystem, s: IconSource) void {
        self.default_source = s;
    }

    // Tell the dev (once) that an Icon has no glyph in the chosen source - e.g.
    // a *_fill member under .bundled (Lucide is stroke-only), or a native symbol
    // absent on this OS version.
    fn warn_missing(self: *IconSystem, ic: Icon, source: IconSource) void {
        const si: usize = @intFromEnum(source);
        const idx: usize = @intFromEnum(ic);
        if (self.warned[si].isSet(idx)) return;
        self.warned[si].set(idx);
        std.log.warn("zigui: icon .{s} has no {s} glyph", .{ @tagName(ic), @tagName(source) });
    }

    pub fn platform(self: *IconSystem) PlatformIconSystem {
        return self.native.platform_icon_system();
    }

    pub fn tile(self: *IconSystem, params: IconParams) ?AtlasTile {
        const key = IconKey.from_params(params).hash();
        if (self.atlas.get(key)) |t| return t;

        const bitmap = self.platform().rasterize(params);
        // Top-left origin (not glyph baseline) for icons.
        return self.atlas.get_or_insert(key, bitmap, .{ .x = 0, .y = 0 });
    }

    // An Icon drawn from the chosen source: native (the OS set, resolved by
    // name) or bundled (embedded Lucide paths, stroked here). Shared atlas +
    // sprite math; only the rasterization source differs.
    pub fn sprite_icon(
        self: *IconSystem,
        ic: Icon,
        source: IconSource,
        params: IconParams,
        x: f32,
        y: f32,
        rgba: color.Rgba,
    ) ?MonochromeSprite {
        const t = switch (source) {
            .native => self.tile(.{
                .name = self.native.name_for(ic),
                .point_size = params.point_size,
                .weight = params.weight,
                .scale = params.scale,
                .scale_factor = params.scale_factor,
            }),
            .bundled => self.bundled_tile(ic, params),
        } orelse {
            self.warn_missing(ic, source);
            return null;
        };
        return self.sprite_from_tile(t, x, y, rgba, params.scale_factor);
    }

    fn bundled_tile(self: *IconSystem, ic: Icon, params: IconParams) ?AtlasTile {
        const px: u32 = @intFromFloat(@ceil(params.point_size * params.scale_factor));
        const e: u32 = @intFromEnum(ic);
        // seed 2 = bundled-icon domain (native uses IconKey, glyphs use 0/1)
        var h = std.hash.Wyhash.init(2);
        h.update(std.mem.asBytes(&e));
        h.update(std.mem.asBytes(&px));
        const key = h.final();
        if (self.atlas.get(key)) |t| return t;
        const bmp = self.bundled.rasterize_icon(ic, params);
        return self.atlas.get_or_insert(key, bmp, .{ .x = 0, .y = 0 });
    }

    fn sprite_from_tile(
        self: *IconSystem,
        t: AtlasTile,
        x: f32,
        y: f32,
        rgba: color.Rgba,
        scale_factor: f32,
    ) MonochromeSprite {
        const atlas_size_px: f32 = @floatFromInt(self.atlas.get_texture_size());
        const tw_px: f32 = @floatFromInt(t.bounds.size.width);
        const th_px: f32 = @floatFromInt(t.bounds.size.height);
        const ox_px: f32 = @floatFromInt(t.bounds.origin.x);
        const oy_px: f32 = @floatFromInt(t.bounds.origin.y);
        return .{
            .position = .{ x, y },
            .size = .{ tw_px / scale_factor, th_px / scale_factor },
            .uv_origin = .{ ox_px / atlas_size_px, oy_px / atlas_size_px },
            .uv_size = .{ tw_px / atlas_size_px, th_px / atlas_size_px },
            .sprite_color = .{ rgba.r, rgba.g, rgba.b, rgba.a },
        };
    }
};

test "IconKey hash differs from glyph hash domain" {
    const k1 = IconKey{
        .name_hash = 123,
        .point_size_bits = 0,
        .weight = 4,
        .scale = 2,
    };
    const k2 = IconKey{
        .name_hash = 123,
        .point_size_bits = 0,
        .weight = 4,
        .scale = 3,
    };
    try std.testing.expect(k1.hash() != k2.hash());
}
