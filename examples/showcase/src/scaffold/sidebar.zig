const std = @import("std");
const zigui = @import("zigui");
const Node = zigui.Node;
const Frame = zigui.Frame;
const App = @import("../app.zig").App;
const Entry = zigui.SidebarEntry;

const MIN_W: f32 = 200;
const MAX_W: f32 = 360;
const COLLAPSE_SLOP: f32 = 40; // drag below MIN_W by this much to snap to the rail

const FORMS_KIDS = [_]Entry{
    .{ .kind = .item, .id = "button", .label = "Button" },
    .{ .kind = .item, .id = "input", .label = "Input" },
    .{ .kind = .item, .id = "textarea", .label = "Textarea" },
    .{ .kind = .item, .id = "checkbox", .label = "Checkbox" },
    .{ .kind = .item, .id = "toggle", .label = "Switch" },
    .{ .kind = .item, .id = "toggle_btn", .label = "Toggle" },
    .{ .kind = .item, .id = "toggle_grp", .label = "Toggle Group" },
    .{ .kind = .item, .id = "radio", .label = "Radio Group" },
    .{ .kind = .item, .id = "select", .label = "Select" },
    .{ .kind = .item, .id = "slider", .label = "Slider" },
};
const DISPLAY_KIDS = [_]Entry{
    .{ .kind = .item, .id = "icons", .label = "Icons" },
    .{ .kind = .item, .id = "badge", .label = "Badge" },
    .{ .kind = .item, .id = "card", .label = "Card" },
    .{ .kind = .item, .id = "avatar", .label = "Avatar" },
    .{ .kind = .item, .id = "spinner", .label = "Spinner" },
    .{ .kind = .item, .id = "progress", .label = "Progress" },
    .{ .kind = .item, .id = "skeleton", .label = "Skeleton" },
    .{ .kind = .item, .id = "separator", .label = "Separator" },
    .{ .kind = .item, .id = "tabbar", .label = "Tab Bar" },
    .{ .kind = .item, .id = "menu", .label = "Menu" },
    .{ .kind = .item, .id = "kbd", .label = "Kbd" },
    .{ .kind = .item, .id = "resizable", .label = "Resizable", .badge = "new" },
};
const CHART_KIDS = [_]Entry{
    .{ .kind = .item, .id = "chart_line", .label = "Line" },
    .{ .kind = .item, .id = "chart_bar", .label = "Bar" },
    .{ .kind = .item, .id = "chart_area", .label = "Area" },
    .{ .kind = .item, .id = "chart_pie", .label = "Pie" },
};
const FEEDBACK_KIDS = [_]Entry{
    .{ .kind = .item, .id = "alert", .label = "Alert" },
    .{ .kind = .item, .id = "toast", .label = "Toast" },
    .{ .kind = .item, .id = "tooltip", .label = "Tooltip" },
    .{ .kind = .item, .id = "popover", .label = "Popover" },
    .{ .kind = .item, .id = "dialog", .label = "Dialog" },
    .{ .kind = .item, .id = "sheet", .label = "Sheet" },
    .{ .kind = .item, .id = "tabs", .label = "Tabs" },
};

fn select(app: *App, id: []const u8) void {
    app.nav.selected_id = id; // item ids are static literals, safe to store
}

fn disclose(app: *App, id: []const u8, open: bool) void {
    if (std.mem.eql(u8, id, "grp_forms")) {
        app.groups.forms = open;
    } else if (std.mem.eql(u8, id, "grp_display")) {
        app.groups.display = open;
    } else if (std.mem.eql(u8, id, "grp_chart")) {
        app.groups.chart = open;
    } else if (std.mem.eql(u8, id, "grp_feedback")) {
        app.groups.feedback = open;
    }
}

// The sidebar sits at the window left, so the drag cursor x is the new width.
fn resize(app: *App, x: f32, _: f32) void {
    if (x < MIN_W - COLLAPSE_SLOP) {
        app.sidebar_collapsed = true;
        return;
    }
    app.sidebar_collapsed = false;
    app.sidebar_w = std.math.clamp(x, MIN_W, MAX_W);
}

pub fn view(f: *Frame, app: *App) *Node {
    _ = f;
    return zigui.sidebar(.{
        .items = &.{
            .{ .kind = .group, .label = "Overview" },
            .{ .kind = .item, .id = "dashboard", .label = "Dashboard", .icon = .grid },
            .{ .kind = .group, .label = "Components" },
            .{
                .kind = .item,
                .id = "grp_forms",
                .label = "Forms",
                .icon = .copy,
                .expanded = app.groups.forms,
                .children = &FORMS_KIDS,
            },
            .{
                .kind = .item,
                .id = "grp_display",
                .label = "Display",
                .icon = .layout_grid,
                .expanded = app.groups.display,
                .children = &DISPLAY_KIDS,
            },
            .{
                .kind = .item,
                .id = "grp_chart",
                .label = "Chart",
                .icon = .chart_bar,
                .expanded = app.groups.chart,
                .children = &CHART_KIDS,
            },
            .{
                .kind = .item,
                .id = "grp_feedback",
                .label = "Feedback",
                .icon = .bell_badge,
                .expanded = app.groups.feedback,
                .children = &FEEDBACK_KIDS,
            },
        },
        .state = &app.nav,
        .scroll = &app.nav_scroll,
        .width = app.sidebar_w,
        .collapsed = app.sidebar_collapsed,
        .on_select = zigui.on_id(App, select),
        .on_disclose = zigui.on_disclose(App, disclose),
        .on_resize = zigui.on_drag(App, resize),
    });
}
