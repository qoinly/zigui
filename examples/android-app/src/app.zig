const std = @import("std");
const zigui = @import("zigui");
const Node = zigui.Node;
const Frame = zigui.Frame;
const router = @import("router.zig");
const overlay = @import("scaffold/overlay.zig");
const onboarding = @import("pages/onboarding.zig");

// Single source of truth: the view is a pure function of this, handlers mutate it.
// The runtime owns the allocator/engine/theme and hands them back on the Frame, so
// caller state is just data. On Android the state must outlive main() (App.run
// returns immediately, the framework owns the loop), so main.zig holds one as a
// container-scoped var rather than a stack local.
pub const App = struct {
    // Navigation + per-page widget state the pushed pages render through. These keep
    // a stable address (App lives container-scoped), so nav_page / the scroll list /
    // the shared text editor can back-point into them.
    nav: zigui.NavStack = .{},
    list_scroll: zigui.ScrollState = .{},
    field: zigui.TextField = .{},
    onboarding: zigui.CarouselState = .{},
    bottom_nav: zigui.BottomBarState = .{},
    tab: usize = 0, // active bottom-bar destination
    bb_style: zigui.BottomBarStyle = .floating, // bottom-bar style, toggled in the demo

    clicks: u32 = 0,
    focus: u32 = 0, // id of the focused text field, 0 = none
    awake: bool = false, // FLAG_KEEP_SCREEN_ON while true
    immersive: bool = false, // system bars hidden while true
    bright: bool = false, // screen forced to full brightness while true
    orient: zigui.napi.display.Orientation = .auto, // current orientation lock
    auth_done: ?bool = null, // last biometric outcome: null none, true ok, false failed

    // The last result a detail page returned, copied out of the stack on the frame
    // the pop delivered it (take_result yields it once, the slice is borrowed).
    last_result: [64]u8 = undefined,
    last_result_len: usize = 0,
    // The last picked file's display name + local path, kept across frames (take_file
    // yields them once, like the route result).
    picked_name: [128]u8 = undefined,
    picked_name_len: usize = 0,
    picked_path: [256]u8 = undefined,
    picked_path_len: usize = 0,
    // The last accessibility screen-read, kept across frames (read() borrows the
    // buffer it fills, so copy it out for the page to show).
    a11y_read: [256]u8 = undefined,
    a11y_read_len: usize = 0,
    // The last subscribed accessibility event, "type\tpackage\ttext", kept across frames.
    a11y_event: [256]u8 = undefined,
    a11y_event_len: usize = 0,
    // The last notification the listener caught, kept across frames (take() borrows
    // the buffer it fills).
    notif: [256]u8 = undefined,
    notif_len: usize = 0,
    // The last broadcast, flattened to "action key=val ...", kept across frames.
    bc: [256]u8 = undefined,
    bc_len: usize = 0,
    // The inbox read-out, "address\tbody\n...", kept across frames (read() borrows
    // the buffer it fills).
    sms: [256]u8 = undefined,
    sms_len: usize = 0,

    // A background job + its last result, kept after poll consumes it once.
    bg_task: zigui.Task(u64) = .{},
    bg_result: ?u64 = null,

    // Kit overlay widgets (rendered by the kit, not native): a modal dialog, an eased
    // edge sheet, and an in-app toast stack. The overlay / hud scaffold draws them.
    dialog_open: bool = false,
    sheet_open: bool = false,
    sheet_t: f32 = 0, // caller-eased sheet slide progress 0..1
    toasts: [3]zigui.ToastSlot = .{ .{}, .{}, .{} },

    // Push a toast into the first free slot; if all are full, overwrite slot 0.
    // text must be a static literal - the slot borrows it across frames.
    pub fn toast(self: *App, text: []const u8, variant: zigui.ToastVariant) void {
        for (&self.toasts) |*s| {
            if (!s.active) {
                s.* = .{ .active = true, .text = text, .variant = variant };
                return;
            }
        }
        self.toasts[0] = .{ .active = true, .text = text, .variant = variant };
    }

    pub fn render(f: *Frame, app: *App) *Node {
        if (app.nav.depth == 0) app.nav.go("home", "Home"); // seed the root once
        zigui.handle_back(&app.nav); // Esc / Android Back / chevron -> pop
        app.drain_results();
        // Window properties, re-asserted every frame (the backend hops into the OS
        // only on a change): light status-bar icons over this dark theme, plus the
        // two live toggles.
        zigui.napi.display.status_bar_icons(.light);
        zigui.napi.display.keep_awake(app.awake);
        zigui.napi.display.immersive(app.immersive);

        // The onboarding carousel is full-screen (no app-bar): swipe or Next across
        // the slides, Skip / Finish leave it.
        if (std.mem.eql(u8, app.nav.current(), "splash")) return onboarding.view(f, app);

        // nav_page renders the current page, or slides the two during a push / pop.
        const page = zigui.nav_page(f, App, &app.nav, app, router.dispatch);
        return zigui.col(.{}, &.{
            zigui.app_bar(app.nav.current_title(), .{ .show_back = app.nav.depth > 1 }),
            page,
        });
    }

    // The async results every page polls for: each take_* yields once, so copy the
    // borrowed slice into the page's keep-across-frames buffer the frame it lands.
    fn drain_results(app: *App) void {
        if (app.nav.take_result()) |r| {
            const k = @min(r.len, app.last_result.len);
            @memcpy(app.last_result[0..k], r[0..k]);
            app.last_result_len = k;
        }
        if (zigui.napi.picker.take_file()) |f| {
            app.picked_name_len = copy(&app.picked_name, f.name);
            app.picked_path_len = copy(&app.picked_path, f.path);
        }
        if (zigui.napi.biometric.result()) |outcome| {
            app.auth_done = outcome == .success;
        }
        if (zigui.napi.notification_listener.take(&app.notif)) |n| {
            app.notif_len = n.len;
        }
        if (zigui.napi.broadcast.take()) |b| {
            app.bc_len = flatten_broadcast(&app.bc, b);
        }
        if (zigui.napi.accessibility.take_event(&app.a11y_event)) |e| {
            app.a11y_event_len = e.len;
        }
        if (app.bg_task.poll()) |r| app.bg_result = r;
    }
};

// The modal + non-modal layers run/main passes alongside the body.
pub const overlay_view = overlay.view;
pub const hud_view = @import("scaffold/hud.zig").view;

// Flatten a broadcast (action + key=value extras) into buf as "action key=val ...".
// Shared by the foreground take() drain above and the headless log.
pub fn flatten_broadcast(buf: []u8, b: zigui.napi.broadcast.Broadcast) usize {
    var n = copy(buf, b.action);
    for (b.extras) |kv| {
        n += copy(buf[n..], " ");
        n += copy(buf[n..], kv.key);
        n += copy(buf[n..], "=");
        n += copy(buf[n..], kv.value);
    }
    return n;
}

fn copy(dst: []u8, src: []const u8) usize {
    const k = @min(dst.len, src.len);
    @memcpy(dst[0..k], src[0..k]);
    return k;
}
