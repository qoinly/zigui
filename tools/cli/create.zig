// `zigui create [name]` - scaffold a new app. Interactive on a TTY (name, package,
// target pick); flag-driven when piped or when --target is given. The gather here is
// shared by both paths; scaffold.zig writes the files (non-destructively).

const std = @import("std");
const cli = @import("main.zig");
const prompt = @import("prompt.zig");
const scaffold = @import("scaffold.zig");

const target_names = [_][]const u8{ "desktop", "android", "ios" };

pub const Config = struct {
    name: []const u8,
    package: []const u8,
    out: []const u8,
    desktop: bool,
    android: bool,
    ios: bool,
    force: bool,
};

pub fn run(ctx: cli.Ctx, args: *std.process.Args.Iterator) !void {
    var name: ?[]const u8 = null;
    var package: ?[]const u8 = null;
    var out: ?[]const u8 = null;
    var target_flag: ?[]const u8 = null;
    var force = false;

    while (args.next()) |a| {
        if (cli.eql(a, "--help") or cli.eql(a, "-h")) return help(ctx.out);
        if (cli.eql(a, "--name")) {
            name = args.next() orelse return missing(ctx, "--name");
        } else if (cli.eql(a, "--package")) {
            package = args.next() orelse return missing(ctx, "--package");
        } else if (cli.eql(a, "--out")) {
            out = args.next() orelse return missing(ctx, "--out");
        } else if (cli.eql(a, "--target")) {
            target_flag = args.next() orelse return missing(ctx, "--target");
        } else if (cli.eql(a, "--force") or cli.eql(a, "-f")) {
            force = true;
        } else if (std.mem.startsWith(u8, a, "-")) {
            try ctx.err.print("zigui create: unknown flag '{s}'\n", .{a});
            return cli.Error.Reported;
        } else if (name == null) {
            name = a; // first positional is the project name
        }
    }

    const interactive = target_flag == null and prompt.is_tty(ctx);
    var cfg = if (interactive)
        try gather_interactive(ctx, name, package)
    else
        try gather_flags(ctx, name, package, target_flag);
    if (out) |o| cfg.out = o;
    cfg.force = force;

    if (!cfg.desktop and !cfg.android and !cfg.ios) {
        try ctx.err.print("zigui create: pick at least one target\n", .{});
        return cli.Error.Reported;
    }

    try ctx.out.print("\ncreating {s} ({s}{s}{s}) in {s}/\n\n", .{
        cfg.name,
        if (cfg.desktop) "desktop " else "",
        if (cfg.android) "android " else "",
        if (cfg.ios) "ios" else "",
        cfg.out,
    });
    try scaffold.run(ctx, cfg);
}

fn gather_interactive(ctx: cli.Ctx, name_in: ?[]const u8, pkg_in: ?[]const u8) !Config {
    const name = name_in orelse try prompt.text(ctx, "Project name", "my-zigui-app");
    const package = pkg_in orelse
        try prompt.text(ctx, "Package id", try default_package(ctx, name));
    var chosen = [_]bool{ true, false, false }; // desktop preselected
    try prompt.multiselect(ctx, "Targets", &target_names, &chosen);
    return .{
        .name = name,
        .package = package,
        .out = name,
        .desktop = chosen[0],
        .android = chosen[1],
        .ios = chosen[2],
        .force = false,
    };
}

fn gather_flags(
    ctx: cli.Ctx,
    name_in: ?[]const u8,
    pkg_in: ?[]const u8,
    target_flag: ?[]const u8,
) !Config {
    const name = name_in orelse {
        try ctx.err.print(
            "zigui create: name required (positional or --name) when not a TTY\n",
            .{},
        );
        return cli.Error.Reported;
    };
    const tf = target_flag orelse {
        try ctx.err.print(
            "zigui create: --target required (e.g. desktop,android) when piped\n",
            .{},
        );
        return cli.Error.Reported;
    };
    var desktop = false;
    var android = false;
    var ios = false;
    var it = std.mem.splitScalar(u8, tf, ',');
    while (it.next()) |t| {
        const s = std.mem.trim(u8, t, " ");
        if (cli.eql(s, "desktop")) {
            desktop = true;
        } else if (cli.eql(s, "android")) {
            android = true;
        } else if (cli.eql(s, "ios")) {
            ios = true;
        } else {
            try ctx.err.print(
                "zigui create: unknown target '{s}' (have desktop, android, ios)\n",
                .{s},
            );
            return cli.Error.Reported;
        }
    }
    return .{
        .name = name,
        .package = pkg_in orelse try default_package(ctx, name),
        .out = name,
        .desktop = desktop,
        .android = android,
        .ios = ios,
        .force = false,
    };
}

// "com.example.<ident>" from the project name - a sensible editable default.
fn default_package(ctx: cli.Ctx, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(ctx.gpa, "com.example.{s}", .{try ident(ctx, name)});
}

// A valid lower snake_case identifier (zon .name, the lib name): non-alnum -> '_'.
pub fn ident(ctx: cli.Ctx, name: []const u8) ![]const u8 {
    std.debug.assert(name.len > 0);
    const buf = try ctx.gpa.alloc(u8, name.len);
    for (name, 0..) |c, i| {
        buf[i] = if (std.ascii.isAlphanumeric(c)) std.ascii.toLower(c) else '_';
    }
    return buf;
}

fn missing(ctx: cli.Ctx, flag: []const u8) cli.Error {
    ctx.err.print("zigui create: {s} needs a value\n", .{flag}) catch {};
    return cli.Error.Reported;
}

fn help(w: *std.Io.Writer) !void {
    try w.print(
        \\usage: zigui create [name] [flags]
        \\
        \\interactive on a TTY (asks name, package, targets). Flags drive it headless:
        \\  --name <name>          project name (or the positional)
        \\  --package <id>         package id (default com.example.<name>)
        \\  --target <a,b>         desktop, android, ios (required when piped)
        \\  --out <dir>            output dir (default <name>)
        \\  --force                overwrite files that already exist
        \\
    , .{});
}
