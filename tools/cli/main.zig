// The zigui CLI: a subcommand dispatcher. Each command lives in a sibling file with a
// `run(ctx, args)`; run() routes by the first argument.

const std = @import("std");
const doctor = @import("doctor.zig");
const create = @import("create.zig");

pub const version = "0.3.1";

// Threaded into every command: the IO backend, an arena for the run, the process
// environment, and the two streams. A command writes user output to `out` and
// diagnostics to `err`; it returns error.Reported once it has already printed a
// human message, so main() exits non-zero without a second machine-looking line.
pub const Ctx = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    env: *std.process.Environ.Map,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
};

pub const Error = error{Reported};

pub fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn main(startup: std.process.Init) !void {
    const io = startup.io;
    var out_buf: [4096]u8 = undefined;
    var err_buf: [1024]u8 = undefined;
    var ow = std.Io.File.Writer.init(std.Io.File.stdout(), io, &out_buf);
    var ew = std.Io.File.Writer.init(std.Io.File.stderr(), io, &err_buf);
    defer ow.interface.flush() catch {};
    defer ew.interface.flush() catch {};

    const ctx = Ctx{
        .io = io,
        .gpa = startup.arena.allocator(),
        .env = startup.environ_map,
        .out = &ow.interface,
        .err = &ew.interface,
    };

    // initAllocator, not init: on Windows the process gets no argv vector, so the
    // iterator decodes GetCommandLineW through the arena; on POSIX it wraps argv as-is.
    var args = try std.process.Args.Iterator.initAllocator(startup.minimal.args, ctx.gpa);
    defer args.deinit();
    _ = args.next(); // argv[0]

    run(ctx, &args) catch |e| {
        // process.exit skips the deferred flushes, so flush both streams here - the
        // command's own output (on out) and any error line must reach the terminal.
        if (e != Error.Reported) ctx.err.print("error: {s}\n", .{@errorName(e)}) catch {};
        ctx.out.flush() catch {};
        ctx.err.flush() catch {};
        std.process.exit(1);
    };
}

fn run(ctx: Ctx, args: *std.process.Args.Iterator) !void {
    const cmd = args.next() orelse return usage(ctx.out);
    // `init` is an alias for `create` (in-place semantics aside, the same scaffolder).
    if (eql(cmd, "create") or eql(cmd, "init")) return create.run(ctx, args);
    if (eql(cmd, "doctor")) return doctor.run(ctx, args);
    if (eql(cmd, "help") or eql(cmd, "--help") or eql(cmd, "-h")) return usage(ctx.out);
    if (eql(cmd, "version") or eql(cmd, "--version") or eql(cmd, "-V")) {
        return ctx.out.print("zigui {s}\n", .{version});
    }
    try ctx.err.print("zigui: unknown command '{s}'\n\n", .{cmd});
    try usage(ctx.err);
    return Error.Reported;
}

fn usage(w: *std.Io.Writer) !void {
    try w.print(
        \\zigui {s} - the zigui command line
        \\
        \\usage: zigui <command> [args]
        \\
        \\commands:
        \\  create [name]  scaffold a new app (interactive: pick desktop / android / ios)
        \\  doctor         check the Android + iOS toolchains
        \\  version        print the version
        \\  help           print this help
        \\
        \\run `zigui create --help` for the scaffold flags.
        \\
    , .{version});
}
