const std = @import("std");
const zigui = @import("zigui");
const Node = zigui.Node;
const Frame = zigui.Frame;
const Config = zigui.Config;

// A native iOS showcase for zigui. A frosted floating tab bar switches five pages: a
// card feed (collapsing large title), a navigation demo (parallax push + edge-swipe
// back), the native device APIs, the widget kit, and an about page. Edge-to-edge per
// Apple's HIG: content scrolls under the bars. Icons are builtin Lucide.
const tabs = [_]zigui.BottomBarItem{
    .{ .icon = .doc, .label = "Home" },
    .{ .icon = .layout_grid, .label = "Nav" },
    .{ .icon = .cpu, .label = "Native" },
    .{ .icon = .grid, .label = "Kit" },
    .{ .icon = .info, .label = "About" },
};

const card_bg = zigui.Rgba{ .r = 0.11, .g = 0.11, .b = 0.13, .a = 1 };
const accent = zigui.Rgba{ .r = 0.0, .g = 0.478, .b = 1.0, .a = 1 };
const ios_title = zigui.Rgba{ .r = 0.96, .g = 0.96, .b = 0.98, .a = 1 };
const muted = zigui.Rgba{ .r = 0.6, .g = 0.6, .b = 0.64, .a = 1 };

const Feature = struct { icon: zigui.Icon, title: []const u8, subtitle: []const u8 };
const features = [_]Feature{
    .{
        .icon = .bolt,
        .title = "Native chrome",
        .subtitle = "Frosted tab bar + collapsing nav titles.",
    },
    .{
        .icon = .layout_grid,
        .title = "Parallax push",
        .subtitle = "Detail slides in; swipe the edge to go back.",
    },
    .{
        .icon = .cpu,
        .title = "Device APIs",
        .subtitle = "Battery, clipboard, share, files, haptics.",
    },
    .{
        .icon = .grid,
        .title = "Widget kit",
        .subtitle = "Buttons, toggles, sliders, charts - on iOS.",
    },
};

const Article = struct { title: []const u8, summary: []const u8, body: []const u8 };
const articles = [_]Article{
    .{
        .title = "Frosted navigation",
        .summary = "A floating tab bar and collapsing large titles.",
        .body = "The tab bar and the top navigation bar are drawn by zigui's kit and " ++
            "frosted with a real gaussian blur of the content behind them. The large " ++
            "title collapses to a small inline title as you scroll, and returns on the " ++
            "way back up.",
    },
    .{
        .title = "Parallax push",
        .summary = "Detail slides in; swipe from the edge to dismiss.",
        .body = "Pushing a page slides it in over the previous one, which parallaxes and " ++
            "dims behind it. Drag from the left edge to pop interactively - the page " ++
            "follows your finger and springs back if you release early.",
    },
    .{
        .title = "Native device APIs",
        .summary = "Battery, clipboard, share, files, haptics.",
        .body = "The Native tab calls UIKit through zigui's napi layer: read the battery, " ++
            "copy and paste text, present the share sheet, open links, pick a file, and " ++
            "fire haptics - all from Zig.",
    },
    .{
        .title = "A portable widget kit",
        .summary = "Buttons, toggles, sliders, charts - on iOS.",
        .body = "The same widgets that render on desktop and Android render here: buttons, " ++
            "badges, toggles, sliders, progress and charts. The Kit tab shows a sampling.",
    },
};

const ItemCtx = struct { app: *App, idx: usize };
const Bio = enum { untried, success, failed }; // last biometric outcome

const SegItem = zigui.kit.toggle_group.ToggleGroupItem;
const donut_slices = [_]zigui.kit.chart.Slice{
    .{ .label = "Zig", .value = 50, .color = zigui.Rgba.from_hex(0xF7A41D) },
    .{ .label = "Metal", .value = 32, .color = zigui.Rgba.from_hex(0x3B82F6) },
    .{ .label = "UIKit", .value = 18, .color = zigui.Rgba.from_hex(0x22C55E) },
};

pub const App = struct {
    tab: usize = 0,
    detail: bool = false,
    detail_idx: usize = 0,
    push: zigui.PushState = .{},
    bottom_nav: zigui.BottomBarState = .{},
    scrolls: [tabs.len]zigui.ScrollState = [_]zigui.ScrollState{.{}} ** tabs.len,
    detail_list: zigui.ScrollState = .{},
    item_ctx: [articles.len]ItemCtx = undefined,
    // Native-tab napi state.
    clip: [128]u8 = undefined,
    clip_len: usize = 0,
    picked: [256]u8 = undefined,
    picked_len: usize = 0,
    picked_name: [128]u8 = undefined,
    picked_name_len: usize = 0,
    awake: bool = false,
    bright_slider: zigui.kit.slider.SliderState = .{},
    bright_vals: [1]f32 = .{0.5},
    bio: Bio = .untried,
    // Kit-tab widget state.
    kit_toggle: bool = true,
    kit_check: bool = false,
    kit_slider: zigui.kit.slider.SliderState = .{},
    kit_slider_vals: [1]f32 = .{0.4},
    kit_input: zigui.TextField = .{},
    kit_focus: u32 = 0, // id of the focused text field (0 = none)
    kit_align: usize = 0, // segmented-control selection

    pub fn render(f: *Frame, app: *App) *Node {
        const safe_top = f.body.origin.y;
        const base = page_body(f, app, safe_top);
        const pushed = detail_body(f, app, safe_top);
        return zigui.col(.{}, &.{
            zigui.push_slide(f, &app.push, &app.detail, base, pushed),
            zigui.bottom_bar(&tabs, &app.bottom_nav, .{
                .active = app.tab,
                .style = .floating,
                .on_select = zigui.on_index(App, select_tab),
            }),
        });
    }
};

fn page_body(f: *Frame, app: *App, safe_top: f32) *Node {
    return switch (app.tab) {
        0 => home_page(f, app, safe_top),
        1 => nav_page(f, app, safe_top),
        2 => native_page(f, app, safe_top),
        3 => kit_page(f, app, safe_top),
        else => about_page(f, app, safe_top),
    };
}

// A scrollable page: content under a large collapsing title.
fn page(
    list: *zigui.ScrollState,
    f: *Frame,
    title: []const u8,
    content: *Node,
) *Node {
    return zigui.col(.{}, &.{
        zigui.scroll(list, .{ .height = f.size.height }, content),
        zigui.top_bar(title, .{ .style = .large, .scroll = list }),
    });
}

fn top_gap(safe_top: f32) *Node {
    return zigui.col(.{ .height = safe_top + 56 }, &.{}); // status bar + large title
}
fn bottom_gap() *Node {
    return zigui.col(.{ .height = 86 }, &.{}); // clears the floating tab bar
}
fn section(title: []const u8) *Node {
    return zigui.text(title, .{ .size = 13, .weight = .semi_bold, .color = muted });
}

// ---- Home: a feed of feature cards ----
fn home_page(f: *Frame, app: *App, safe_top: f32) *Node {
    const items = f.arena.alloc(*Node, features.len + 1) catch return zigui.text("oom", .{});
    items[0] = zigui.text("A native iOS UI toolkit, in Zig.", .{ .size = 17, .color = muted });
    for (features, 0..) |ft, i| items[i + 1] = feature_card(ft);
    const content = zigui.col(.{}, &.{
        top_gap(safe_top),
        zigui.col(.{ .pad = .lg, .gap = .md }, items),
        bottom_gap(),
    });
    return page(&app.scrolls[0], f, "Home", content);
}

fn feature_card(ft: Feature) *Node {
    return zigui.col(.{ .bg = card_bg, .radius = 14, .pad = .lg }, &.{
        zigui.row(.{ .gap = .md, .cross = .center }, &.{
            zigui.icon(ft.icon, .{ .size = 26, .color = accent }),
            zigui.col(.{ .gap = .sm }, &.{
                zigui.text(ft.title, .{ .size = 17, .weight = .semi_bold }),
                zigui.text(ft.subtitle, .{ .size = 14, .color = muted }),
            }),
        }),
    });
}

// ---- Nav: a list of articles that push a detail page ----
fn nav_page(f: *Frame, app: *App, safe_top: f32) *Node {
    const rows = f.arena.alloc(*Node, articles.len) catch return zigui.text("oom", .{});
    for (articles, 0..) |art, i| {
        app.item_ctx[i] = .{ .app = app, .idx = i };
        rows[i] = article_row(art, &app.item_ctx[i]);
    }
    const content = zigui.col(.{}, &.{
        top_gap(safe_top),
        zigui.col(.{ .pad = .lg, .gap = .md }, rows),
        bottom_gap(),
    });
    return page(&app.scrolls[1], f, "Nav", content);
}

fn article_row(art: Article, ctx: *ItemCtx) *Node {
    const cfg = Config{
        .bg = card_bg,
        .radius = 14,
        .pad = .lg,
        .gap = .sm,
        .on_click = open_article,
        .click_ctx = @ptrCast(ctx),
    };
    return zigui.col(cfg, &.{
        zigui.text(art.title, .{ .size = 17, .weight = .semi_bold }),
        zigui.text(art.summary, .{ .size = 14, .color = muted }),
    });
}

// ---- Native: the napi device features ----
fn native_page(f: *Frame, app: *App, safe_top: f32) *Node {
    const lvl = zigui.napi.device.battery_level();
    const chg: []const u8 = if (zigui.napi.device.charging()) " - charging" else "";
    const bat = std.fmt.allocPrint(f.arena, "Battery {d}%{s}", .{ lvl, chg }) catch "Battery";
    const net: []const u8 = switch (zigui.napi.device.network()) {
        .none => "none",
        .wifi => "wifi",
        .cellular => "cellular",
        .other => "other",
    };
    const net_txt = std.fmt.allocPrint(f.arena, "Network: {s}", .{net}) catch "Network";
    const cl = app.clip[0..app.clip_len];
    const clip = std.fmt.allocPrint(f.arena, "Clipboard: {s}", .{cl}) catch "Clipboard";
    const ext: []const u8 = if (zigui.napi.clipboard.changed()) "yes" else "no";
    const ext_txt = std.fmt.allocPrint(f.arena, "External change: {s}", .{ext}) catch "?";
    if (zigui.napi.biometric.result()) |o| app.bio = if (o == .success) .success else .failed;
    const bio_txt = switch (app.bio) {
        .success => "Face ID: success",
        .failed => "Face ID: failed",
        .untried => "Face ID: not tried",
    };
    const picking = zigui.napi.picker.pending();
    if (zigui.napi.picker.take_file()) |pf| store_pick(app, pf);
    const nm = app.picked_name[0..app.picked_name_len];
    const pick_text = if (app.picked_name_len > 0)
        std.fmt.allocPrint(f.arena, "Picked: {s}", .{nm}) catch "Picked"
    else
        "No file picked yet";
    const pick_node = if (picking)
        zigui.spinner(12, ios_title)
    else
        zigui.button("Pick a file", .{ .on_click = zigui.on(App, pick_file) });
    const content = zigui.col(.{}, &.{
        top_gap(safe_top),
        zigui.col(.{ .pad = .lg, .gap = .md }, &.{
            section("DEVICE"),
            zigui.text(bat, .{ .size = 16 }),
            zigui.text(net_txt, .{ .size = 16 }),
            section("CLIPBOARD"),
            zigui.button("Copy \"zigui\"", .{ .on_click = zigui.on(App, copy_text) }),
            zigui.text(clip, .{ .size = 14, .color = muted }),
            zigui.text(ext_txt, .{ .size = 14, .color = muted }),
            section("LINKS"),
            zigui.button("Share text", .{ .on_click = zigui.on(App, share) }),
            zigui.button("Open ziglang.org", .{ .on_click = zigui.on(App, open_zig) }),
            zigui.button("Send SMS", .{ .on_click = zigui.on(App, send_sms) }),
            section("FILES"),
            pick_node,
            zigui.text(pick_text, .{ .size = 14, .color = muted }),
            section("HAPTICS"),
            zigui.button("Buzz", .{ .on_click = zigui.on(App, buzz) }),
            section("DISPLAY"),
            zigui.toggle(app.awake, "Keep awake", .{ .on_change = zigui.on(App, set_awake) }),
            zigui.text("Brightness", .{ .size = 14, .color = muted }),
            zigui.slider(&app.bright_vals, &app.bright_slider, .{
                .on_change = zigui.on_at(App, set_bright),
            }),
            section("SECURITY"),
            zigui.button("Authenticate", .{ .on_click = zigui.on(App, do_auth) }),
            zigui.text(bio_txt, .{ .size = 14, .color = muted }),
            section("PERMISSIONS"),
            zigui.button("Request camera", .{ .on_click = zigui.on(App, req_camera) }),
            zigui.text(perm_text(f, "camera", "Camera"), .{ .size = 14, .color = muted }),
            zigui.button("Request photos", .{ .on_click = zigui.on(App, req_photos) }),
            zigui.text(perm_text(f, "photos", "Photos"), .{ .size = 14, .color = muted }),
            zigui.button("Request notifications", .{ .on_click = zigui.on(App, req_notif) }),
            zigui.text(
                perm_text(f, "notifications", "Notifications"),
                .{ .size = 14, .color = muted },
            ),
            zigui.button("Request location", .{ .on_click = zigui.on(App, req_location) }),
            zigui.text(perm_text(f, "location", "Location"), .{ .size = 14, .color = muted }),
            section("NOTIFICATIONS"),
            zigui.button("Post notification", .{ .on_click = zigui.on(App, post_notif) }),
            zigui.button("Show toast", .{ .on_click = zigui.on(App, show_toast) }),
        }),
        bottom_gap(),
    });
    return page(&app.scrolls[2], f, "Native", content);
}

// ---- Kit: a sampling of the widget kit ----
fn kit_page(f: *Frame, app: *App, safe_top: f32) *Node {
    // The page-level click blurs the native text editor when a tap misses every field.
    const body = zigui.col(.{ .pad = .lg, .gap = .md, .on_click = zigui.on(App, blur_input) }, &.{
        section("BUTTONS"),
        zigui.row(.{ .gap = .sm, .wrap = true }, &.{
            zigui.button("Primary", .{ .on_click = zigui.on(App, buzz) }),
            zigui.button("Secondary", .{ .on_click = zigui.on(App, buzz) }),
        }),
        section("BADGES"),
        zigui.row(.{ .gap = .sm, .wrap = true }, &.{
            zigui.badge("Default", .default),
            zigui.badge("Secondary", .secondary),
            zigui.badge("Destructive", .destructive),
        }),
        section("AVATAR"),
        zigui.row(.{ .gap = .sm, .cross = .center }, &.{
            zigui.avatar("RZ", 40),
            zigui.avatar("AB", 40),
        }),
        section("SWITCH"),
        zigui.toggle(app.kit_toggle, "Wi-Fi", .{ .on_change = zigui.on(App, flip_toggle) }),
        section("CHECKBOX"),
        zigui.checkbox(app.kit_check, "Subscribe", .{ .on_change = zigui.on(App, flip_check) }),
        section("SLIDER"),
        zigui.slider(&app.kit_slider_vals, &app.kit_slider, .{
            .on_change = zigui.on_at(App, set_slider),
        }),
        section("PROGRESS"),
        zigui.progress(0.6, 8),
        section("TEXT INPUT"),
        zigui.text_input(&app.kit_input, .{
            .placeholder = "Type your name",
            .focused = app.kit_focus == 1,
            .id = 1,
            .on_focus = zigui.on(App, focus_input),
        }),
        section("SEGMENTED"),
        zigui.toggle_group(&.{
            seg_item(.align_left, app.kit_align == 0, zigui.on(App, seg0), app),
            seg_item(.align_center, app.kit_align == 1, zigui.on(App, seg1), app),
            seg_item(.align_right, app.kit_align == 2, zigui.on(App, seg2), app),
        }, .{ .variant = .outline, .connected = true }),
        section("DONUT"),
        zigui.donut(.{
            .theme = f.theme,
            .slices = &donut_slices,
            .inner_ratio = 0.62,
        }, 180),
    });
    const content = zigui.col(.{}, &.{ top_gap(safe_top), body, bottom_gap() });
    return page(&app.scrolls[3], f, "Kit", content);
}

// ---- About: who + where ----
fn about_page(f: *Frame, app: *App, safe_top: f32) *Node {
    const vbuf = f.arena.alloc(u8, 32) catch return zigui.text("oom", .{});
    const v = zigui.napi.device.app_version(vbuf); // the iOS app's bundle version
    const ver = if (v.len > 0) v else "unknown";
    const content = zigui.col(.{}, &.{
        top_gap(safe_top),
        zigui.col(.{ .pad = .lg, .gap = .md }, &.{
            zigui.text("zigui", .{ .size = 28, .weight = .bold }),
            zigui.text(
                "A native GPU UI toolkit for Zig. One kit across macOS, Windows, " ++
                    "Linux, Android and iOS.",
                .{ .size = 15, .color = muted },
            ),
            section("APP VERSION"),
            zigui.text(ver, .{ .size = 15 }),
            section("LINKS"),
            zigui.button("GitHub", .{ .on_click = zigui.on(App, open_github) }),
            zigui.button("Share zigui", .{ .on_click = zigui.on(App, share) }),
        }),
        bottom_gap(),
    });
    return page(&app.scrolls[4], f, "About", content);
}

// ---- the pushed detail page (an article) ----
fn detail_body(f: *Frame, app: *App, safe_top: f32) *Node {
    const art = articles[@min(app.detail_idx, articles.len - 1)];
    const content = zigui.col(.{}, &.{
        zigui.col(.{ .height = safe_top + 58 }, &.{}), // under the circle buttons
        zigui.col(.{ .pad = .lg, .gap = .md }, &.{
            zigui.text(art.title, .{ .size = 30, .weight = .bold }),
            zigui.text(art.body, .{ .size = 16, .color = ios_title }),
        }),
        bottom_gap(),
    });
    return zigui.col(.{}, &.{
        zigui.scroll(&app.detail_list, .{ .height = f.size.height }, content),
        zigui.top_bar(art.title, .{
            .style = .none,
            .frost = false,
            .on_back = zigui.on(App, go_back),
            .on_action = zigui.on(App, share),
            .action_icon = .share,
        }),
    });
}

fn select_tab(app: *App, i: usize) void {
    zigui.napi.haptics.vibrate(8); // a light tap on each tab switch
    app.detail = false; // a tab tap leaves any pushed detail page
    app.tab = i;
}
fn open_article(ctx: ?*anyopaque) void {
    const ic: *ItemCtx = @ptrCast(@alignCast(ctx orelse return));
    ic.app.detail_idx = ic.idx;
    ic.app.detail = true;
}
fn go_back(app: *App) void {
    app.detail = false;
}
fn copy_text(app: *App) void {
    zigui.napi.clipboard.write("zigui");
    zigui.napi.haptics.vibrate(10);
    app.clip_len = zigui.napi.clipboard.read(&app.clip).len; // read back our own write
}
fn share(app: *App) void {
    _ = app;
    zigui.napi.links.share_text("Shared from zigui");
}
fn open_zig(app: *App) void {
    _ = app;
    zigui.napi.links.open_url("https://ziglang.org");
}
fn send_sms(app: *App) void {
    _ = app;
    zigui.napi.sms.send("12345", "Hello from zigui!");
}
fn pick_file(app: *App) void {
    _ = app;
    zigui.napi.picker.open_file();
}
fn buzz(app: *App) void {
    _ = app;
    zigui.napi.haptics.vibrate(20);
}
fn set_awake(app: *App) void {
    app.awake = !app.awake;
    zigui.napi.display.keep_awake(app.awake);
}
fn set_bright(app: *App, i: usize, v: f32) void {
    app.bright_vals[i] = v;
    zigui.napi.display.brightness(v);
}
fn do_auth(app: *App) void {
    _ = app;
    zigui.napi.biometric.authenticate("Authenticate", "Unlock the zigui demo");
}
fn req_camera(app: *App) void {
    _ = app;
    zigui.napi.permissions.request("camera");
}
fn req_photos(app: *App) void {
    _ = app;
    zigui.napi.permissions.request("photos");
}
fn req_notif(app: *App) void {
    _ = app;
    zigui.napi.permissions.request("notifications");
}
fn post_notif(app: *App) void {
    _ = app;
    zigui.napi.notifications.post("zigui", "Hello from the zigui demo!");
}
fn req_location(app: *App) void {
    _ = app;
    zigui.napi.permissions.request("location");
}
fn show_toast(app: *App) void {
    _ = app;
    zigui.napi.notifications.toast("Toast from zigui!");
}
fn perm_text(f: *Frame, name: []const u8, label: []const u8) []const u8 {
    const w: []const u8 = switch (zigui.napi.permissions.status(name)) {
        .granted => "granted",
        .not_requested => "not requested",
        .declined => "declined",
        .declined_permanent => "denied",
    };
    return std.fmt.allocPrint(f.arena, "{s}: {s}", .{ label, w }) catch label;
}
fn flip_toggle(app: *App) void {
    app.kit_toggle = !app.kit_toggle;
}
fn flip_check(app: *App) void {
    app.kit_check = !app.kit_check;
}
fn set_slider(app: *App, i: usize, v: f32) void {
    app.kit_slider_vals[i] = v;
}
fn open_github(app: *App) void {
    _ = app;
    zigui.napi.links.open_url("https://github.com/qoinly/zigui");
}
fn focus_input(app: *App) void {
    app.kit_focus = 1;
}
fn blur_input(app: *App) void {
    app.kit_focus = 0;
}
fn seg0(app: *App) void {
    app.kit_align = 0;
}
fn seg1(app: *App) void {
    app.kit_align = 1;
}
fn seg2(app: *App) void {
    app.kit_align = 2;
}
fn seg_item(ic: zigui.Icon, on: bool, cb: zigui.ClickFn, app: *App) SegItem {
    return .{ .icon = ic, .on = on, .on_toggle = cb, .ctx = app };
}
// Stash the picked file's name; the local path is in pf.path for a caller to read.
fn store_pick(app: *App, pf: zigui.napi.picker.PickedFile) void {
    app.picked_name_len = @min(pf.name.len, app.picked_name.len);
    @memcpy(app.picked_name[0..app.picked_name_len], pf.name[0..app.picked_name_len]);
    app.picked_len = @min(pf.path.len, app.picked.len);
    @memcpy(app.picked[0..app.picked_len], pf.path[0..app.picked_len]);
}
