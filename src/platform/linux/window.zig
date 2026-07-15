// Native (non-custom-chrome) window types; the Linux backend leads with the
// custom shell (custom_shell.zig), like Windows. The full public surface exists
// so the window facade + root compile and the API matches macOS, even where a
// shell has no Linux implementation: those open_* return error.Unsupported and
// the setters are no-ops.

const std = @import("std");
const types = @import("../../window/types.zig");

pub const Error = error{
    WindowCreateFailed,
    Unsupported,
};

const Size2 = extern struct { width: f64 = 0, height: f64 = 0 };
const Rect2 = extern struct { x: f64 = 0, y: f64 = 0, width: f64 = 0, height: f64 = 0 };

pub const Event = struct { kind: u8 = 0, x: f32 = 0, y: f32 = 0 };

pub const BodyMouseEvent = types.BodyMouseEvent;
pub const BodyMouseFn = types.BodyMouseFn;
pub const BodyExitFn = types.BodyExitFn;

pub const SimpleOptions = struct {
    title: []const u8,
    width: f64 = 360,
    height: f64 = 200,
    label: ?[]const u8 = null,
};

pub const Handle = struct {
    raw: ?*anyopaque = null,

    pub fn focus(self: Handle) void {
        _ = self;
    }
};

pub const MetalOptions = struct {
    title: []const u8,
    width: f64 = 800,
    height: f64 = 600,
    resizable: bool = true,
};

pub const MetalHandle = struct {
    window: ?*anyopaque = null,
    // cross-platform "render surface" handle (CAMetalLayer on macOS); unused
    // here - the native shells have no Linux implementation.
    metal_layer: ?*anyopaque = null,
    height: f32 = 0,

    pub fn focus(self: MetalHandle) void {
        _ = self;
    }
    pub fn get_size(self: MetalHandle) Size2 {
        _ = self;
        return .{};
    }
    pub fn deinit(self: MetalHandle) void {
        _ = self;
    }
};

pub const PanelMaterial = enum(u32) {
    menu = 5,
    popover = 6,
    sidebar = 7,
    hud = 8,
    fullscreen_ui = 15,
    under_window = 21,
};

pub const PanelOptions = struct {
    width: f64 = 360,
    height: f64 = 480,
    corner_radius: f64 = 12,
    material: PanelMaterial = .menu,
};

pub const PanelHandle = struct {
    window: ?*anyopaque = null,
    metal_layer: ?*anyopaque = null,

    pub fn show(self: PanelHandle) void {
        _ = self;
    }
    pub fn hide(self: PanelHandle) void {
        _ = self;
    }
    pub fn is_visible(self: PanelHandle) bool {
        _ = self;
        return false;
    }
    pub fn set_origin(self: PanelHandle, x: f64, y: f64) void {
        _ = self;
        _ = x;
        _ = y;
    }
    pub fn set_size(self: PanelHandle, w: f64, h: f64) void {
        _ = self;
        _ = w;
        _ = h;
    }
    pub fn set_size_top_anchored(self: PanelHandle, w: f64, h: f64) void {
        _ = self;
        _ = w;
        _ = h;
    }
    pub fn on_resign_key(
        self: PanelHandle,
        ctx: *anyopaque,
        callback: *const fn (*anyopaque) void,
    ) void {
        _ = self;
        _ = ctx;
        _ = callback;
    }
    pub fn set_mouse_handler(
        self: PanelHandle,
        ctx: *anyopaque,
        callback: *const fn (*anyopaque, Event) void,
    ) void {
        _ = self;
        _ = ctx;
        _ = callback;
    }
    pub fn deinit(self: PanelHandle) void {
        _ = self;
    }
};

pub const NativeShellHandle = struct {
    window: ?*anyopaque = null,
    metal_layer: ?*anyopaque = null,
    height: f32 = 0,

    pub fn focus(self: NativeShellHandle) void {
        _ = self;
    }
    pub fn get_content_size(self: NativeShellHandle) Size2 {
        _ = self;
        return .{};
    }
    pub fn get_safe_content_bounds(self: NativeShellHandle) Rect2 {
        _ = self;
        return .{};
    }
    pub fn sync_drawable_size(self: NativeShellHandle) Size2 {
        _ = self;
        return .{};
    }
    pub fn deinit(self: NativeShellHandle) void {
        _ = self;
    }
};

pub fn open_simple(opts: SimpleOptions) Error!Handle {
    _ = opts;
    return error.Unsupported;
}

pub fn open_metal(opts: MetalOptions) Error!MetalHandle {
    _ = opts;
    return error.Unsupported;
}

pub fn open_panel(opts: PanelOptions) Error!PanelHandle {
    _ = opts;
    return error.Unsupported;
}

pub fn open_native_shell(opts: types.NativeShellOptions) Error!NativeShellHandle {
    _ = opts;
    return error.Unsupported;
}

pub fn set_sidebar_items(handle: NativeShellHandle, items: []const types.SidebarEntry) void {
    _ = handle;
    _ = items;
}
pub fn set_sidebar_on_select(ctx: *anyopaque, callback: types.SidebarSelectFn) void {
    _ = ctx;
    _ = callback;
}
pub fn set_sidebar_on_reorder(ctx: *anyopaque, callback: types.SidebarReorderFn) void {
    _ = ctx;
    _ = callback;
}
pub fn set_sidebar_selection(id: []const u8) void {
    _ = id;
}
pub fn set_native_shell_title(handle: NativeShellHandle, title: []const u8) void {
    _ = handle;
    _ = title;
}
pub fn set_native_shell_on_scroll(ctx: *anyopaque, callback: types.ScrollFn) void {
    _ = ctx;
    _ = callback;
}
pub fn set_native_shell_on_body_move(ctx: *anyopaque, callback: BodyMouseFn) void {
    _ = ctx;
    _ = callback;
}
pub fn set_native_shell_on_body_click(ctx: *anyopaque, callback: BodyMouseFn) void {
    _ = ctx;
    _ = callback;
}
pub fn set_native_shell_on_body_exit(ctx: *anyopaque, callback: BodyExitFn) void {
    _ = ctx;
    _ = callback;
}
pub fn set_toolbar_items(handle: NativeShellHandle, items: []const types.ToolbarEntry) void {
    _ = handle;
    _ = items;
}
pub fn set_toolbar_on_select(ctx: *anyopaque, callback: types.ToolbarSelectFn) void {
    _ = ctx;
    _ = callback;
}
pub fn set_toolbar_on_search(ctx: *anyopaque, callback: types.ToolbarSearchFn) void {
    _ = ctx;
    _ = callback;
}

pub fn run_alert(opts: types.AlertOptions) usize {
    _ = opts;
    return 0;
}

pub fn native_image_named(name: []const u8) ?*anyopaque {
    _ = name;
    return null;
}

// Linux has no native file dialog in a non-GTK app, so shell out to `zenity` (the
// common portable choice; `xdg-desktop-portal` would be the sandboxed alternative).
// Blocks the loop while the dialog is up, like macOS runModal. Returns "" on cancel
// or if zenity is absent.
pub fn open_file(opts: types.FilePickerOptions, out_buf: []u8) []const u8 {
    return run_zenity(opts, out_buf, false);
}

pub fn save_file(opts: types.FilePickerOptions, out_buf: []u8) []const u8 {
    return run_zenity(opts, out_buf, true);
}

// 0.16's std has no process.run over the blocking Io and no posix fork/exec, so shell
// out with a direct libc fork/exec (Dover links libc). The child only calls
// async-signal-safe dup2/close/execvp before exec, so it is safe after GPU init.
extern "c" fn fork() std.c.pid_t;
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn _exit(code: c_int) noreturn;

fn run_zenity(opts: types.FilePickerOptions, out_buf: []u8, save: bool) []const u8 {
    var title_buf: [256]u8 = undefined;
    var name_buf: [256]u8 = undefined;
    var filter_buf: [512]u8 = undefined;
    var argv: [12]?[*:0]const u8 = undefined;
    var argc: usize = 0;
    const push = struct {
        fn f(av: []?[*:0]const u8, i: *usize, s: [*:0]const u8) void {
            av[i.*] = s;
            i.* += 1;
        }
    }.f;
    push(&argv, &argc, "zenity");
    push(&argv, &argc, "--file-selection");
    if (save) {
        push(&argv, &argc, "--save");
        push(&argv, &argc, "--confirm-overwrite");
    }
    if (opts.allow_directories and !opts.allow_files) push(&argv, &argc, "--directory");
    if (opts.title.len > 0) {
        const s: [:0]const u8 = std.fmt.bufPrintZ(&title_buf, "--title={s}", .{opts.title}) catch "--title=Open";
        push(&argv, &argc, s.ptr);
    }
    if (opts.default_filename.len > 0) {
        const s = std.fmt.bufPrintZ(&name_buf, "--filename={s}", .{opts.default_filename}) catch return "";
        push(&argv, &argc, s.ptr);
    }
    if (opts.allowed_extensions.len > 0)
        push(&argv, &argc, build_filter(&filter_buf, opts.allowed_extensions));
    argv[argc] = null; // execvp sentinel

    var fds: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&fds) != 0) return "";
    const pid = fork();
    if (pid < 0) {
        _ = std.c.close(fds[0]);
        _ = std.c.close(fds[1]);
        return "";
    }
    if (pid == 0) {
        _ = std.c.dup2(fds[1], 1); // child stdout -> pipe
        _ = std.c.close(fds[0]);
        _ = std.c.close(fds[1]);
        _ = execvp("zenity", @ptrCast(&argv));
        _exit(127); // exec failed (zenity absent)
    }
    _ = std.c.close(fds[1]);
    var total: usize = 0;
    while (total < out_buf.len) {
        const n = std.c.read(fds[0], out_buf[total..].ptr, out_buf.len - total);
        if (n <= 0) break;
        total += @intCast(n);
    }
    _ = std.c.close(fds[0]);
    var status: c_int = 0;
    _ = std.c.waitpid(pid, &status, 0);
    // WIFEXITED && WEXITSTATUS == 0; a cancel is exit 1, a missing zenity is 127.
    if ((status & 0x7f) != 0 or ((status >> 8) & 0xff) != 0) return "";
    return std.mem.trim(u8, out_buf[0..total], "\r\n");
}

// zenity glob filter arg, null-terminated: "--file-filter=Collections | *.json *.yaml ...".
fn build_filter(buf: []u8, exts: []const []const u8) [*:0]const u8 {
    const prefix = "--file-filter=Collections |";
    @memcpy(buf[0..prefix.len], prefix);
    var n: usize = prefix.len;
    for (exts) |e| {
        if (n + 4 + e.len > buf.len) break; // room for " *." + ext + trailing NUL
        buf[n] = ' ';
        buf[n + 1] = '*';
        buf[n + 2] = '.';
        n += 3;
        @memcpy(buf[n..][0..e.len], e);
        n += e.len;
    }
    buf[n] = 0;
    return @ptrCast(buf.ptr);
}
