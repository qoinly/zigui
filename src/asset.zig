const std = @import("std");

const Allocator = std.mem.Allocator;

pub const AssetSource = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        load: *const fn (ptr: *anyopaque, path: []const u8) ?[]const u8,
        list: *const fn (ptr: *anyopaque, allocator: Allocator, path: []const u8) ?[][]const u8,
        free: *const fn (ptr: *anyopaque, data: []const u8) void,
    };

    pub fn load(self: AssetSource, path: []const u8) ?[]const u8 {
        return self.vtable.load(self.ptr, path);
    }

    pub fn list(self: AssetSource, allocator: Allocator, path: []const u8) ?[][]const u8 {
        return self.vtable.list(self.ptr, allocator, path);
    }

    pub fn free(self: AssetSource, data: []const u8) void {
        self.vtable.free(self.ptr, data);
    }
};

pub const EmbeddedAssetSource = struct {
    entries: []const Entry,

    pub const Entry = struct {
        path: []const u8,
        data: []const u8,
    };

    const Self = @This();

    pub fn init(entries: []const Entry) Self {
        return .{ .entries = entries };
    }

    pub fn asset_source(self: *Self) AssetSource {
        return .{
            .ptr = self,
            .vtable = &.{
                .load = load,
                .list = list_dir,
                .free = free_data,
            },
        };
    }

    fn load(ptr: *anyopaque, path: []const u8) ?[]const u8 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        for (self.entries) |entry| {
            if (std.mem.eql(u8, entry.path, path)) return entry.data;
        }
        return null;
    }

    fn list_dir(ptr: *anyopaque, allocator: Allocator, path: []const u8) ?[][]const u8 {
        const self: *Self = @ptrCast(@alignCast(ptr));

        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer {
            for (names.items) |name| allocator.free(name);
            names.deinit(allocator);
        }

        const dir_prefix = if (path.len > 0 and !std.mem.endsWith(u8, path, "/"))
            std.fmt.allocPrint(allocator, "{s}/", .{path}) catch return null
        else
            allocator.dupe(u8, path) catch return null;
        defer allocator.free(dir_prefix);

        for (self.entries) |entry| {
            if (!std.mem.startsWith(u8, entry.path, dir_prefix)) continue;
            const rest = entry.path[dir_prefix.len..];
            if (std.mem.indexOfScalar(u8, rest, '/') != null) continue;
            const name = allocator.dupe(u8, rest) catch continue;
            names.append(allocator, name) catch {
                allocator.free(name);
                continue;
            };
        }

        return names.toOwnedSlice(allocator) catch null;
    }

    // Embedded data lives in the binary; no per-call free.
    fn free_data(_: *anyopaque, _: []const u8) void {}
};

test "EmbeddedAssetSource load + list + miss" {
    const allocator = std.testing.allocator;

    const entries = [_]EmbeddedAssetSource.Entry{
        .{ .path = "icons/home.svg", .data = "<svg>home</svg>" },
        .{ .path = "icons/settings.svg", .data = "<svg>settings</svg>" },
        .{ .path = "icons/sub/nested.svg", .data = "<svg>nested</svg>" },
        .{ .path = "images/logo.png", .data = "PNG" },
    };

    var source = EmbeddedAssetSource.init(&entries);
    const src = source.asset_source();

    const home = src.load("icons/home.svg");
    try std.testing.expect(home != null);
    try std.testing.expectEqualStrings("<svg>home</svg>", home.?);

    const icons = src.list(allocator, "icons");
    try std.testing.expect(icons != null);
    defer {
        for (icons.?) |n| allocator.free(n);
        allocator.free(icons.?);
    }
    try std.testing.expectEqual(@as(usize, 2), icons.?.len);

    try std.testing.expect(src.load("missing.svg") == null);
}
