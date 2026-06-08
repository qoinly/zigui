const std = @import("std");
const zigui = @import("zigui");
const Node = zigui.Node;
const Frame = zigui.Frame;
const App = @import("../app.zig").App;
const page = @import("../scaffold/page.zig");

const ta = zigui.kit.textarea;

const TA_PLAIN_INIT =
    "Edit me.\nThis text area renders its own glyphs - no native\nNSTextField. Type, select, undo.";
const TA_JSON_INIT =
    \\{
    \\  "name": "Pedro",
    \\  "active": true,
    \\  "score": 42
    \\}
;

// The App holds the buffers by value; a by-value init can't point a TextBuffer at
// its own bytes, so seed lazily on first render.
fn seed(app: *App) void {
    const fr = &app.forms;
    if (fr.ta_seeded) return;
    @memcpy(fr.ta_plain_buf[0..TA_PLAIN_INIT.len], TA_PLAIN_INIT);
    fr.ta_plain = .{ .buf = .{ .bytes = &fr.ta_plain_buf, .len = TA_PLAIN_INIT.len } };
    @memcpy(fr.ta_json_buf[0..TA_JSON_INIT.len], TA_JSON_INIT);
    fr.ta_json = .{ .buf = .{ .bytes = &fr.ta_json_buf, .len = TA_JSON_INIT.len } };
    fr.ta_seeded = true;
}

// JSON tokeniser feeding the span hook. The edit_seq gate skips the re-tokenise
// when the buffer is unchanged, so the shape cache survives idle frames.
fn retokenize(app: *App) void {
    const fr = &app.forms;
    if (fr.ta_json.buf.edit_seq == fr.ta_span_seq) return;
    const s = fr.ta_json.buf.slice();
    const KEY = zigui.Rgba.from_hex(0x7DD3FC);
    const STR = zigui.Rgba.from_hex(0x86EFAC);
    const NUM = zigui.Rgba.from_hex(0xFCA5A5);
    const LIT = zigui.Rgba.from_hex(0xC4B5FD);
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len and n < fr.ta_spans.len) {
        const c = s[i];
        if (c == '"') {
            const start = i;
            i += 1;
            while (i < s.len and s[i] != '"') : (i += 1) {
                if (s[i] == '\\' and i + 1 < s.len) i += 1;
            }
            if (i < s.len) i += 1;
            var j = i;
            while (j < s.len and (s[j] == ' ' or s[j] == '\t')) j += 1;
            const scol = if (j < s.len and s[j] == ':') KEY else STR;
            fr.ta_spans[n] = .{ .start = @intCast(start), .end = @intCast(i), .color = scol };
            n += 1;
        } else if (c == '-' or (c >= '0' and c <= '9')) {
            const start = i;
            i += 1;
            while (i < s.len and ((s[i] >= '0' and s[i] <= '9') or s[i] == '.')) : (i += 1) {}
            fr.ta_spans[n] = .{ .start = @intCast(start), .end = @intCast(i), .color = NUM };
            n += 1;
        } else if (c == 't' or c == 'f' or c == 'n') {
            const rest = s[i..];
            var lit: usize = 0;
            if (std.mem.startsWith(u8, rest, "true")) {
                lit = 4;
            } else if (std.mem.startsWith(u8, rest, "false")) {
                lit = 5;
            } else if (std.mem.startsWith(u8, rest, "null")) {
                lit = 4;
            }
            if (lit > 0) {
                const s0: u32 = @intCast(i);
                const e: u32 = @intCast(i + lit);
                fr.ta_spans[n] = .{ .start = s0, .end = e, .color = LIT, .weight = .medium };
                n += 1;
                i += lit;
            } else i += 1;
        } else i += 1;
    }
    fr.ta_span_n = n;
    fr.ta_span_seq = fr.ta_json.buf.edit_seq;
}

fn focus_plain(app: *App) void {
    app.forms.ta_plain.focused = true;
    app.forms.ta_json.focused = false;
}
fn focus_json(app: *App) void {
    app.forms.ta_json.focused = true;
    app.forms.ta_plain.focused = false;
}
fn blur(app: *App) void {
    app.forms.ta_plain.focused = false;
    app.forms.ta_json.focused = false;
}

fn field(kid: *Node) *Node {
    return zigui.col(.{ .max_width = 620 }, &.{kid});
}

pub fn view(f: *Frame, app: *App) *Node {
    _ = f;
    seed(app);
    retokenize(app);
    const fr = &app.forms;
    // A click that misses both editors blurs them.
    return zigui.col(.{ .grow = 1, .on_click = zigui.on(App, blur) }, &.{
        page.page(&.{
            page.header("Textarea", "A multi-line editor that renders its own glyphs."),
            zigui.col(.{ .gap = .sm }, &.{
                page.title_label("Plain"),
                field(zigui.textarea(&fr.ta_plain, .{
                    .on_focus = zigui.on(App, focus_plain),
                })),
            }),
            zigui.col(.{ .gap = .sm }, &.{
                page.title_label("Syntax highlighting (caller-supplied spans)"),
                field(zigui.textarea(&fr.ta_json, .{
                    .spans = fr.ta_spans[0..fr.ta_span_n],
                    .on_focus = zigui.on(App, focus_json),
                })),
            }),
        }),
    });
}
