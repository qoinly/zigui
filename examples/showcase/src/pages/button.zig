const std = @import("std");
const zigui = @import("zigui");
const Node = zigui.Node;
const Frame = zigui.Frame;
const App = @import("../app.zig").App;
const page = @import("../scaffold/page.zig");

fn inc(app: *App) void {
    app.forms.counter += 1;
}
fn dec(app: *App) void {
    app.forms.counter -= 1;
}

pub fn view(f: *Frame, app: *App) *Node {
    const t = f.theme;
    const count = std.fmt.allocPrint(f.arena, "{d}", .{app.forms.counter}) catch "0";
    const phase: f32 = @floatCast(@mod(f.time * 1.2, 1.0));
    zigui.animate(); // keep the loading spinners advancing
    return page.page(&.{
        page.header("Button", "Trigger an action or event."),
        page.section(t, "Counter", &.{
            zigui.button("", .{
                .variant = .outline,
                .size = .icon,
                .icon = .minus,
                .on_click = zigui.on(App, dec),
            }),
            zigui.col(.{ .width = 48, .cross = .center }, &.{
                zigui.text(count, .{ .size = 20, .weight = .semi_bold }),
            }),
            zigui.button("", .{
                .variant = .outline,
                .size = .icon,
                .icon = .plus,
                .on_click = zigui.on(App, inc),
            }),
            zigui.text("Click to change the count live.", .{ .size = 12, .muted = true }),
        }),
        page.section(t, "Variants", &.{
            zigui.button("Default", .{}),
            zigui.button("Secondary", .{ .variant = .secondary }),
            zigui.button("Destructive", .{ .variant = .destructive }),
            zigui.button("Outline", .{ .variant = .outline }),
            zigui.button("Ghost", .{ .variant = .ghost }),
            zigui.button("Link", .{ .variant = .link }),
        }),
        page.section(t, "Sizes", &.{
            zigui.button("Small", .{ .size = .sm }),
            zigui.button("Default", .{ .size = .default }),
            zigui.button("Large", .{ .size = .lg }),
            zigui.button("", .{ .size = .icon, .icon = .plus }),
        }),
        page.section(t, "With icon", &.{
            zigui.button("Download", .{ .icon = .arrow_down_to_line }),
            zigui.button("Add item", .{ .variant = .outline, .icon = .plus }),
        }),
        page.section(t, "Loading", &.{
            zigui.button("Saving", .{ .loading = true, .spin_phase = phase }),
            zigui.button("Please wait", .{
                .variant = .outline,
                .loading = true,
                .spin_phase = phase,
            }),
            zigui.button("", .{
                .variant = .secondary,
                .size = .icon,
                .loading = true,
                .spin_phase = phase,
            }),
        }),
        page.section(t, "Disabled", &.{
            zigui.button("Disabled", .{ .disabled = true }),
            zigui.button("Outline", .{ .variant = .outline, .disabled = true }),
        }),
    });
}
