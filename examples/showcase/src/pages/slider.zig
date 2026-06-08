const zigui = @import("zigui");
const Node = zigui.Node;
const Frame = zigui.Frame;
const App = @import("../app.zig").App;
const page = @import("../scaffold/page.zig");
const SliderState = zigui.kit.slider.SliderState;
const ChangeAt = zigui.kit.slider.ChangeAtFn;

fn set_single(app: *App, i: usize, v: f32) void {
    app.forms.sl_single[i] = v;
}
fn set_range(app: *App, i: usize, v: f32) void {
    app.forms.sl_range[i] = v;
}
fn set_step(app: *App, i: usize, v: f32) void {
    app.forms.sl_step[i] = v;
}

fn sl_row(
    values: []const f32,
    state: *SliderState,
    step: f32,
    disabled: bool,
    hint: []const u8,
    on_change: ?ChangeAt,
) *Node {
    return zigui.row(.{ .gap = .md, .cross = .center, .wrap = true }, &.{
        zigui.col(.{ .grow = 1, .min_width = 140, .max_width = 320 }, &.{
            zigui.slider(values, state, .{
                .step = step,
                .disabled = disabled,
                .on_change = on_change,
            }),
        }),
        zigui.text(hint, .{ .size = 12, .muted = true }),
    });
}

pub fn view(f: *Frame, app: *App) *Node {
    const d = &app.forms;
    const t = f.theme;
    return page.page(&.{
        page.header("Slider", "Pick a value from a range."),
        page.section(t, "Single", &.{sl_row(
            &d.sl_single,
            &d.st_single,
            0,
            false,
            "Drag or click",
            zigui.on_at(App, set_single),
        )}),
        page.section(t, "Range", &.{
            sl_row(&d.sl_range, &d.st_range, 0, false, "Two thumbs", zigui.on_at(App, set_range)),
        }),
        page.section(t, "Stepped (10%)", &.{sl_row(
            &d.sl_step,
            &d.st_step,
            0.1,
            false,
            "Snaps to detents",
            zigui.on_at(App, set_step),
        )}),
        page.section(t, "Disabled", &.{
            sl_row(&d.sl_disabled, &d.st_disabled, 0, true, "No interaction", null),
        }),
    });
}
