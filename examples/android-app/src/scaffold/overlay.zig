const zigui = @import("zigui");
const Node = zigui.Node;
const Frame = zigui.Frame;
const App = @import("../app.zig").App;

fn dialog_close(app: *App) void {
    app.dialog_open = false;
}
fn dialog_confirm(app: *App) void {
    app.dialog_open = false;
    app.toast("Confirmed", .success);
}
fn sheet_close(app: *App) void {
    app.sheet_open = false; // sheet_t eases to 0 over the next frames, sliding it out
}

// The modal layer: the eased edge sheet owns it while sliding, else the dialog frosts
// the backdrop and blocks the body. Both are kit-rendered (GPU), not native Android.
pub fn view(f: *Frame, app: *App) ?*Node {
    const target: f32 = if (app.sheet_open) 1 else 0;
    app.sheet_t += (target - app.sheet_t) * 0.25;
    if (@abs(target - app.sheet_t) < 0.005) app.sheet_t = target;
    if (app.sheet_t != target) zigui.animate(); // keep ticking while it slides
    if (app.sheet_t > 0.001) {
        return zigui.sheet(.{
            .side = .bottom,
            .open_t = app.sheet_t,
            .top_inset = f.body.origin.y,
            .title = "Edit profile",
            .description = "A kit sheet sliding from the bottom edge.",
            .dismiss = app.sheet_open,
            .on_close = zigui.on(App, sheet_close),
        });
    }
    app.sheet_open = false; // fully closed
    if (!app.dialog_open) return null;
    return zigui.dialog(.{
        .width = 288, // fit a phone screen (the 420 default overflows)
        .title = "Delete this?",
        .description = "This kit dialog interrupts for a decision.",
        .actions = &.{
            .{
                .label = "Cancel",
                .variant = .outline,
                .on_click = zigui.on(App, dialog_close),
            },
            .{
                .label = "Delete",
                .variant = .destructive,
                .on_click = zigui.on(App, dialog_confirm),
            },
        },
        .on_dismiss = zigui.on(App, dialog_close),
    });
}
