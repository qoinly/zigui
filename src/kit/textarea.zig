const std = @import("std");
const builtin = @import("builtin");
const types = @import("../window/types.zig");
const color = @import("../color.zig");
const text_system = @import("../text_system.zig");
const builder = @import("../render/builder.zig");
const RenderError = builder.RenderError;
const label = @import("../render/label.zig");
const icon = @import("../render/icon.zig");
const primitives = @import("../primitives.zig");
const custom_paint = @import("../window/paint.zig");
const custom_shell = @import("../custom_shell.zig");
const tr = @import("theme_resolve.zig");

pub const RenderBuilder = builder.RenderBuilder;
pub const Theme = types.Theme;
pub const Rgba = color.Rgba;

// The platform key model surfaces `mods.cmd` as the primary shortcut modifier (Cmd on macOS, Ctrl on
// Linux/Windows) and `mods.alt` as Option/Alt. So caret jumps split by OS: macOS uses Cmd+arrow for
// line/doc and Option+arrow for word; elsewhere Ctrl(=cmd)+arrow jumps by word and Ctrl+Home/End by doc.
const is_mac = builtin.os.tag == .macos;
pub const Quad = primitives.Quad;
pub const SizeF = @import("../geometry.zig").SizeF;
pub const FontWeight = text_system.FontWeight;

pub const MAX_LINES: usize = 4096; // a body past this clamps (asserted cap)
pub const MAX_VIS: usize = 8192; // visual rows (logical lines split by soft wrap); clamps past this
const MAX_FOLDS: usize = 512; // multi-line bracket regions tracked for folding; clamps past this
const MAX_FOLD_DEPTH: usize = 64; // bracket nesting the fold scanner tracks
const TAB: usize = 4; // tab stop width in columns (caret/layout only)
const CARET_W: f32 = 1.5;
const BLINK_PERIOD_S: f64 = 1.0; // caret blink: 0.5s on / 0.5s off
const PASTE_CAP: usize = 4096; // bounded paste scratch; a longer clipboard is UTF-8-trimmed to fit
// Selection has no Theme token; blend background<-ring and force an alpha so the
// band reads behind glyphs. Brighter when focused, dimmer when not.
const SEL_MIX: f32 = 0.5;
const SEL_ALPHA: f32 = 0.30;
const SEL_ALPHA_INACTIVE: f32 = 0.18;
const NL_STUB: f32 = 0.5; // half a glyph past line end marks a selected newline
const UNDO_MAX_OPS: usize = 128; // edit-history depth; oldest group drops past this
const UNDO_ARENA: usize = 4096; // bytes stored for undo (removed + inserted); evicts oldest

// One reversible splice: buffer[pos..pos+ins_len) replaced what was at
// [pos..pos+rem_len). The removed and inserted bytes live in the state's undo
// arena, so undo re-inserts `removed` and redo re-inserts `inserted`.
const UndoOp = struct {
    pos: u32,
    rem_at: u32,
    rem_len: u32,
    ins_at: u32,
    ins_len: u32,
};

// One byte range drawn in a colour/weight. Caller passes spans sorted by `start`
// and non-overlapping; an empty slice draws the whole text in the foreground.
// A syntax highlighter keyed on TextBuffer.edit_seq keeps unchanged text's shape
// cache.
pub const TextSpan = struct {
    start: u32,
    end: u32,
    color: Rgba,
    weight: FontWeight = .normal,
};

// Caller-owned backing store; the kit mutates bytes[0..len] in place, never
// allocs or frees it. edit_seq bumps on each successful insert/delete so the
// line index and a caller's tokeniser can cheaply detect a change.
pub const TextBuffer = struct {
    bytes: []u8, // caller backing store; capacity = bytes.len
    len: usize = 0,
    edit_seq: u64 = 0,

    pub fn slice(self: *const TextBuffer) []const u8 {
        return self.bytes[0..self.len];
    }

    // Rejects the WHOLE insert on overflow - a partial copy could split a
    // codepoint. Returns false if it didn't fit.
    pub fn insert_bytes(self: *TextBuffer, at: usize, text: []const u8) bool {
        std.debug.assert(at <= self.len);
        std.debug.assert(self.len <= self.bytes.len);
        if (text.len == 0) return true;
        if (self.len + text.len > self.bytes.len) return false;
        std.mem.copyBackwards(
            u8,
            self.bytes[at + text.len .. self.len + text.len],
            self.bytes[at..self.len],
        );
        @memcpy(self.bytes[at .. at + text.len], text);
        self.len += text.len;
        self.edit_seq += 1;
        return true;
    }

    pub fn delete_range(self: *TextBuffer, start: usize, end: usize) void {
        std.debug.assert(start <= end);
        std.debug.assert(end <= self.len);
        if (start == end) return;
        std.mem.copyForwards(
            u8,
            self.bytes[start .. self.len - (end - start)],
            self.bytes[end..self.len],
        );
        self.len -= (end - start);
        self.edit_seq += 1;
    }
};

// Cross-frame editor state the CALLER owns and passes by pointer. The line index
// lives here so the kit allocs nothing; glyphs go in the renderer-owned sprite
// list reused across frames.
pub const TextAreaState = struct {
    buf: TextBuffer,
    caret: usize = 0, // byte offset; always on a UTF-8 lead boundary
    goal_col: usize = 0, // sticky column for up/down across short lines
    focused: bool = false,
    full: bool = false, // last insert hit capacity (caller may show a cap hint)
    scroll_y: f32 = 0, // local scroll; not the page's shared paint.scroll_y
    scroll_to_caret: bool = false, // set by goto() so an external caret move scrolls into view

    // Selection: the fixed end (UTF-8 lead boundary). caret is the moving end, so
    // the range is [min(sel_anchor,caret), max). null or ==caret means none.
    sel_anchor: ?usize = null,
    dragging: bool = false, // press sets anchor; drag re-feeds extend caret only
    blink_phase_t0: f64 = 0, // now_s at last caret reset; visibility is a pure fn of the delta
    now_cached: f64 = 0, // paint.now_s copied at render top so the mouse thunks can read it
    drag_autoscroll_dy: f32 = 0, // points/frame a held edge-drag wants to scroll
    last_view_h: f32 = 0, // view height stashed for the drag thunk's exit test

    // Undo/redo: ops [0..undo_count) are the undo stack; [undo_count..undo_total)
    // are undone ops available to redo. A new edit discards the redo tail. The
    // arena holds each op's removed+inserted bytes (in op order, oldest lowest).
    undo_ops: [UNDO_MAX_OPS]UndoOp = undefined,
    undo_count: usize = 0,
    undo_total: usize = 0,
    undo_arena: [UNDO_ARENA]u8 = undefined,
    undo_arena_len: usize = 0,
    undo_coalesce: bool = false, // may the next typed char merge into the top op?

    // edit_seq-gated line index: rebuilt only when the buffer changed, so
    // scroll/blink/hover frames do zero scan work.
    line_starts: [MAX_LINES]u32 = undefined,
    line_count: usize = 1,
    index_seq: u64 = std.math.maxInt(u64), // != any real seq -> first frame builds

    // Visual-row index for soft wrap: each logical line, wrapped to the view
    // width, becomes one or more visual rows. Layout / caret / scroll all run on
    // these; line_starts stays the logical (newline) truth that editing + undo
    // mutate. Rebuilt when the buffer (vis_seq) or the wrap width (vis_cols)
    // changes. vis_cols == 0 disables wrap (the visual index then mirrors the
    // logical one).
    vis_starts: [MAX_VIS]u32 = undefined,
    vis_count: usize = 1,
    vis_seq: u64 = std.math.maxInt(u64),
    vis_cols: usize = 0,

    // Fold regions (multi-line bracket pairs), recomputed when the buffer changes; each is a
    // logical [open_line, close_line] with close_line > open_line. `collapsed` is keyed by open
    // line (kept across rebuilds; may drift on edits above a fold, which is fine — re-toggle).
    fold_open: [MAX_FOLDS]u32 = undefined,
    fold_close: [MAX_FOLDS]u32 = undefined,
    fold_cchar: [MAX_FOLDS]u8 = undefined, // the region's closing bracket, shown in the collapsed marker
    fold_n: usize = 0,
    fold_seq: u64 = std.math.maxInt(u64),
    collapsed: std.StaticBitSet(MAX_LINES) = std.StaticBitSet(MAX_LINES).initEmpty(),
    collapse_seq: u64 = 0, // bumped on every fold toggle so the visual index rebuilds
    vis_collapse_seq: u64 = std.math.maxInt(u64), // collapse_seq the current vis index reflects
    vis_eof_folded: bool = false, // a collapsed region reached the last line; gutter draws a trailing number
    folding_on: bool = false, // stashed from opts each render so edit-path re-indexing folds too

    char_w: f32 = 0, // mono advance, cached per font size
    char_w_size: f32 = 0,

    // Geometry stashed at the end of render, read by the click handler next
    // frame: render writes, the event thunk reads.
    last_text_x: f32 = 0,
    last_text_y: f32 = 0,
    last_line_h: f32 = 0,
    last_fold_x: f32 = 0, // fold-chevron column, so the click thunk can hit-test it
    last_fold_w: f32 = 0,
    // Focus callback stashed from options each frame so the click handler can
    // tell the caller to unfocus its other text areas (only one drains keys).
    on_focus: ?*const fn (ctx: ?*anyopaque) void = null,
    focus_ctx: ?*anyopaque = null,

    // Insert text at the caret (snippet / programmatic), replacing any selection.
    // Funnels through the same recorded chokepoint, so a caller can cmd-Z it.
    // Move the caret to a byte offset (clearing any selection) and request a scroll so the
    // target row comes into view next render. Used by find navigation to jump to a match.
    pub fn goto(self: *TextAreaState, off: usize) void {
        self.sel_anchor = null;
        self.caret = @min(off, self.buf.len);
        self.scroll_to_caret = true;
    }

    // Replace bytes [a, b) with `text` (line index + undo maintained). Used by find & replace.
    pub fn replace_range(self: *TextAreaState, a: usize, b: usize, text: []const u8) void {
        if (a > b or b > self.buf.len) return;
        _ = edit_replace(self, a, b, text, false);
    }

    pub fn insert_at_caret(self: *TextAreaState, text: []const u8) void {
        const sel = sel_range(self);
        _ = edit_replace(
            self,
            if (sel) |r| r.a else self.caret,
            if (sel) |r| r.b else self.caret,
            text,
            false,
        );
    }
};

// Drives an inline completion popup the caller renders (e.g. an editor autocomplete). Zero-cost
// when the option is null. While `open`, the editor routes the navigation keys (Up/Down move the
// selection with wrap, Enter/Tab commit, Esc dismisses) into this struct instead of the caret, so
// those keys never edit text; every other key (typing, backspace) still edits, which lets the
// caller refilter as the user types. The caller owns the struct: set `open`/`count` each frame
// (clamp `selected` to the current count), read `selected` to highlight a row, and consume
// `commit`/`dismiss` (clearing them) to accept or close.
pub const Completion = struct {
    open: bool = false,
    count: u32 = 0,
    selected: u32 = 0,
    commit: bool = false,
    dismiss: bool = false,
};

// Drives snippet tabstops the caller manages (e.g. after accepting a function completion, its
// argument placeholders). While `active`, Tab / Shift+Tab / Esc route into this struct instead of
// indenting the editor, so the caller can move the selection to the next/previous placeholder or
// exit. Typing still edits (the user replaces a placeholder). The caller owns the struct: set
// `active`, place the selection, and consume `next`/`prev`/`cancel` (clearing them).
pub const Snippet = struct {
    active: bool = false,
    next: bool = false,
    prev: bool = false,
    cancel: bool = false,
};

pub const TextAreaOptions = struct {
    state: *TextAreaState,
    spans: []const TextSpan = &.{}, // sorted by start, non-overlapping; empty = plain
    theme: *const Theme,
    paint: *custom_paint.PaintContext,
    font_size: f32 = 13,
    line_spacing: f32 = 1.35,
    pad: f32 = 10,
    read_only: bool = false,
    wrap: bool = true, // soft-wrap long lines to the view width (no h-scroll exists)
    line_numbers: bool = false, // a left gutter numbering logical (newline) lines
    // Find highlighting: byte ranges to band behind the text (search matches); the one at
    // `active_match` reads brighter. Caller navigates by setting caret/sel_anchor to a match.
    match_ranges: []const [2]u32 = &.{},
    active_match: i32 = -1,
    bordered: bool = true, // false = fill only, no border/ring (a code pane in a panel)
    // Code-editor smarts: bracket-pair match highlight, auto-close/skip brackets +
    // quotes, pair backspace, Enter auto-indent, Tab/Shift+Tab indent-dedent. Off =
    // a plain text field (Tab inserts a tab, Enter a bare newline).
    code_edits: bool = false,
    // Code folding: a fold chevron in the gutter for every multi-line {…} / […] region; a click
    // collapses it to its header line. Requires line_numbers. Off = no fold column, no skipping.
    folding: bool = false,
    font_family: []const u8 = "SF Mono",
    on_change: ?*const fn (ctx: ?*anyopaque) void = null,
    on_focus: ?*const fn (ctx: ?*anyopaque) void = null,
    ctx: ?*anyopaque = null,
    // Window-absolute caret rect [x, y, w, h], written every focused frame (zeroed when unfocused)
    // for anchoring an overlay (a completion popup) at the caret. Like a node's rect_out: the value
    // lands during render, so the overlay reads it the next frame.
    caret_out: ?*[4]f32 = null,
    // An inline completion popup's navigation state (see Completion). Null = no popup.
    completion: ?*Completion = null,
    // Snippet tabstop navigation (see Snippet). Null = not in a snippet.
    snippet: ?*Snippet = null,
};

fn is_cont(b: u8) bool {
    return (b & 0xC0) == 0x80; // 0b10xxxxxx UTF-8 continuation byte
}

fn next_boundary(bytes: []const u8, i: usize) usize {
    if (i >= bytes.len) return bytes.len;
    var j = i + 1;
    while (j < bytes.len and is_cont(bytes[j])) j += 1; // bounded: <= 4 steps
    return j;
}

fn prev_boundary(bytes: []const u8, i: usize) usize {
    if (i == 0) return 0;
    var j = i - 1;
    while (j > 0 and is_cont(bytes[j])) j -= 1; // bounded: <= 4 steps
    return j;
}

// The active selection as a half-open byte range, or null. A zero-width anchor
// (anchor == caret) normalises to no-selection so it never paints or copies.
fn sel_range(st: *const TextAreaState) ?struct { a: usize, b: usize } {
    const an = st.sel_anchor orelse return null;
    if (an == st.caret) return null;
    return .{ .a = @min(an, st.caret), .b = @max(an, st.caret) };
}

fn has_sel(st: *const TextAreaState) bool {
    return sel_range(st) != null;
}

fn rebuild_line_index(st: *TextAreaState) void {
    const bytes = st.buf.slice();
    st.line_starts[0] = 0;
    var n: usize = 1;
    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        if (bytes[i] == '\n') {
            if (n >= MAX_LINES) break;
            st.line_starts[n] = @intCast(i + 1);
            n += 1;
        }
    }
    st.line_count = n;
    st.index_seq = st.buf.edit_seq;
}

// Incremental index update after a splice at `pos` that removed `rem_len` bytes
// and inserted `ins` (already applied to the buffer; line_starts still reflects
// the OLD buffer). Entries before pos stay; entries whose newline fell inside the
// removed range drop; new newlines from `ins` splice in; the tail shifts by the
// net byte delta. O(lines after pos + ins.len) vs a full O(buffer) rescan - the
// hot-path win, since typing would otherwise rescan the whole body every
// keystroke. Falls back to a full rebuild when the index is already at the
// MAX_LINES cap or this edit would cross it (rare).
fn update_line_index(st: *TextAreaState, pos: usize, rem_len: usize, ins: []const u8) void {
    const r0 = row_of_offset(st, pos); // line containing pos; line_starts[0..r0] are unchanged
    std.debug.assert(r0 < st.line_count);
    var tail_start = r0 + 1; // first old entry whose newline lay past the removed range
    while (tail_start < st.line_count and st.line_starts[tail_start] <= pos + rem_len) {
        tail_start += 1;
    }
    const tail_len = st.line_count - tail_start;

    var mid: usize = 0;
    for (ins) |c| {
        if (c == '\n') mid += 1;
    }
    const new_count = r0 + 1 + mid + tail_len;
    // A clamped index (line_count pinned at MAX_LINES) has a truncated tail, so
    // the incremental delta can't be trusted; likewise if this edit would cross
    // the cap. Either way a full rebuild is the only correct path - it re-clamps
    // exactly like the from-scratch index.
    if (st.line_count >= MAX_LINES or new_count > MAX_LINES) {
        rebuild_line_index(st);
        return;
    }

    const delta: isize = @as(isize, @intCast(ins.len)) - @as(isize, @intCast(rem_len));
    const dst0 = r0 + 1 + mid; // where the shifted tail lands, just past the new middle entries
    if (dst0 >= tail_start) { // tail moves right (or stays): copy high-to-low so it can't clobber
        var i = tail_len;
        while (i > 0) {
            i -= 1;
            st.line_starts[dst0 + i] = @intCast(@as(isize, st.line_starts[tail_start + i]) + delta);
        }
    } else { // tail moves left: copy low-to-high
        var i: usize = 0;
        while (i < tail_len) : (i += 1) {
            st.line_starts[dst0 + i] = @intCast(@as(isize, st.line_starts[tail_start + i]) + delta);
        }
    }

    var w = r0 + 1; // write the inserted region's newlines between the kept head and the tail
    var j: usize = 0;
    while (j < ins.len) : (j += 1) {
        if (ins[j] == '\n') {
            st.line_starts[w] = @intCast(pos + j + 1);
            w += 1;
        }
    }

    st.line_count = new_count;
    st.index_seq = st.buf.edit_seq;
}

// Largest row r with line_starts[r] <= off.
fn row_of_offset(st: *const TextAreaState, off: usize) usize {
    var lo: usize = 0;
    var hi: usize = st.line_count;
    while (lo + 1 < hi) {
        const mid = (lo + hi) / 2;
        if (st.line_starts[mid] <= off) lo = mid else hi = mid;
    }
    return lo;
}

// Byte offset one past the last visible char of row r (excludes the '\n').
fn line_end(st: *const TextAreaState, r: usize) usize {
    if (r + 1 < st.line_count) return st.line_starts[r + 1] - 1;
    return st.buf.len;
}

// Advance a display column over `bytes` (codepoint = +1; tab snaps to the next
// multiple of TAB). Absolute column in, so tab stops stay correct mid-line.
fn advance_col(start_col: usize, bytes: []const u8) usize {
    var col = start_col;
    var i: usize = 0;
    while (i < bytes.len) {
        if (bytes[i] == '\t') {
            col = (col / TAB + 1) * TAB;
            i += 1;
        } else {
            i = next_boundary(bytes, i);
            col += 1;
        }
    }
    return col;
}

// Where to cut [start, le) so it fits cols_max display columns: the byte after
// the last space inside the fit (word wrap), else the overflow point itself (a
// word longer than the line hard-breaks). Always consumes >= 1 char before it
// can break, so the segment strictly advances; bounded by the line length.
fn wrap_point(st: *const TextAreaState, start: usize, le: usize, cols_max: usize) usize {
    const bytes = st.buf.slice();
    var i = start;
    var col: usize = 0;
    var last_break = start;
    var saw_break = false;
    while (i < le) {
        const is_tab = bytes[i] == '\t';
        const ni = if (is_tab) i + 1 else next_boundary(bytes, i);
        const ncol = if (is_tab) (col / TAB + 1) * TAB else col + 1;
        if (ncol > cols_max and i > start) {
            return if (saw_break and last_break > start) last_break else i;
        }
        col = ncol;
        if (bytes[i] == ' ') {
            last_break = ni;
            saw_break = true;
        }
        i = ni;
    }
    return le;
}

// Rebuild the visual index from the (current) logical index. cols_max == 0 ->
// no wrap, so it mirrors line_starts; otherwise each logical line splits into
// wrap_point segments. Clamps at MAX_VIS like the line index. Gated on
// vis_seq / vis_cols by the callers, so steady-state frames skip it.
//
// O(buffer): re-wraps every line, unlike the incremental logical index next to
// it. Accepted, not free - a text area is a bounded GUI control and edits are
// human-paced; an incremental re-wrap would only pay off for huge bodies.
// Fold regions: one stack pass over the buffer pairs brackets; a pair spanning >1 logical line
// becomes a foldable [open_line, close_line]. Gated on edit_seq, so it runs only when text changes.
// Brackets inside strings/comments aren't excluded (a pragmatic approximation for a v1 folder).
fn rebuild_folds(st: *TextAreaState) void {
    if (st.fold_seq == st.buf.edit_seq) return;
    st.fold_seq = st.buf.edit_seq;
    st.fold_n = 0;
    const buf = st.buf.slice();
    var stack: [MAX_FOLD_DEPTH]u32 = undefined; // opener offsets
    var closer: [MAX_FOLD_DEPTH]u8 = undefined; // the closer each opener expects
    var sp: usize = 0;
    for (buf, 0..) |c, i| {
        switch (c) {
            '{', '[', '(' => if (sp < stack.len) {
                stack[sp] = @intCast(i);
                closer[sp] = if (c == '{') '}' else if (c == '[') ']' else ')';
                sp += 1;
            },
            '}', ']', ')' => if (sp > 0 and closer[sp - 1] == c) {
                sp -= 1;
                const ol: u32 = @intCast(row_of_offset(st, stack[sp]));
                const cl: u32 = @intCast(row_of_offset(st, i));
                if (cl > ol and st.fold_n < MAX_FOLDS) {
                    st.fold_open[st.fold_n] = ol;
                    st.fold_close[st.fold_n] = cl;
                    st.fold_cchar[st.fold_n] = c;
                    st.fold_n += 1;
                }
            },
            else => {},
        }
    }
}

// If a fold opens on `line`, the close line of its widest region (so nested pairs on one header
// line collapse as a whole); else null. O(fold_n), fold_n small.
fn fold_end_at(st: *const TextAreaState, line: usize) ?u32 {
    var best: ?u32 = null;
    for (0..st.fold_n) |k| {
        if (st.fold_open[k] == line and (best == null or st.fold_close[k] > best.?)) best = st.fold_close[k];
    }
    return best;
}

fn line_is_collapsed(st: *const TextAreaState, line: usize) bool {
    return line < MAX_LINES and st.collapsed.isSet(line) and fold_end_at(st, line) != null;
}

// The closing bracket of the widest region opening on `line` (matches fold_end_at's choice), for the
// collapsed "…}" marker.
fn fold_cchar_at(st: *const TextAreaState, line: usize) u8 {
    var best: ?u32 = null;
    var ch: u8 = '}';
    for (0..st.fold_n) |k| {
        if (st.fold_open[k] == line and (best == null or st.fold_close[k] > best.?)) {
            best = st.fold_close[k];
            ch = st.fold_cchar[k];
        }
    }
    return ch;
}

fn rebuild_vis_index(st: *TextAreaState, cols_max: usize, folding: bool) void {
    if (folding) rebuild_folds(st); // cheap no-op unless the buffer changed
    st.vis_eof_folded = false;
    if (cols_max == 0) {
        if (!folding) {
            const n = @min(st.line_count, MAX_VIS);
            @memcpy(st.vis_starts[0..n], st.line_starts[0..n]);
            st.vis_count = n;
        } else {
            var v: usize = 0;
            var r: usize = 0;
            while (r < st.line_count and v < MAX_VIS) {
                st.vis_starts[v] = st.line_starts[r];
                v += 1;
                if (line_is_collapsed(st, r)) {
                    const close = fold_end_at(st, r).?;
                    if (close == st.line_count - 1) st.vis_eof_folded = true;
                    r = close + 1;
                } else r += 1;
            }
            st.vis_count = @max(1, v);
        }
        st.vis_seq = st.buf.edit_seq;
        st.vis_cols = 0;
        st.vis_collapse_seq = st.collapse_seq;
        return;
    }
    var v: usize = 0;
    var r: usize = 0;
    outer: while (r < st.line_count) : (r += 1) {
        const le = line_end(st, r);
        var seg: usize = st.line_starts[r];
        while (true) {
            if (v >= MAX_VIS) break :outer;
            st.vis_starts[v] = @intCast(seg);
            v += 1;
            const nxt = wrap_point(st, seg, le, cols_max);
            std.debug.assert(nxt > seg or seg >= le); // a non-empty segment must advance
            if (nxt >= le) break;
            seg = nxt;
        }
        // A collapsed header shows its own (wrapped) rows; jump past the hidden body to the closer.
        if (folding and line_is_collapsed(st, r)) {
            const close = fold_end_at(st, r).?;
            if (close == st.line_count - 1) st.vis_eof_folded = true;
            r = close;
        }
    }
    if (v == 0) {
        st.vis_starts[0] = 0;
        v = 1;
    }
    st.vis_count = v;
    st.vis_seq = st.buf.edit_seq;
    st.vis_cols = cols_max;
    st.vis_collapse_seq = st.collapse_seq;
}

// Largest visual row r with vis_starts[r] <= off.
fn vis_row_of_offset(st: *const TextAreaState, off: usize) usize {
    var lo: usize = 0;
    var hi: usize = st.vis_count;
    while (lo + 1 < hi) {
        const mid = (lo + hi) / 2;
        if (st.vis_starts[mid] <= off) lo = mid else hi = mid;
    }
    return lo;
}

// Visible end of visual row r: one past its last drawn char. A soft-wrap
// boundary keeps every byte (the break sits between glyphs); a hard newline at
// the next row's start is excluded.
fn vis_line_end(st: *const TextAreaState, r: usize) usize {
    const normal = if (r + 1 < st.vis_count) blk: {
        const ns = st.vis_starts[r + 1];
        break :blk if (ns > 0 and st.buf.bytes[ns - 1] == '\n') ns - 1 else ns;
    } else st.buf.len;
    // A collapsed header row must not swallow the hidden body: cap it at its own logical line end
    // (the next visual row starts at the region's closer, far past this line).
    if (st.folding_on) {
        const logical = row_of_offset(st, st.vis_starts[r]);
        if (line_is_collapsed(st, logical)) return @min(normal, line_end(st, logical));
    }
    return normal;
}

fn vis_col_of(st: *const TextAreaState, row: usize, off: usize) usize {
    return advance_col(0, st.buf.bytes[st.vis_starts[row]..off]);
}

// First byte offset in visual row whose display column reaches `target` (or its
// visible end). Columns reset to 0 at each visual row's start.
fn byte_offset_at_vis_col(st: *const TextAreaState, row: usize, target: usize) usize {
    const bytes = st.buf.slice();
    const le = vis_line_end(st, row);
    var i: usize = st.vis_starts[row];
    var col: usize = 0;
    while (i < le and col < target) {
        if (bytes[i] == '\t') {
            col = (col / TAB + 1) * TAB;
            i += 1;
        } else {
            i = next_boundary(bytes, i);
            col += 1;
        }
    }
    return i;
}

// Sticky column for up/down, in visual-row coordinates.
fn refresh_goal(st: *TextAreaState) void {
    st.goal_col = vis_col_of(st, vis_row_of_offset(st, st.caret), st.caret);
}

// One on_point hitbox drives both a click and a drag-select: the press sets the
// anchor, then PaintContext re-feeds this thunk on every mouseDragged (so
// st.dragging tells press from drag). drag_end_thunk clears the capture.
// Collapse/expand a fold whose header is `line`. Collapsing pulls the caret out of the body it is
// about to hide, so caret/selection stay on a visible row.
fn toggle_fold(st: *TextAreaState, line: usize) void {
    if (line >= MAX_LINES) return;
    const close = fold_end_at(st, line) orelse return;
    if (st.collapsed.isSet(line)) {
        st.collapsed.unset(line);
    } else {
        st.collapsed.set(line);
        const cl = row_of_offset(st, st.caret);
        if (cl > line and cl <= close) {
            st.caret = line_end(st, line);
            st.sel_anchor = null;
        }
    }
    st.collapse_seq += 1;
}

fn click_thunk(ctx: ?*anyopaque, px: f32, py: f32) void {
    const st: *TextAreaState = @ptrCast(@alignCast(ctx orelse return));
    // A click in the fold-chevron column toggles that row's region instead of moving the caret.
    if (st.folding_on and st.last_fold_w > 0 and px >= st.last_fold_x and px < st.last_fold_x + st.last_fold_w) {
        const fy = py - st.last_text_y + st.scroll_y;
        var vr: usize = if (fy <= 0 or st.last_line_h <= 0) 0 else @intFromFloat(fy / st.last_line_h);
        if (vr >= st.vis_count) vr = st.vis_count - 1;
        const logical = row_of_offset(st, st.vis_starts[vr]);
        if (fold_end_at(st, logical) != null) {
            toggle_fold(st, logical);
            return;
        }
    }
    const rel_y = py - st.last_text_y + st.scroll_y;
    var row: usize =
        if (rel_y <= 0 or st.last_line_h <= 0) 0 else @intFromFloat(rel_y / st.last_line_h);
    if (row >= st.vis_count) row = st.vis_count - 1;
    const rel_x = px - st.last_text_x;
    const col: usize =
        if (rel_x <= 0 or st.char_w <= 0) 0 else @intFromFloat(rel_x / st.char_w + 0.5);
    const off = byte_offset_at_vis_col(st, row, col);

    if (!st.dragging) {
        st.dragging = true;
        if (custom_shell.current_shift_down() and st.focused) {
            if (st.sel_anchor == null) st.sel_anchor = st.caret; // extend from the live caret
            st.caret = off;
        } else {
            st.sel_anchor = off; // fresh press: anchor == caret -> no band yet
            st.caret = off;
        }
        st.goal_col = col;
        st.focused = true;
        st.blink_phase_t0 = st.now_cached; // solid caret on click
        st.drag_autoscroll_dy = 0;
        st.undo_coalesce = false; // a click ends the typing run
        if (st.on_focus) |cb| cb(st.focus_ctx); // caller unfocuses its other areas
    } else {
        st.caret = off;
        st.goal_col = col;
        const top = st.last_text_y;
        const bot = st.last_text_y + st.last_view_h;
        st.drag_autoscroll_dy =
            if (py < top) -st.last_line_h else if (py > bot) st.last_line_h else 0;
    }
}

fn drag_end_thunk(ctx: ?*anyopaque) void {
    const st: *TextAreaState = @ptrCast(@alignCast(ctx orelse return));
    st.dragging = false;
    st.drag_autoscroll_dy = 0;
}

// Drop focus: the paint context calls this when a press lands outside the editor
// (registered via text_focus_blur while focused).
fn blur_thunk(ctx: *anyopaque) void {
    const st: *TextAreaState = @ptrCast(@alignCast(ctx));
    st.focused = false;
}

// Seed/clear the anchor before a caret move: Shift extends (anchor stays put),
// no Shift collapses the selection.
fn extend_begin(st: *TextAreaState, ev: custom_shell.KeyEvent) void {
    if (ev.mods.shift) {
        if (st.sel_anchor == null) st.sel_anchor = st.caret;
    } else {
        st.sel_anchor = null;
    }
}

// Copy the selection to the clipboard. No selection -> leave the clipboard be.
fn copy_selection(st: *TextAreaState) bool {
    const r = sel_range(st) orelse return false;
    // ends are lead boundaries -> valid UTF-8
    custom_shell.pasteboard_write_string(st.buf.bytes[r.a..r.b]);
    return true;
}

// Paste at the caret, replacing any selection. Reads into a bounded scratch and
// trims a capacity-truncated tail back to the last whole codepoint. edit_replace
// fit-checks before mutating, so a too-big paste over a selection keeps it.
fn paste_at_caret(st: *TextAreaState) bool {
    var scratch: [PASTE_CAP]u8 = undefined;
    const raw = custom_shell.pasteboard_read_into(&scratch);
    var n = raw.len;
    if (n == PASTE_CAP and n > 0) { // only a capacity-filling read can split a codepoint
        var lead_i = n - 1;
        while (lead_i > 0 and is_cont(scratch[lead_i])) lead_i -= 1; // bounded: <= 3 steps
        const lead = scratch[lead_i];
        const need: usize =
            if (lead < 0x80) 1 else if (lead < 0xE0) 2 else if (lead < 0xF0) 3 else 4;
        if (n - lead_i < need) n = lead_i; // last codepoint incomplete -> drop it
    }
    const sel = sel_range(st);
    return edit_replace(
        st,
        if (sel) |r| r.a else st.caret,
        if (sel) |r| r.b else st.caret,
        scratch[0..n],
        false,
    );
}

// cmd-letter shortcuts (macOS): select-all / copy / cut / paste / undo / redo.
// Lowercased so Cmd-A and Cmd-Shift-A both match; mods carries Shift so cmd-Z and
// cmd-Shift-Z split. Returns whether the buffer changed.
fn apply_cmd_char(st: *TextAreaState, ch: u21, mods: custom_shell.KeyMods, read_only: bool) bool {
    const lower: u21 = if (ch >= 'A' and ch <= 'Z') ch + 32 else ch;
    switch (lower) {
        'a' => {
            st.sel_anchor = 0;
            st.caret = st.buf.len;
            refresh_goal(st);
            return false;
        },
        'c' => {
            _ = copy_selection(st);
            return false;
        },
        'x' => {
            if (read_only) return false;
            const r = sel_range(st) orelse return false;
            custom_shell.pasteboard_write_string(st.buf.bytes[r.a..r.b]); // copy before deleting
            return edit_replace(st, r.a, r.b, "", false);
        },
        'v' => {
            if (read_only) return false;
            return paste_at_caret(st);
        },
        'z' => {
            if (read_only) return false;
            return if (mods.shift) redo(st) else undo(st); // cmd-shift-z = redo
        },
        'y' => {
            if (read_only) return false;
            return redo(st); // common alternate redo
        },
        else => return false,
    }
}

// Caret on/off from the blink epoch. Pure fn of wall-clock so 60/120Hz blink at
// the same rate; phase resets to 0 (solid) at every blink_phase_t0 update.
fn caret_visible(st: *const TextAreaState, now_s: f64) bool {
    const dt = now_s - st.blink_phase_t0;
    const phase = dt - @floor(dt / BLINK_PERIOD_S) * BLINK_PERIOD_S;
    return phase < BLINK_PERIOD_S * 0.5;
}

// Seconds until the caret's next on<->off flip — a pure fn of the blink epoch, so
// a focused editor can schedule one wakeup per flip instead of animating every frame.
fn next_blink_edge_s(st: *const TextAreaState, now_s: f64) f64 {
    const dt = now_s - st.blink_phase_t0;
    const phase = dt - @floor(dt / BLINK_PERIOD_S) * BLINK_PERIOD_S;
    const half = BLINK_PERIOD_S * 0.5;
    return if (phase < half) half - phase else BLINK_PERIOD_S - phase;
}

// Top of the arena bytes used by the undo region; redo bytes (if any) sit above.
fn undo_high_water(st: *const TextAreaState) usize {
    if (st.undo_count == 0) return 0;
    const op = st.undo_ops[st.undo_count - 1];
    return op.ins_at + op.ins_len; // inserted is pushed last per op
}

fn undo_clear(st: *TextAreaState) void {
    st.undo_count = 0;
    st.undo_total = 0;
    st.undo_arena_len = 0;
    st.undo_coalesce = false;
}

// Drop the oldest op (its bytes are at the arena bottom) and slide the rest down.
fn undo_evict_oldest(st: *TextAreaState) void {
    std.debug.assert(st.undo_count > 0);
    // only called mid-record, redo tail already dropped
    std.debug.assert(st.undo_total == st.undo_count);
    const freed = st.undo_ops[0].ins_at + st.undo_ops[0].ins_len; // op[0] occupies arena[0..freed]
    var i: usize = 1;
    while (i < st.undo_total) : (i += 1) {
        var op = st.undo_ops[i];
        op.rem_at -= @intCast(freed);
        op.ins_at -= @intCast(freed);
        st.undo_ops[i - 1] = op;
    }
    st.undo_total -= 1;
    if (st.undo_count > 0) st.undo_count -= 1;
    std.mem.copyForwards(
        u8,
        st.undo_arena[0 .. st.undo_arena_len - freed],
        st.undo_arena[freed..st.undo_arena_len],
    );
    st.undo_arena_len -= freed;
}

// Record one splice. coalesce lets a single typed char extend the top op so a
// run of typing is one undo step. A new op discards the redo tail; eviction
// drops oldest groups when the rings fill; an edit too big to store clears the
// history (the buffer edit still stands - it just becomes un-undoable).
fn record_splice(
    st: *TextAreaState,
    pos: usize,
    removed: []const u8,
    inserted: []const u8,
    coalesce: bool,
) void {
    if (coalesce and st.undo_coalesce and st.undo_count > 0 and removed.len == 0) {
        const top = &st.undo_ops[st.undo_count - 1];
        const contiguous = top.rem_len == 0 and
            top.pos + top.ins_len == pos and
            top.ins_at + top.ins_len == st.undo_arena_len;
        if (contiguous and st.undo_arena_len + inserted.len <= UNDO_ARENA) {
            @memcpy(st.undo_arena[st.undo_arena_len..][0..inserted.len], inserted);
            st.undo_arena_len += inserted.len;
            top.ins_len += @intCast(inserted.len);
            return;
        }
    }
    st.undo_total = st.undo_count; // drop redo tail
    st.undo_arena_len = undo_high_water(st); // reclaim redo bytes
    const need = removed.len + inserted.len;
    if (need > UNDO_ARENA) {
        undo_clear(st);
        return;
    }
    while (st.undo_count == UNDO_MAX_OPS or st.undo_arena_len + need > UNDO_ARENA) {
        if (st.undo_count == 0) {
            // nothing left to evict; need <= UNDO_ARENA (checked above) so the empty state fits
            undo_clear(st);
            break;
        }
        undo_evict_oldest(st);
    }
    const rem_at: u32 = @intCast(st.undo_arena_len);
    @memcpy(st.undo_arena[st.undo_arena_len..][0..removed.len], removed);
    st.undo_arena_len += removed.len;
    const ins_at: u32 = @intCast(st.undo_arena_len);
    @memcpy(st.undo_arena[st.undo_arena_len..][0..inserted.len], inserted);
    st.undo_arena_len += inserted.len;
    st.undo_ops[st.undo_count] = .{
        .pos = @intCast(pos),
        .rem_at = rem_at,
        .rem_len = @intCast(removed.len),
        .ins_at = ins_at,
        .ins_len = @intCast(inserted.len),
    };
    st.undo_count += 1;
    st.undo_total = st.undo_count;
}

// The single mutation chokepoint: replace buffer[a..b) with `text`, recording
// one undo op. Every edit (typing, delete, paste, cut) funnels here so undo
// captures a selection-replace as ONE step. Fit-checks before mutating so an
// overflow is a clean no-op (nothing recorded). Returns whether it changed.
fn edit_replace(st: *TextAreaState, a: usize, b: usize, text: []const u8, coalesce: bool) bool {
    std.debug.assert(a <= b);
    std.debug.assert(b <= st.buf.len);
    // update_line_index needs the index current for the pre-edit buffer. render
    // guarantees that, but a caller editing a seeded buffer before the first
    // render would not - rebuild once if stale (a no-op in steady-state typing).
    if (st.buf.edit_seq != st.index_seq) rebuild_line_index(st);
    const rem_len = b - a;
    if (rem_len == 0 and text.len == 0) return false;
    if (st.buf.len - rem_len + text.len > st.buf.bytes.len) {
        st.full = true;
        return false;
    }
    st.full = false;
    record_splice(st, a, st.buf.bytes[a..b], text, coalesce); // capture removed before delete_range
    if (rem_len > 0) st.buf.delete_range(a, b);
    if (text.len > 0) _ = st.buf.insert_bytes(a, text);
    st.caret = a + text.len;
    st.sel_anchor = null;
    update_line_index(st, a, rem_len, text); // incremental: O(lines after pos), not O(buffer)
    rebuild_vis_index(st, st.vis_cols, st.folding_on); // the wrap layout shifted with the edit
    refresh_goal(st);
    st.undo_coalesce = coalesce;
    return true;
}

// Reverse the top op: delete its inserted run, restore its removed bytes. The op
// moves to the redo region.
fn undo(st: *TextAreaState) bool {
    if (st.undo_count == 0) return false;
    const op = st.undo_ops[st.undo_count - 1];
    if (op.ins_len > 0) st.buf.delete_range(op.pos, op.pos + op.ins_len);
    if (op.rem_len > 0) _ = st.buf.insert_bytes(op.pos, st.undo_arena[op.rem_at..][0..op.rem_len]);
    st.undo_count -= 1;
    st.caret = op.pos + op.rem_len;
    st.sel_anchor = null;
    st.undo_coalesce = false;
    rebuild_line_index(st);
    rebuild_vis_index(st, st.vis_cols, st.folding_on); // the wrap layout shifted with the edit
    refresh_goal(st);
    return true;
}

fn redo(st: *TextAreaState) bool {
    if (st.undo_count >= st.undo_total) return false;
    const op = st.undo_ops[st.undo_count];
    if (op.rem_len > 0) st.buf.delete_range(op.pos, op.pos + op.rem_len);
    if (op.ins_len > 0) _ = st.buf.insert_bytes(op.pos, st.undo_arena[op.ins_at..][0..op.ins_len]);
    st.undo_count += 1;
    st.caret = op.pos + op.ins_len;
    st.sel_anchor = null;
    st.undo_coalesce = false;
    rebuild_line_index(st);
    rebuild_vis_index(st, st.vis_cols, st.folding_on); // the wrap layout shifted with the edit
    refresh_goal(st);
    return true;
}

// Replace the current selection (or the caret point if none) with text. coalesce
// only takes effect for plain typing with no selection (the consecutive-char undo
// run), so callers pass true for typed chars and false for enter/tab.
fn edit_at_selection(st: *TextAreaState, text: []const u8, coalesce: bool) bool {
    const sel = sel_range(st);
    const a = if (sel) |r| r.a else st.caret;
    const b = if (sel) |r| r.b else st.caret;
    return edit_replace(st, a, b, text, coalesce and sel == null);
}

// Horizontal caret move. Plain (no shift) over a selection collapses to its edge;
// otherwise extend/move by one grapheme boundary.
fn move_horiz(st: *TextAreaState, ev: custom_shell.KeyEvent, forward: bool) void {
    const bytes = st.buf.slice();
    if (!ev.mods.shift) if (sel_range(st)) |r| {
        st.sel_anchor = null;
        st.caret = if (forward) r.b else r.a;
        refresh_goal(st);
        return;
    };
    extend_begin(st, ev);
    st.caret = if (forward) next_boundary(bytes, st.caret) else prev_boundary(bytes, st.caret);
    refresh_goal(st);
}

// Vertical caret move to the goal column on the adjacent visual row.
fn move_vert(st: *TextAreaState, ev: custom_shell.KeyEvent, down: bool) void {
    extend_begin(st, ev);
    const row = vis_row_of_offset(st, st.caret);
    if (down) {
        if (row + 1 < st.vis_count) st.caret = byte_offset_at_vis_col(st, row + 1, st.goal_col);
    } else {
        if (row > 0) st.caret = byte_offset_at_vis_col(st, row - 1, st.goal_col);
    }
}

// Caret to the start (to_end=false) or end of the current visual line.
fn move_line(st: *TextAreaState, ev: custom_shell.KeyEvent, to_end: bool) void {
    extend_begin(st, ev);
    const row = vis_row_of_offset(st, st.caret);
    if (to_end) {
        st.caret = vis_line_end(st, row);
        st.goal_col = vis_col_of(st, row, st.caret);
    } else {
        st.caret = st.vis_starts[row];
        st.goal_col = 0;
    }
}

// Caret to the document start (to_end=false) or end. Cmd+Up/Down on macOS, Ctrl+Home/End elsewhere.
fn move_doc(st: *TextAreaState, ev: custom_shell.KeyEvent, to_end: bool) void {
    extend_begin(st, ev);
    st.caret = if (to_end) st.buf.len else 0;
    refresh_goal(st);
}

// Caret by one word: forward stops after the next word, backward at the start of the previous one.
// Option+arrow on macOS, Ctrl+arrow elsewhere.
fn move_word(st: *TextAreaState, ev: custom_shell.KeyEvent, forward: bool) void {
    const bytes = st.buf.slice();
    extend_begin(st, ev);
    st.caret = if (forward) next_word(bytes, st.caret) else prev_word(bytes, st.caret);
    refresh_goal(st);
}

fn next_word(bytes: []const u8, start: usize) usize {
    var i = start;
    while (i < bytes.len and !is_word(bytes[i])) i += 1; // skip separators
    while (i < bytes.len and is_word(bytes[i])) i += 1; // then the word
    return i;
}
fn prev_word(bytes: []const u8, start: usize) usize {
    var i = start;
    while (i > 0 and !is_word(bytes[i - 1])) i -= 1;
    while (i > 0 and is_word(bytes[i - 1])) i -= 1;
    return i;
}

const INDENT = "  "; // code-editor indent unit (two spaces)

fn is_word(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}
fn is_quote(c: u8) bool {
    return c == '"' or c == '\'' or c == '`';
}
fn closer_for(c: u8) ?u8 {
    return switch (c) {
        '(' => ')',
        '[' => ']',
        '{' => '}',
        else => null,
    };
}
// The two bytes are an empty auto-closed pair the caret sits inside (backspace drops both).
fn is_empty_pair(l: u8, r: u8) bool {
    if (is_quote(l) and l == r) return true;
    if (closer_for(l)) |cc| return cc == r;
    return false;
}

// Wrap the current selection [a,b) in `open`..`close`, leaving the inner text
// selected. Two splices (a Ctrl+Z each) - offsets from the tail so they stay valid.
fn surround(st: *TextAreaState, a: usize, b: usize, open: u8, close: u8) bool {
    _ = edit_replace(st, b, b, &[_]u8{close}, false);
    _ = edit_replace(st, a, a, &[_]u8{open}, false);
    st.sel_anchor = a + 1;
    st.caret = b + 1;
    refresh_goal(st);
    return true;
}

// Insert `open``close` at the caret and sit between them.
fn insert_pair(st: *TextAreaState, open: u8, close: u8) bool {
    if (!edit_replace(st, st.caret, st.caret, &[_]u8{ open, close }, false)) return false;
    st.caret -= 1;
    refresh_goal(st);
    return true;
}

// Auto-close / skip / surround for a typed ASCII char. Returns null to fall through
// to the plain insert; a bool means it handled the key (value = buffer changed).
fn code_type_char(st: *TextAreaState, ch: u8) ?bool {
    const buf = st.buf.slice();
    const next: ?u8 = if (st.caret < buf.len) buf[st.caret] else null;
    const prev: ?u8 = if (st.caret > 0) buf[st.caret - 1] else null;

    if (sel_range(st)) |r| {
        // Typing a bracket/quote over a selection wraps it (never destroys it).
        if (closer_for(ch)) |cc| return surround(st, r.a, r.b, ch, cc);
        if (is_quote(ch)) return surround(st, r.a, r.b, ch, ch);
        return null;
    }

    // Skip over the just-typed closing char when it already sits under the caret.
    if ((ch == ')' or ch == ']' or ch == '}' or is_quote(ch)) and next == ch) {
        st.caret += 1;
        refresh_goal(st);
        return false;
    }
    if (closer_for(ch)) |cc| return insert_pair(st, ch, cc);
    if (is_quote(ch)) {
        // Don't pair inside a word (apostrophes) or right before one.
        const in_word = (prev != null and is_word(prev.?)) or (next != null and is_word(next.?));
        if (!in_word) return insert_pair(st, ch, ch);
    }
    return null;
}

// Enter with indent: carry the current line's leading whitespace; an opener just
// before the caret adds a level, and an opener/closer straddling the caret opens a
// blank indented line between them.
fn code_newline(st: *TextAreaState) bool {
    if (sel_range(st) != null) return edit_at_selection(st, "\n", false);
    const buf = st.buf.slice();
    const a = st.caret;
    const ls = line_start_of(buf, a);
    var ind_len: usize = 0;
    while (ls + ind_len < a and (buf[ls + ind_len] == ' ' or buf[ls + ind_len] == '\t')) ind_len += 1;
    const prev: ?u8 = if (a > 0) buf[a - 1] else null;
    const next: ?u8 = if (a < buf.len) buf[a] else null;
    const open_before = prev != null and closer_for(prev.?) != null;
    const closer_after = open_before and next != null and closer_for(prev.?).? == next.?;

    var scratch: [512]u8 = undefined;
    var w: usize = 0;
    const put = struct {
        fn s(dst: []u8, at: *usize, bytes2: []const u8) bool {
            if (at.* + bytes2.len > dst.len) return false;
            @memcpy(dst[at.*..][0..bytes2.len], bytes2);
            at.* += bytes2.len;
            return true;
        }
    }.s;
    const indent = buf[ls..][0..ind_len];
    if (!put(&scratch, &w, "\n")) return edit_at_selection(st, "\n", false);
    if (!put(&scratch, &w, indent)) return edit_at_selection(st, "\n", false);
    if (open_before and !put(&scratch, &w, INDENT)) return edit_at_selection(st, "\n", false);
    const caret_to = a + w; // caret lands at the end of the (indented) new line
    if (closer_after) {
        if (!put(&scratch, &w, "\n") or !put(&scratch, &w, indent)) return edit_at_selection(st, "\n", false);
    }
    if (!edit_replace(st, a, a, scratch[0..w], false)) return false;
    st.caret = caret_to;
    refresh_goal(st);
    return true;
}

fn line_start_of(buf: []const u8, off: usize) usize {
    var i = off;
    while (i > 0 and buf[i - 1] != '\n') i -= 1;
    return i;
}

// Tab / Shift+Tab in code mode: Shift dedents the touched lines; a plain Tab over a
// multi-line selection indents them; otherwise it just inserts one indent.
fn code_tab(st: *TextAreaState, shift: bool) bool {
    const sel = sel_range(st);
    if (shift) {
        const a = if (sel) |r| r.a else st.caret;
        const b = if (sel) |r| r.b else st.caret;
        return block_indent(st, a, b, true, sel != null);
    }
    if (sel) |r| {
        if (std.mem.indexOfScalar(u8, st.buf.slice()[r.a..r.b], '\n') != null)
            return block_indent(st, r.a, r.b, false, true);
    }
    return edit_at_selection(st, INDENT, false);
}

// Indent (or dedent) every line touched by [a,b]. Splices tail-first so the line
// starts gathered from the pre-edit buffer stay valid. Restores a block selection
// when the caller had one, so a repeated Tab keeps working.
fn block_indent(st: *TextAreaState, a: usize, b: usize, dedent: bool, had_sel: bool) bool {
    const BLOCK_MAX = 1024;
    var starts: [BLOCK_MAX]u32 = undefined;
    var n: usize = 0;
    {
        const buf = st.buf.slice();
        const stop = if (b > a) b - 1 else b;
        var i = line_start_of(buf, a);
        while (i <= stop and n < BLOCK_MAX) {
            starts[n] = @intCast(i);
            n += 1;
            const nl = std.mem.indexOfScalarPos(u8, buf, i, '\n') orelse break;
            i = nl + 1;
        }
    }
    if (n == 0) return false;
    var changed = false;
    var k = n;
    while (k > 0) {
        k -= 1;
        const pos: usize = starts[k];
        if (dedent) {
            const cur = st.buf.slice();
            if (pos >= cur.len) continue;
            var rm: usize = 0;
            if (cur[pos] == '\t') rm = 1 else while (rm < INDENT.len and pos + rm < cur.len and cur[pos + rm] == ' ') : (rm += 1) {}
            if (rm > 0 and edit_replace(st, pos, pos + rm, "", false)) changed = true;
        } else {
            if (edit_replace(st, pos, pos, INDENT, false)) changed = true;
        }
    }
    if (had_sel) {
        const cur = st.buf.slice();
        var p: usize = starts[0]; // unmoved: no edit landed before it
        var left = n;
        while (left > 1) : (left -= 1) {
            const nl = std.mem.indexOfScalarPos(u8, cur, p, '\n') orelse break;
            p = nl + 1;
        }
        var e = p;
        while (e < cur.len and cur[e] != '\n') e += 1;
        st.sel_anchor = starts[0];
        st.caret = e;
        refresh_goal(st);
    }
    return changed;
}

fn apply_key(st: *TextAreaState, ev: custom_shell.KeyEvent, read_only: bool, code: bool) bool {
    const bytes = st.buf.slice();
    if (ev.code != .char) st.undo_coalesce = false; // any non-typing key ends the typing run
    switch (ev.code) {
        .char => {
            if (ev.mods.cmd and !ev.mods.ctrl and !ev.mods.alt) {
                return apply_cmd_char(st, ev.ch, ev.mods, read_only);
            }
            if (ev.mods.cmd or ev.mods.ctrl) return false; // other shortcuts: not text
            if (read_only or ev.ch == 0) return false;
            if (code and ev.ch < 128) if (code_type_char(st, @intCast(ev.ch))) |changed| return changed;
            var scratch: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(ev.ch, &scratch) catch return false;
            return edit_at_selection(st, scratch[0..n], true);
        },
        .enter => {
            if (read_only) return false;
            if (code) return code_newline(st);
            return edit_at_selection(st, "\n", false);
        },
        .tab => {
            if (read_only) return false;
            if (code) return code_tab(st, ev.mods.shift);
            return edit_at_selection(st, "\t", false);
        },
        .backspace => {
            if (read_only) return false;
            // delete the range, not one char
            if (sel_range(st)) |r| return edit_replace(st, r.a, r.b, "", false);
            if (st.caret == 0) return false;
            if (code and st.caret < st.buf.len and is_empty_pair(bytes[st.caret - 1], bytes[st.caret]))
                return edit_replace(st, st.caret - 1, st.caret + 1, "", false); // drop both of an empty pair
            return edit_replace(st, prev_boundary(bytes, st.caret), st.caret, "", false);
        },
        .delete_fwd => {
            if (read_only) return false;
            if (sel_range(st)) |r| return edit_replace(st, r.a, r.b, "", false);
            if (st.caret >= st.buf.len) return false;
            return edit_replace(st, st.caret, next_boundary(bytes, st.caret), "", false);
        },
        .left => {
            const word = if (is_mac) ev.mods.alt else ev.mods.cmd;
            if (is_mac and ev.mods.cmd) {
                move_line(st, ev, false); // macOS Cmd+←: line start
            } else if (word) {
                move_word(st, ev, false); // Option (macOS) / Ctrl (Linux/Win): previous word
            } else {
                move_horiz(st, ev, false);
            }
            return false;
        },
        .right => {
            const word = if (is_mac) ev.mods.alt else ev.mods.cmd;
            if (is_mac and ev.mods.cmd) {
                move_line(st, ev, true);
            } else if (word) {
                move_word(st, ev, true);
            } else {
                move_horiz(st, ev, true);
            }
            return false;
        },
        .home => {
            if (ev.mods.cmd) move_doc(st, ev, false) else move_line(st, ev, false); // Ctrl/Cmd+Home: doc start
            return false;
        },
        .end => {
            if (ev.mods.cmd) move_doc(st, ev, true) else move_line(st, ev, true);
            return false;
        },
        .up => {
            if (is_mac and ev.mods.cmd) move_doc(st, ev, false) else move_vert(st, ev, false); // macOS Cmd+↑: doc start
            return false;
        },
        .down => {
            if (is_mac and ev.mods.cmd) move_doc(st, ev, true) else move_vert(st, ev, true);
            return false;
        },
        .escape => {
            if (has_sel(st)) st.sel_anchor = null // first Esc: clear selection, keep caret + focus
            else st.focused = false; // then Esc: drop focus
            return false;
        },
        .page_up, .page_down => return false,
    }
}

fn mono_style(family: []const u8, size: f32, col: Rgba, weight: FontWeight) label.Style {
    return .{ .font_family = family, .font_size = size, .weight = weight, .color = col };
}

// Per-frame geometry shared by the draw helpers (all in points).
const Geom = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    text_x: f32,
    text_y: f32,
    line_h: f32,
    view_h: f32,
    gutter_w: f32 = 0, // left line-number column (0 = none); text_x already past it
    num_right_x: f32 = 0, // x that line numbers right-align to
    fold_x: f32 = 0, // left edge of the fold-chevron column (0-width when folding is off)
    fold_w: f32 = 0,
};

fn digit_count(n: usize) usize {
    var d: usize = 1;
    var v = n;
    while (v >= 10) : (v /= 10) d += 1;
    return d;
}

// A caller-prefilled buffer could leave the caret or anchor past the end or
// mid-codepoint; snap both so no path splits a UTF-8 sequence.
fn snap_caret(st: *TextAreaState) void {
    if (st.caret > st.buf.len) st.caret = st.buf.len;
    if (st.caret < st.buf.len and is_cont(st.buf.bytes[st.caret])) {
        st.caret = prev_boundary(st.buf.slice(), st.caret);
    }
    if (st.sel_anchor) |an| {
        var a = @min(an, st.buf.len);
        if (a < st.buf.len and is_cont(st.buf.bytes[a])) a = prev_boundary(st.buf.slice(), a);
        st.sel_anchor = a;
    }
}

// Caret nav runs on the column-sized visual index, so char_w must exist first.
fn ensure_char_w(b: *RenderBuilder, st: *TextAreaState, opts: TextAreaOptions) void {
    if (opts.font_size == st.char_w_size) return;
    const w_style = mono_style(opts.font_family, opts.font_size, opts.theme.foreground, .normal);
    st.char_w = label.measure(b, "0", w_style).width;
    st.char_w_size = opts.font_size;
}

// Drain the shared key queue (only the focused area consumes). Returns whether
// the buffer changed; keeps the line index valid mid-drain.
fn drain_keys(st: *TextAreaState, opts: TextAreaOptions) bool {
    const p = opts.paint;
    var changed = false;
    for (p.keys()) |ev| {
        if (opts.completion) |c| if (c.open and completion_key(c, ev)) continue; // popup ate the nav key
        if (opts.snippet) |s| if (s.active and snippet_key(s, ev)) continue; // Tab/Esc drive the tabstops
        if (apply_key(st, ev, opts.read_only, opts.code_edits)) changed = true;
        if (st.buf.edit_seq != st.index_seq) rebuild_line_index(st);
    }
    if (p.keys().len > 0) st.blink_phase_t0 = st.now_cached; // any key -> solid caret
    return changed;
}

// While a completion popup is open, the navigation keys drive it, not the caret. Returns true when
// the key was consumed (so it must not also edit text); typing + backspace fall through to refilter.
fn completion_key(c: *Completion, ev: custom_shell.KeyEvent) bool {
    switch (ev.code) {
        .up => {
            if (c.count > 0) c.selected = (c.selected + c.count - 1) % c.count;
            return true;
        },
        .down => {
            if (c.count > 0) c.selected = (c.selected + 1) % c.count;
            return true;
        },
        .enter, .tab => {
            c.commit = true;
            return true;
        },
        .escape => {
            c.dismiss = true;
            return true;
        },
        else => return false,
    }
}

// While a snippet is active, Tab / Shift+Tab / Esc move between tabstops instead of indenting. The
// caller moves the selection and clears the flag; typing falls through to edit the placeholder.
fn snippet_key(s: *Snippet, ev: custom_shell.KeyEvent) bool {
    switch (ev.code) {
        .tab => {
            if (ev.mods.shift) s.prev = true else s.next = true;
            return true;
        },
        .escape => {
            s.cancel = true;
            return true;
        },
        else => return false,
    }
}

// Wheel capture + edge-drag autoscroll + caret-follow (only when the caret
// moved), then clamp. A pure wheel / idle frame keeps the user's scroll.
fn apply_scroll(st: *TextAreaState, opts: TextAreaOptions, g: Geom, caret_moved: bool) void {
    const p = opts.paint;
    const content_h = @as(f32, @floatFromInt(st.vis_count)) * g.line_h;
    const max_scroll = @max(0, content_h - g.view_h);
    if (max_scroll > 0 and p.wheel_dy != 0 and p.is_hovered(g.x, g.y, g.w, g.h)) {
        st.scroll_y -= p.wheel_dy;
        p.wheel_dy = 0;
    }
    if (st.dragging and st.drag_autoscroll_dy != 0) st.scroll_y += st.drag_autoscroll_dy;
    if (caret_moved or st.scroll_to_caret) {
        const top = @as(f32, @floatFromInt(vis_row_of_offset(st, st.caret))) * g.line_h;
        if (top < st.scroll_y) st.scroll_y = top;
        if (top + g.line_h > st.scroll_y + g.view_h) st.scroll_y = top + g.line_h - g.view_h;
        st.scroll_to_caret = false;
    }
    st.scroll_y = std.math.clamp(st.scroll_y, 0, max_scroll);
}

// One visual row's glyphs: fast path (no spans) or coloured segments via the
// shared forward span cursor; clips the row's sprites to the text band.
fn draw_row_glyphs(
    b: *RenderBuilder,
    st: *TextAreaState,
    opts: TextAreaOptions,
    g: Geom,
    ls: usize,
    le: usize,
    yy: f32,
    base_style: label.Style,
    span_i: *usize,
    band: [4]f32,
) RenderError!void {
    const spans = opts.spans;
    const t0 = b.sprites.items.len;
    if (spans.len == 0) {
        if (le > ls) _ = try label.render(b, g.text_x, yy, st.buf.bytes[ls..le], base_style);
    } else {
        var cursor = ls;
        var col: usize = 0;
        while (cursor < le) {
            while (span_i.* < spans.len and spans[span_i.*].end <= cursor) span_i.* += 1;
            const in_span = span_i.* < spans.len and spans[span_i.*].start <= cursor;
            const seg_end = if (in_span)
                @min(le, @as(usize, spans[span_i.*].end))
            else if (span_i.* < spans.len)
                @min(le, @as(usize, spans[span_i.*].start))
            else
                le;
            const sty = if (in_span) mono_style(
                opts.font_family,
                opts.font_size,
                spans[span_i.*].color,
                spans[span_i.*].weight,
            ) else base_style;
            const seg = st.buf.bytes[cursor..seg_end];
            const seg_x = g.text_x + @as(f32, @floatFromInt(col)) * st.char_w;
            _ = try label.render(b, seg_x, yy, seg, sty);
            col = advance_col(col, seg);
            cursor = seg_end;
        }
    }
    for (b.sprites.items[t0..]) |*sp| sp.clip_bounds = tr.clip_intersect(sp.clip_bounds, band);
}

fn draw_rows(
    b: *RenderBuilder,
    st: *TextAreaState,
    opts: TextAreaOptions,
    g: Geom,
    first_row: usize,
    last_row: usize,
    band: [4]f32,
) RenderError!void {
    const theme = opts.theme;
    const spans = opts.spans;
    // Forward span cursor: spans are sorted, so each is touched once across all
    // visible rows -> O(rows + spans), never O(rows * spans).
    var span_i: usize = 0;
    if (spans.len > 0 and st.vis_count > 0) {
        const start_off = st.vis_starts[first_row];
        while (span_i < spans.len and spans[span_i].end <= start_off) span_i += 1;
    }
    const base_style = mono_style(opts.font_family, opts.font_size, theme.foreground, .normal);
    // Selection band colour: no Theme token, so blend background<-ring with a
    // forced alpha (dimmer when unfocused).
    const sel = sel_range(st);
    const srow = if (sel) |s| vis_row_of_offset(st, s.a) else 0;
    const erow = if (sel) |s| vis_row_of_offset(st, s.b) else 0;
    var sel_color = tr.mix(theme.background, theme.ring, SEL_MIX);
    sel_color.a = if (st.focused) SEL_ALPHA else SEL_ALPHA_INACTIVE;

    var r = first_row;
    while (r < last_row) : (r += 1) {
        const ls: usize = st.vis_starts[r];
        const le = vis_line_end(st, r);
        const yy = g.text_y + @as(f32, @floatFromInt(r)) * g.line_h - st.scroll_y;

        // Selection band BEFORE glyphs (quads honour submission order, then all
        // glyphs flush on top) so the band sits behind the row's text.
        if (sel) |s| if (r >= srow and r <= erow) {
            const seg_a: usize = if (r == srow) s.a else ls;
            const seg_b: usize = if (r == erow) s.b else le;
            const col_a = vis_col_of(st, r, seg_a);
            const col_b = vis_col_of(st, r, seg_b);
            const bx = g.text_x + @as(f32, @floatFromInt(col_a)) * st.char_w;
            var bw = @as(f32, @floatFromInt(col_b - col_a)) * st.char_w;
            // Only a hard newline at the row's end draws the swallow-stub; a soft
            // wrap keeps no '\n', so its fully-selected row stops at the text.
            if (r < erow and le < st.buf.len and st.buf.bytes[le] == '\n') {
                bw += st.char_w * NL_STUB;
            }
            // Sliver for a selected empty INTERIOR row only; a zero-width band on
            // the last row (selection ended on a soft-wrap boundary) draws nothing.
            if (bw <= 0 and r < erow) bw = st.char_w * NL_STUB;
            var band_q = Quad.init(bx, yy, bw, g.line_h);
            _ = band_q.set_background(sel_color)
                .set_clip_bounds(tr.clip_intersect(.{ -1e9, -1e9, 2e9, 2e9 }, band));
            try b.append_quad(band_q);
        };

        try draw_row_glyphs(b, st, opts, g, ls, le, yy, base_style, &span_i, band);

        // A collapsed region shows a muted "…}" right after its header (the ellipsis stands in for the
        // hidden body, the closer makes the bracket read whole).
        if (st.folding_on) {
            const logical = row_of_offset(st, ls);
            if (line_is_collapsed(st, logical) and le == line_end(st, logical)) {
                const mcol = vis_col_of(st, r, le);
                const mx = g.text_x + @as(f32, @floatFromInt(mcol)) * st.char_w;
                const msty = mono_style(opts.font_family, opts.font_size, theme.muted_foreground, .normal);
                var mbuf: [5]u8 = undefined;
                const marker = std.fmt.bufPrint(&mbuf, "\u{2026}{c}", .{fold_cchar_at(st, logical)}) catch "\u{2026}";
                const m0 = b.sprites.items.len;
                _ = try label.render(b, mx, yy, marker, msty);
                for (b.sprites.items[m0..]) |*sp| sp.clip_bounds = tr.clip_intersect(sp.clip_bounds, band);
            }
        }
    }
}

// A thin bar at the active end (st.caret), shown while focused (incl. during a
// selection, where it marks the moving end), blinking ~2x/s.
fn draw_caret(
    b: *RenderBuilder,
    st: *TextAreaState,
    opts: TextAreaOptions,
    g: Geom,
    band: [4]f32,
) RenderError!void {
    if (!(st.focused and caret_visible(st, st.now_cached))) return;
    const caret_row = vis_row_of_offset(st, st.caret);
    const ccol = vis_col_of(st, caret_row, st.caret);
    const cx = g.text_x + @as(f32, @floatFromInt(ccol)) * st.char_w;
    const cy = g.text_y + @as(f32, @floatFromInt(caret_row)) * g.line_h - st.scroll_y;
    if (cy + g.line_h > g.text_y and cy < g.text_y + g.view_h) {
        var caret = Quad.init(cx, cy, CARET_W, g.line_h);
        _ = caret.set_background(opts.theme.foreground)
            .set_clip_bounds(tr.clip_intersect(.{ -1e9, -1e9, 2e9, 2e9 }, band));
        try b.append_quad(caret);
    }
}

// Left gutter: a muted column with each logical line's number, right-aligned at its first
// visual row (wrapped continuation rows stay blank); the caret's line reads brighter.
fn draw_gutter(b: *RenderBuilder, st: *TextAreaState, opts: TextAreaOptions, g: Geom, first_row: usize, last_row: usize) RenderError!void {
    const theme = opts.theme;
    // The gutter band stops a pad short of the text, leaving a gap so code doesn't hug the edge.
    const edge = g.text_x - opts.pad;
    var col = Quad.init(g.x, g.y, edge - g.x, g.h);
    _ = col.set_background(tr.mix(theme.background, theme.muted, 0.35))
        .set_clip_bounds(.{ g.x, g.y + 1, edge - g.x, g.h - 2 });
    try b.append_quad(col);

    const caret_line = row_of_offset(st, st.caret);
    const num_style = mono_style(opts.font_family, opts.font_size, theme.muted_foreground, .normal);
    const cur_style = mono_style(opts.font_family, opts.font_size, theme.foreground, .normal);
    const band: [4]f32 = .{ g.x, g.y + 1, edge - g.x, g.h - 2 };

    var r = first_row;
    while (r < last_row) : (r += 1) {
        const off = st.vis_starts[r];
        const logical = row_of_offset(st, off);
        if (st.line_starts[logical] != off) continue; // a soft-wrap continuation row has no number
        const yy = g.text_y + @as(f32, @floatFromInt(r)) * g.line_h - st.scroll_y;
        var nbuf: [12]u8 = undefined;
        const s = std.fmt.bufPrint(&nbuf, "{d}", .{logical + 1}) catch continue;
        const sty = if (logical == caret_line and st.focused) cur_style else num_style;
        const nw = @as(f32, @floatFromInt(s.len)) * st.char_w;
        const t0 = b.sprites.items.len;
        _ = try label.render(b, g.num_right_x - nw, yy, s, sty);
        for (b.sprites.items[t0..]) |*sp| sp.clip_bounds = tr.clip_intersect(sp.clip_bounds, band);
        // Fold chevron: right for a collapsed region, down for an expanded one.
        if (g.fold_w > 0 and fold_end_at(st, logical) != null) {
            const chev: icon.Icon = if (line_is_collapsed(st, logical)) .chevron_right else .chevron_down;
            const c0 = b.sprites.items.len;
            _ = try icon.render_icon_centered_xy(b, g.fold_x, yy, g.fold_w, g.line_h, chev, .{
                .point_size = opts.font_size - 2,
                .color = theme.muted_foreground,
            });
            for (b.sprites.items[c0..]) |*sp| sp.clip_bounds = tr.clip_intersect(sp.clip_bounds, band);
        }
    }
    // A region collapsed to the last line has no real row after it; draw the trailing line number
    // below the header so the fold still reads as "one line, then the rest" (matches an editor that
    // keeps the closing line's slot).
    if (st.folding_on and st.vis_eof_folded) {
        const yy = g.text_y + @as(f32, @floatFromInt(st.vis_count)) * g.line_h - st.scroll_y;
        if (yy + g.line_h > g.text_y and yy < g.text_y + g.view_h) {
            var nbuf: [12]u8 = undefined;
            if (std.fmt.bufPrint(&nbuf, "{d}", .{st.line_count + 1})) |s| {
                const nw = @as(f32, @floatFromInt(s.len)) * st.char_w;
                const t0 = b.sprites.items.len;
                _ = try label.render(b, g.num_right_x - nw, yy, s, num_style);
                for (b.sprites.items[t0..]) |*sp| sp.clip_bounds = tr.clip_intersect(sp.clip_bounds, band);
            } else |_| {}
        }
    }
}

// Search-match highlight: a coloured band behind each match range (across its visual rows);
// the active match reads warmer. Behind the text, like the selection band.
fn draw_match_bands(b: *RenderBuilder, st: *TextAreaState, opts: TextAreaOptions, g: Geom, first_row: usize, last_row: usize, band: [4]f32) RenderError!void {
    if (opts.match_ranges.len == 0) return;
    const c_match = Rgba.from_u8(250, 204, 21, 90);
    const c_active = Rgba.from_u8(251, 146, 60, 150);
    const clip = tr.clip_intersect(.{ -1e9, -1e9, 2e9, 2e9 }, band);
    for (opts.match_ranges, 0..) |m, i| {
        const start: usize = m[0];
        const end: usize = m[1];
        if (end <= start or start > st.buf.len) continue;
        const fill = if (@as(i32, @intCast(i)) == opts.active_match) c_active else c_match;
        var r = vis_row_of_offset(st, start);
        const end_row = vis_row_of_offset(st, end - 1);
        while (r <= end_row) : (r += 1) {
            if (r < first_row or r >= last_row) continue;
            const rs = st.vis_starts[r];
            const re = vis_line_end(st, r);
            const sa = @max(start, rs);
            const sb = @min(end, re);
            if (sb <= sa) continue;
            const col_a = vis_col_of(st, r, sa);
            const col_b = vis_col_of(st, r, sb);
            const bx = g.text_x + @as(f32, @floatFromInt(col_a)) * st.char_w;
            const bw = @as(f32, @floatFromInt(col_b - col_a)) * st.char_w;
            const yy = g.text_y + @as(f32, @floatFromInt(r)) * g.line_h - st.scroll_y;
            var q = Quad.init(bx, yy, bw, g.line_h);
            _ = q.set_background(fill).set_clip_bounds(clip);
            try b.append_quad(q);
        }
    }
}

// A faint band across the caret's visual row (behind the glyphs), only while focused.
fn draw_current_line(b: *RenderBuilder, st: *TextAreaState, opts: TextAreaOptions, g: Geom, band: [4]f32) RenderError!void {
    if (!st.focused) return;
    const row = vis_row_of_offset(st, st.caret);
    const yy = g.text_y + @as(f32, @floatFromInt(row)) * g.line_h - st.scroll_y;
    if (yy + g.line_h <= g.text_y or yy >= g.text_y + g.view_h) return;
    const bw = g.w - (g.text_x - g.x) - opts.pad;
    var q = Quad.init(g.text_x, yy, @max(@as(f32, 0), bw), g.line_h);
    _ = q.set_background(tr.mix(opts.theme.background, opts.theme.muted, 0.4))
        .set_clip_bounds(tr.clip_intersect(.{ -1e9, -1e9, 2e9, 2e9 }, band));
    try b.append_quad(q);
}

const BRACKETS = [_][2]u8{ .{ '(', ')' }, .{ '[', ']' }, .{ '{', '}' } };

// Forward from an opener at `from` to its matching closer (nesting-aware); null if unbalanced.
fn scan_close(buf: []const u8, from: usize, open_c: u8, close_c: u8) ?usize {
    var depth: i32 = 1;
    var i = from + 1;
    while (i < buf.len) : (i += 1) {
        if (buf[i] == open_c) depth += 1 else if (buf[i] == close_c) {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

// Backward from a closer at `from` to its matching opener (nesting-aware); null if unbalanced.
fn scan_open(buf: []const u8, from: usize, open_c: u8, close_c: u8) ?usize {
    var depth: i32 = 1;
    var i = from;
    while (i > 0) {
        i -= 1;
        if (buf[i] == close_c) depth += 1 else if (buf[i] == open_c) {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

// The bracket pair to highlight: the bracket just left of the caret (or under it)
// and its partner. String-content brackets are not excluded (naive nesting) - a fine
// trade for a read aid. Returns the two byte offsets, lower first.
fn match_bracket(st: *TextAreaState) ?[2]usize {
    const buf = st.buf.slice();
    var pos: [2]usize = undefined;
    var np: usize = 0;
    if (st.caret > 0) {
        pos[np] = st.caret - 1;
        np += 1;
    }
    if (st.caret < buf.len) {
        pos[np] = st.caret;
        np += 1;
    }
    for (pos[0..np]) |p| {
        const c = buf[p];
        for (BRACKETS) |pr| {
            if (c == pr[0]) {
                if (scan_close(buf, p, pr[0], pr[1])) |m| return .{ p, m };
            } else if (c == pr[1]) {
                if (scan_open(buf, p, pr[0], pr[1])) |m| return .{ m, p };
            }
        }
    }
    return null;
}

// A thin outline box around each bracket of the caret's matched pair (focused only).
fn draw_bracket_match(b: *RenderBuilder, st: *TextAreaState, opts: TextAreaOptions, g: Geom, band: [4]f32) RenderError!void {
    if (!st.focused) return;
    const pair = match_bracket(st) orelse return;
    const clip = tr.clip_intersect(.{ -1e9, -1e9, 2e9, 2e9 }, band);
    for (pair) |off| {
        const row = vis_row_of_offset(st, off);
        const col = vis_col_of(st, row, off);
        const bx = g.text_x + @as(f32, @floatFromInt(col)) * st.char_w;
        const yy = g.text_y + @as(f32, @floatFromInt(row)) * g.line_h - st.scroll_y;
        if (yy + g.line_h <= g.text_y or yy >= g.text_y + g.view_h) continue;
        var q = Quad.init(bx, yy, st.char_w, g.line_h);
        _ = q.set_background(tr.mix(opts.theme.background, opts.theme.muted, 0.7))
            .set_border_color(opts.theme.ring)
            .set_border_width(1)
            .set_clip_bounds(clip);
        try b.append_quad(q);
    }
}

// Geometry prologue: bring the line + visual indexes current, ensure char_w
// (caret nav is column-sized, so it must exist first), and return the Geom.
fn prepare(
    b: *RenderBuilder,
    st: *TextAreaState,
    opts: TextAreaOptions,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
) Geom {
    if (st.buf.edit_seq != st.index_seq) rebuild_line_index(st);
    ensure_char_w(b, st, opts);
    const line_h = opts.font_size * opts.line_spacing;
    std.debug.assert(line_h > 0); // row math divides by it (cull, click->row)
    const pad = opts.pad;
    // Line-number gutter: pad + widest number + a pad-sized gap to the gutter edge + another pad
    // of breathing room before the text (so the code never hugs the gutter band).
    const digits: usize = if (opts.line_numbers) @max(2, digit_count(st.line_count)) else 0;
    const num_w = @as(f32, @floatFromInt(digits)) * st.char_w;
    // A fold-chevron column sits between the numbers and the text when folding is on.
    const fold_w: f32 = if (opts.folding and opts.line_numbers) 12 else 0;
    const gutter_w: f32 = if (opts.line_numbers) num_w + pad * 2 + (if (fold_w > 0) fold_w + pad else 0) else 0;
    const text_w = @max(@as(f32, 0), w - pad * 2 - gutter_w);
    // Visual index = logical lines wrapped to the columns that fit; 0 disables wrap.
    const cols_max: usize = if (opts.wrap and st.char_w > 0)
        @max(1, @as(usize, @intFromFloat(text_w / st.char_w)))
    else
        0;
    if (st.buf.edit_seq != st.vis_seq or cols_max != st.vis_cols or
        (opts.folding and st.collapse_seq != st.vis_collapse_seq)) rebuild_vis_index(st, cols_max, opts.folding);
    return .{
        .x = x,
        .y = y,
        .w = w,
        .h = h,
        .text_x = x + pad + gutter_w,
        .text_y = y + pad,
        .line_h = line_h,
        .view_h = @max(@as(f32, 0), h - pad * 2), // tiny h must not cast negative
        .gutter_w = gutter_w,
        .num_right_x = x + pad + num_w,
        .fold_x = x + pad + num_w + pad, // chevron column starts a pad past the numbers
        .fold_w = fold_w,
    };
}

// Body hitbox: on_point maps a click to the caret + captures the drag for
// selection; on_drag_end releases it. ctx is the state; the thunks read geometry.
fn add_body_hitbox(st: *TextAreaState, opts: TextAreaOptions, g: Geom) RenderError!void {
    try opts.paint.add_hitbox(.{
        .x = g.x,
        .y = g.y,
        .w = g.w,
        .h = g.h,
        .on_point = click_thunk,
        .on_drag_end = drag_end_thunk,
        .ctx = st,
    });
}

// An owned-model multi-line text area: zigui shapes every glyph (no native
// NSTextView). Caller owns the state + buffer; pass spans to colour runs (a
// syntax highlighter) or none for a plain area. Drains the per-frame key queue
// only when focused.
pub fn render(
    b: *RenderBuilder,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    opts: TextAreaOptions,
) RenderError!SizeF {
    std.debug.assert(w > 0);
    std.debug.assert(h >= opts.pad * 2);
    std.debug.assert(opts.state.buf.bytes.len <= std.math.maxInt(u32)); // line/undo offsets are u32
    const st = opts.state;
    const theme = opts.theme;
    const p = opts.paint;
    st.now_cached = p.now_s; // mouse thunks run between frames; they read this
    st.on_focus = opts.on_focus; // stash so the click handler (ctx = state) reaches the caller
    st.focus_ctx = opts.ctx;
    st.folding_on = opts.folding;

    snap_caret(st);
    const g = prepare(b, st, opts, x, y, w, h);

    // Register as the focus owner so a press outside the editor drops focus (and Esc
    // can blur it). Re-armed every focused frame; the paint context resets it per frame.
    if (st.focused) {
        p.text_focus_ctx = st;
        p.text_focus_blur = blur_thunk;
    }

    const caret_before = st.caret;
    // Stay focused (caret/selection persist) but stop draining keys while a modal
    // owns the keyboard, else its arrows would also walk this editor's caret.
    const changed = if (st.focused and !p.block_keys) drain_keys(st, opts) else false;
    if (changed) if (opts.on_change) |cb| cb(opts.ctx);
    apply_scroll(st, opts, g, changed or st.caret != caret_before);

    // Box: bg, plus a border (ring when focused) unless the caller wants a bare
    // fill — a code pane embedded in a panel draws no box of its own.
    var box = Quad.init(x, y, w, h);
    _ = box.set_background(theme.background);
    if (opts.bordered) {
        const border = if (st.focused) theme.ring else theme.border;
        _ = box.set_corner_radius(theme.radius - 2)
            .set_border_color(border)
            .set_border_width(if (st.focused) 2 else 1);
    }
    try b.append_quad(box);

    const band: [4]f32 = .{ g.text_x, y + 1, w - opts.pad * 2 - g.gutter_w, h - 2 };
    // Viewport cull: only shape the rows on screen.
    const first_row: usize = @intFromFloat(st.scroll_y / g.line_h);
    const rows_in_view: usize = @as(usize, @intFromFloat(@ceil(g.view_h / g.line_h))) + 1;
    const last_row = @min(st.vis_count, first_row + rows_in_view);

    try draw_current_line(b, st, opts, g, band); // behind the text (quads honour order)
    if (opts.code_edits) try draw_bracket_match(b, st, opts, g, band);
    try draw_match_bands(b, st, opts, g, first_row, last_row, band);
    if (opts.line_numbers) try draw_gutter(b, st, opts, g, first_row, last_row);
    try draw_rows(b, st, opts, g, first_row, last_row, band);
    try draw_caret(b, st, opts, g, band);
    try add_body_hitbox(st, opts, g);

    // A held edge-drag autoscrolls, so it needs every vsync. A focused caret only
    // changes at its blink edges: schedule a single wakeup at the next one instead of
    // animating every frame (so a focused-but-idle editor renders ~2×/s, not 125×/s).
    if (st.dragging) {
        p.animating = true;
    } else if (st.focused) {
        p.request_redraw_after(next_blink_edge_s(st, p.now_s));
    }

    // Caret rect for an overlay anchor (same geometry as draw_caret, but every focused frame, not
    // gated on the blink). Zeroed when unfocused so a stale popup can hide.
    if (opts.caret_out) |co| {
        if (st.focused) {
            const crow = vis_row_of_offset(st, st.caret);
            const ccol = vis_col_of(st, crow, st.caret);
            co.* = .{
                g.text_x + @as(f32, @floatFromInt(ccol)) * st.char_w,
                g.text_y + @as(f32, @floatFromInt(crow)) * g.line_h - st.scroll_y,
                CARET_W,
                g.line_h,
            };
        } else co.* = .{ 0, 0, 0, 0 };
    }

    st.last_text_x = g.text_x;
    st.last_text_y = g.text_y;
    st.last_line_h = g.line_h;
    st.last_view_h = g.view_h;
    st.last_fold_x = g.fold_x;
    st.last_fold_w = g.fold_w;
    return SizeF.init(w, h);
}

fn rand_text(rng: std.Random, buf: []u8) []const u8 {
    const m = rng.uintLessThan(usize, buf.len) + 1;
    for (buf[0..m]) |*b| {
        b.* = if (rng.uintLessThan(u8, 4) == 0) '\n' else 'a' + rng.uintLessThan(u8, 26);
    }
    return buf[0..m];
}

// The incrementally maintained line index must equal a from-scratch rebuild after
// every edit. Drives thousands of random splices (insert / delete / replace,
// newlines included) through edit_replace and asserts line_starts matches
// rebuild_line_index byte-for-byte - the equivalence proof for the incremental
// update_line_index hot path.
test "incremental line index equals full rebuild over random edits" {
    var backing: [4096]u8 = undefined;
    var st: TextAreaState = .{ .buf = .{ .bytes = &backing, .len = 0 } };
    var prng = std.Random.DefaultPrng.init(0x9E3779B97F4A7C15);
    const rng = prng.random();
    var snap: [MAX_LINES]u32 = undefined;
    var tbuf: [6]u8 = undefined;

    var iter: usize = 0;
    while (iter < 30000) : (iter += 1) {
        const len = st.buf.len;
        const a = rng.uintLessThan(usize, len + 1);
        switch (rng.uintLessThan(u8, 3)) {
            0 => _ = edit_replace(&st, a, a, rand_text(rng, &tbuf), false), // insert
            1 => if (len > 0) {
                // delete
                _ = edit_replace(&st, a, a + rng.uintLessThan(usize, len - a + 1), "", false);
            },
            else => if (len > 0) {
                // replace
                _ = edit_replace(
                    &st,
                    a,
                    a + rng.uintLessThan(usize, len - a + 1),
                    rand_text(rng, &tbuf),
                    false,
                );
            },
        }
        const inc_count = st.line_count;
        @memcpy(snap[0..inc_count], st.line_starts[0..inc_count]);
        rebuild_line_index(&st);
        try std.testing.expectEqual(inc_count, st.line_count);
        try std.testing.expectEqualSlices(
            u32,
            snap[0..inc_count],
            st.line_starts[0..st.line_count],
        );
    }
}

// Regression for the clamped-base case: a buffer with MORE than MAX_LINES
// newlines indexes only the first MAX_LINES, so an edit near the top must fall
// back to a full rebuild (the incremental tail is truncated). Editing near the
// front keeps line_count pinned at the cap so this path is actually exercised.
test "incremental index stays correct over the MAX_LINES cap" {
    var backing: [MAX_LINES * 2]u8 = undefined;
    // ~MAX_LINES newlines -> over cap
    for (&backing, 0..) |*c, i| c.* = if (i % 2 == 0) '\n' else 'a';
    var st: TextAreaState = .{ .buf = .{ .bytes = &backing, .len = backing.len } };
    rebuild_line_index(&st);
    try std.testing.expectEqual(MAX_LINES, st.line_count); // confirm the index is clamped

    var prng = std.Random.DefaultPrng.init(0xC0FFEEC0FFEE);
    const rng = prng.random();
    var snap: [MAX_LINES]u32 = undefined;

    var iter: usize = 0;
    while (iter < 5000) : (iter += 1) {
        const len = st.buf.len;
        // edit near the top, where the bug bit
        const a = rng.uintLessThan(usize, @min(len, 200) + 1);
        if (rng.uintLessThan(u8, 2) == 0 and len + 3 <= backing.len) {
            _ = edit_replace(&st, a, a, "\nq\n", false); // insert (adds newlines)
        } else {
            const b = a + rng.uintLessThan(usize, @min(len - a, 8) + 1);
            _ = edit_replace(&st, a, b, "", false); // delete near the top
        }
        const inc_count = st.line_count;
        @memcpy(snap[0..inc_count], st.line_starts[0..inc_count]);
        rebuild_line_index(&st);
        try std.testing.expectEqual(inc_count, st.line_count);
        try std.testing.expectEqualSlices(
            u32,
            snap[0..inc_count],
            st.line_starts[0..st.line_count],
        );
    }
}
