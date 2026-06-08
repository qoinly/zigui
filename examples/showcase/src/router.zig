const std = @import("std");
const zigui = @import("zigui");
const Node = zigui.Node;
const Frame = zigui.Frame;
const App = @import("app.zig").App;
const dashboard_page = @import("pages/dashboard.zig");
const dialog_page = @import("pages/dialog.zig");
const button_page = @import("pages/button.zig");
const checkbox_page = @import("pages/checkbox.zig");
const switch_page = @import("pages/switch.zig");
const toggle_page = @import("pages/toggle.zig");
const toggle_group_page = @import("pages/toggle_group.zig");
const radio_page = @import("pages/radio.zig");
const slider_page = @import("pages/slider.zig");
const input_page = @import("pages/input.zig");
const select_page = @import("pages/select.zig");
const textarea_page = @import("pages/textarea.zig");
const icons_page = @import("pages/icons.zig");
const badge_page = @import("pages/badge.zig");
const card_page = @import("pages/card.zig");
const avatar_page = @import("pages/avatar.zig");
const spinner_page = @import("pages/spinner.zig");
const progress_page = @import("pages/progress.zig");
const skeleton_page = @import("pages/skeleton.zig");
const separator_page = @import("pages/separator.zig");
const tabbar_page = @import("pages/tabbar.zig");
const menu_page = @import("pages/menu.zig");
const kbd_page = @import("pages/kbd.zig");
const resizable_page = @import("pages/resizable.zig");
const alert_page = @import("pages/alert.zig");
const toast_page = @import("pages/toast.zig");
const tooltip_page = @import("pages/tooltip.zig");
const popover_page = @import("pages/popover.zig");
const sheet_page = @import("pages/sheet.zig");
const tabs_page = @import("pages/tabs.zig");
const chart_page = @import("pages/chart.zig");

// Dispatch by the sidebar's selected id (the kit.sidebar item ids); an id with no
// matching page falls through to the placeholder.
pub fn view(f: *Frame, app: *App) *Node {
    const id = app.nav.selected_id;
    const eql = std.mem.eql;
    if (eql(u8, id, "dashboard")) return dashboard_page.view(f, app);
    if (eql(u8, id, "dialog")) return dialog_page.view(f, app);
    if (eql(u8, id, "button")) return button_page.view(f, app);
    if (eql(u8, id, "checkbox")) return checkbox_page.view(f, app);
    if (eql(u8, id, "toggle")) return switch_page.view(f, app);
    if (eql(u8, id, "toggle_btn")) return toggle_page.view(f, app);
    if (eql(u8, id, "toggle_grp")) return toggle_group_page.view(f, app);
    if (eql(u8, id, "radio")) return radio_page.view(f, app);
    if (eql(u8, id, "slider")) return slider_page.view(f, app);
    if (eql(u8, id, "input")) return input_page.view(f, app);
    if (eql(u8, id, "select")) return select_page.view(f, app);
    if (eql(u8, id, "textarea")) return textarea_page.view(f, app);
    if (eql(u8, id, "icons")) return icons_page.view(f, app);
    if (eql(u8, id, "badge")) return badge_page.view(f, app);
    if (eql(u8, id, "card")) return card_page.view(f, app);
    if (eql(u8, id, "avatar")) return avatar_page.view(f, app);
    if (eql(u8, id, "spinner")) return spinner_page.view(f, app);
    if (eql(u8, id, "progress")) return progress_page.view(f, app);
    if (eql(u8, id, "skeleton")) return skeleton_page.view(f, app);
    if (eql(u8, id, "separator")) return separator_page.view(f, app);
    if (eql(u8, id, "tabbar")) return tabbar_page.view(f, app);
    if (eql(u8, id, "menu")) return menu_page.view(f, app);
    if (eql(u8, id, "kbd")) return kbd_page.view(f, app);
    if (eql(u8, id, "resizable")) return resizable_page.view(f, app);
    if (eql(u8, id, "alert")) return alert_page.view(f, app);
    if (eql(u8, id, "toast")) return toast_page.view(f, app);
    if (eql(u8, id, "tooltip")) return tooltip_page.view(f, app);
    if (eql(u8, id, "popover")) return popover_page.view(f, app);
    if (eql(u8, id, "sheet")) return sheet_page.view(f, app);
    if (eql(u8, id, "tabs")) return tabs_page.view(f, app);
    if (eql(u8, id, "chart_line")) return chart_page.line(f, app);
    if (eql(u8, id, "chart_bar")) return chart_page.bar(f, app);
    if (eql(u8, id, "chart_area")) return chart_page.area(f, app);
    if (eql(u8, id, "chart_pie")) return chart_page.pie(f, app);
    return placeholder(id);
}

fn placeholder(id: []const u8) *Node {
    return zigui.col(.{ .pad = .lg, .gap = .sm }, &.{
        zigui.text(id, .{ .size = 24, .weight = .semi_bold }),
        zigui.text("This page lands with its batch.", .{ .size = 13, .muted = true }),
    });
}
