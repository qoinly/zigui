// Writes a project's files for the chosen targets from the templates/ files. Non-
// destructive: an existing file is left alone (skipped) unless --force, so running
// create again only fills in what is missing. Reports each path created or skipped.

const std = @import("std");
const cli = @import("main.zig");
const create = @import("create.zig");

// The zigui dependency written into a generated app's build.zig.zon. In zigui's own
// development this is a sibling path so a scaffolded app builds against the working
// tree; at release, swap it to the tagged tarball:
//   const zigui_dep: Dep = .{ .pinned = .{
//       .url = "https://github.com/qoinly/zigui/archive/refs/tags/v0.3.1.tar.gz",
//       .hash = "<run `zig fetch <url>` to get this>",
//   } };
const zigui_dep: Dep = .{ .path = "../zigui" };

const Dep = union(enum) {
    path: []const u8,
    pinned: struct { url: []const u8, hash: []const u8 },
};

const tmpl_zon = @embedFile("templates/build.zig.zon.tmpl");
const tmpl_build = @embedFile("templates/build.zig.tmpl");
const tmpl_main = @embedFile("templates/main.zig.tmpl");
const tmpl_manifest = @embedFile("templates/AndroidManifest.xml.tmpl");
const tmpl_plist = @embedFile("templates/Info.plist.tmpl");

pub fn run(ctx: cli.Ctx, cfg: create.Config) !void {
    std.debug.assert(cfg.desktop or cfg.android or cfg.ios);
    std.debug.assert(cfg.name.len > 0); // the name seeds the ident and the title
    std.debug.assert(cfg.out.len > 0); // the out dir prefixes every written path
    const ident = try create.ident(ctx, cfg.name);
    const cwd = std.Io.Dir.cwd();

    try cwd.createDirPath(ctx.io, cfg.out);
    try cwd.createDirPath(ctx.io, try join(ctx, cfg.out, "src"));
    if (cfg.android) try cwd.createDirPath(ctx.io, try join(ctx, cfg.out, "android"));
    if (cfg.ios) try cwd.createDirPath(ctx.io, try join(ctx, cfg.out, "ios"));

    const subs = [_]Sub{
        .{ .key = "ident", .val = ident },
        .{ .key = "display", .val = cfg.name },
        .{ .key = "package", .val = cfg.package },
        .{ .key = "fingerprint", .val = try fingerprint(ctx, ident, cfg.package) },
        .{ .key = "dep", .val = try dep_str(ctx) },
        .{ .key = "platform_paths", .val = try platform_paths(ctx, cfg) },
        .{ .key = "desktop_block", .val = try desktop_block(ctx, cfg, ident) },
        .{ .key = "android_block", .val = try android_block(ctx, cfg, ident) },
        .{ .key = "ios_block", .val = try ios_block(ctx, cfg, ident) },
    };

    var made: u32 = 0;
    try write(ctx, cfg, "build.zig.zon", try render(ctx, tmpl_zon, &subs), &made);
    try write(ctx, cfg, "build.zig", try render(ctx, tmpl_build, &subs), &made);
    try write(ctx, cfg, "src/main.zig", try render(ctx, tmpl_main, &subs), &made);
    if (cfg.android) {
        const m = try render(ctx, tmpl_manifest, &subs);
        try write(ctx, cfg, "android/AndroidManifest.xml", m, &made);
    }
    if (cfg.ios) {
        const p = try render(ctx, tmpl_plist, &subs);
        try write(ctx, cfg, "ios/Info.plist", p, &made);
    }

    try ctx.out.print("\n", .{});
    if (made == 0) {
        try ctx.out.print(
            "nothing to do - every file already exists (use --force to overwrite).\n",
            .{},
        );
        return;
    }
    try ctx.out.print("done. next:\n  cd {s}\n", .{cfg.out});
    if (cfg.desktop) try ctx.out.print("  zig build run -- desktop\n", .{});
    if (cfg.android) try ctx.out.print(
        "  zig build run -- android   # needs the Android SDK (see `zigui doctor`)\n",
        .{},
    );
    if (cfg.ios) try ctx.out.print(
        "  zig build run -- ios   # needs Xcode + a booted simulator (see `zigui doctor`)\n",
        .{},
    );
}

// A `.<target> = .{...}` field for the app() call, or "" when that target is off. The leading
// newline puts each on its own line under .source.
fn desktop_block(ctx: cli.Ctx, cfg: create.Config, ident: []const u8) ![]const u8 {
    if (!cfg.desktop) return "";
    return std.fmt.allocPrint(ctx.gpa, "\n        .desktop = .{{ .name = \"{s}\" }},", .{ident});
}

fn android_block(ctx: cli.Ctx, cfg: create.Config, ident: []const u8) ![]const u8 {
    if (!cfg.android) return "";
    return std.fmt.allocPrint(ctx.gpa,
        \\
        \\        .android = .{{
        \\            .name = "{s}",
        \\            .manifest = b.path("android/AndroidManifest.xml"),
        \\            .package_name = "{s}",
        \\        }},
    , .{ ident, cfg.package });
}

fn ios_block(ctx: cli.Ctx, cfg: create.Config, ident: []const u8) ![]const u8 {
    if (!cfg.ios) return "";
    return std.fmt.allocPrint(ctx.gpa,
        \\
        \\        .ios = .{{
        \\            .name = "{s}",
        \\            .info_plist = b.path("ios/Info.plist"),
        \\            .bundle_id = "{s}",
        \\        }},
    , .{ ident, cfg.package });
}

// The platform dirs added to build.zig.zon's .paths.
fn platform_paths(ctx: cli.Ctx, cfg: create.Config) ![]const u8 {
    return std.fmt.allocPrint(ctx.gpa, "{s}{s}", .{
        if (cfg.android) "\n        \"android\"," else "",
        if (cfg.ios) "\n        \"ios\"," else "",
    });
}

const Sub = struct { key: []const u8, val: []const u8 };

// Replaces every {{key}} in `template` with its sub. An unknown token or an unbalanced
// brace is a template bug, surfaced rather than silently emitted.
fn render(ctx: cli.Ctx, template: []const u8, subs: []const Sub) ![]const u8 {
    std.debug.assert(template.len > 0);
    var aw = std.Io.Writer.Allocating.init(ctx.gpa);
    const w = &aw.writer;
    var i: usize = 0;
    while (i < template.len) {
        if (template[i] == '{' and i + 1 < template.len and template[i + 1] == '{') {
            const end = std.mem.indexOfPos(u8, template, i + 2, "}}") orelse
                return error.UnterminatedToken;
            const key = template[i + 2 .. end];
            try w.writeAll(lookup(subs, key) orelse return error.UnknownToken);
            i = end + 2;
        } else {
            try w.writeByte(template[i]);
            i += 1;
        }
    }
    return aw.written();
}

fn lookup(subs: []const Sub, key: []const u8) ?[]const u8 {
    for (subs) |s| if (std.mem.eql(u8, s.key, key)) return s.val;
    return null;
}

// Zig's package fingerprint is { id: u32, checksum: u32 } packed into u64: the checksum
// (high half) MUST be Crc32 of the name, the id (low half) is ours to pick. Derive the
// id from the package so it is stable yet distinct, dodging the two reserved ids.
fn fingerprint(ctx: cli.Ctx, ident: []const u8, package: []const u8) ![]const u8 {
    std.debug.assert(ident.len > 0);
    const checksum: u32 = std.hash.Crc32.hash(ident);
    var id: u32 = @truncate(std.hash.Wyhash.hash(0, package));
    if (id == 0 or id == 0xffffffff) id = 1;
    return std.fmt.allocPrint(ctx.gpa, "0x{x}", .{(@as(u64, checksum) << 32) | id});
}

// Writes one file unless it already exists (then skip, unless --force). Counts writes.
fn write(ctx: cli.Ctx, cfg: create.Config, rel: []const u8, data: []const u8, made: *u32) !void {
    std.debug.assert(rel.len > 0);
    const path = try join(ctx, cfg.out, rel);
    const cwd = std.Io.Dir.cwd();
    const exists = blk: {
        cwd.access(ctx.io, path, .{}) catch break :blk false;
        break :blk true;
    };
    if (exists and !cfg.force) {
        try ctx.out.print("  skip     {s} (exists)\n", .{path});
        return;
    }
    try cwd.writeFile(ctx.io, .{ .sub_path = path, .data = data });
    try ctx.out.print("  created  {s}\n", .{path});
    made.* += 1;
}

fn join(ctx: cli.Ctx, dir: []const u8, rel: []const u8) ![]const u8 {
    return std.fmt.allocPrint(ctx.gpa, "{s}/{s}", .{ dir, rel });
}

fn dep_str(ctx: cli.Ctx) ![]const u8 {
    return switch (zigui_dep) {
        .path => |p| std.fmt.allocPrint(ctx.gpa, ".{{ .path = \"{s}\" }}", .{p}),
        .pinned => |v| std.fmt.allocPrint(
            ctx.gpa,
            ".{{\n            .url = \"{s}\",\n            .hash = \"{s}\",\n        }}",
            .{ v.url, v.hash },
        ),
    };
}
