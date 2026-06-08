const std = @import("std");
const renderer = @import("renderer.zig");

// Public handle to an external frame stream (a remote screen or video): the node
// tree references its current GPU texture, drawn outside the glyph atlas. The
// decoder runs on its own thread and calls submit_surface() with an NV12
// CVPixelBuffer; the render thread calls acquire() once a frame, which imports it
// zero-copy. Handoff is newest-wins, so a slow consumer drops stale frames instead
// of building up latency. The producer side only retains the buffer and writes its
// own mailbox slot - the refcount is atomic and the slot is disjoint from the
// consumer's, so submit_surface is safe to call from the decode thread.

// How the frame is mapped into its laid-out rect.
pub const Fit = enum {
    contain, // scale to fit, preserve aspect (letterbox)
    cover, // scale to fill, preserve aspect (crop)
    fill, // stretch to the rect, ignore aspect
    native, // 1:1 source pixels, centered
};

pub const FrameOpts = struct {
    fit: Fit = .contain,
    opacity: f32 = 1.0,
};

// The matrix that turns the decoder's color primaries into RGB. A decoder reports
// these alongside the frame; the wrong pair tints the whole image.
pub const Colorspace = enum { bt601, bt709, bt2020 };
pub const Range = enum { limited, full };

pub const FrameMeta = struct {
    colorspace: Colorspace = .bt709,
    range: Range = .limited,
};

// The YUV->RGB matrix for `meta`, baked to three rows so the shader just does
// rgb[c] = dot(row[c].xyz, yuv_normalized) + row[c].w - all the colorspace and
// range arithmetic lives here on the CPU, computed once per format change, not per
// pixel. Inputs are the normalized [0,1] plane samples (Y, then Cb, Cr).
pub fn csc_rows(meta: FrameMeta) [3][4]f32 {
    const k: [2]f32 = switch (meta.colorspace) {
        .bt601 => .{ 0.299, 0.114 },
        .bt709 => .{ 0.2126, 0.0722 },
        .bt2020 => .{ 0.2627, 0.0593 },
    };
    const kr = k[0];
    const kb = k[1];
    const kg = 1.0 - kr - kb;
    const cr_to_r = 2.0 * (1.0 - kr);
    const cb_to_b = 2.0 * (1.0 - kb);
    const cb_to_g = -(2.0 * kb * (1.0 - kb) / kg);
    const cr_to_g = -(2.0 * kr * (1.0 - kr) / kg);

    // Map normalized samples to the signal the matrix expects: scale luma off its
    // black floor, recentre chroma on zero. Limited range packs the signal into
    // 16..235 (luma) / 16..240 (chroma); full range uses the whole 0..255.
    const Affine = struct { sy: f32, oy: f32, sc: f32, oc: f32 };
    const t: Affine = switch (meta.range) {
        .full => .{ .sy = 1.0, .oy = 0.0, .sc = 1.0, .oc = -0.5 },
        .limited => .{
            .sy = 255.0 / 219.0,
            .oy = -(16.0 / 255.0) * (255.0 / 219.0),
            .sc = 255.0 / 224.0,
            .oc = -(128.0 / 255.0) * (255.0 / 224.0),
        },
    };

    return .{
        .{ t.sy, 0.0, cr_to_r * t.sc, t.oy + cr_to_r * t.oc },
        .{ t.sy, cb_to_g * t.sc, cr_to_g * t.sc, t.oy + (cb_to_g + cr_to_g) * t.oc },
        .{ t.sy, cb_to_b * t.sc, 0.0, t.oy + cb_to_b * t.oc },
    };
}

// What the render thread reads for a single frame. `tex` is the luma plane (or the
// whole BGRA image); `tex_cbcr` is the NV12 chroma plane, null for BGRA. `csc` is
// meaningful only when tex_cbcr is set.
pub const Current = struct {
    tex: *anyopaque,
    tex_cbcr: ?*anyopaque = null,
    csc: [3][4]f32 = .{.{ 0, 0, 0, 0 }} ** 3,
    width: f32,
    height: f32,
};

// Lock-free single-producer / single-consumer newest-wins index handoff over three
// slots. The producer fills producer_slot() then calls publish(); the consumer
// calls take() for the newest filled slot, or null if none arrived since the last
// take. {front, middle, back} is always a permutation of the three indices, so no
// slot is ever owned by both sides at once - which is what makes it lock-free safe.
const SlotMailbox = struct {
    pub const slot_count = 3;

    front: u8 = 0, // consumer-owned
    back: u8 = 1, // producer-owned
    // Middle (newest ready) index plus a fresh bit; the only field both threads
    // touch, moved between sides by atomic swap.
    shared: std.atomic.Value(u32) = std.atomic.Value(u32).init(pack(2, false)),

    // Producer: the slot to fill before the next publish().
    fn producer_slot(self: *const SlotMailbox) u8 {
        std.debug.assert(self.back < slot_count);
        return self.back;
    }

    // Producer: mark the filled slot newest and rotate the old middle in to fill
    // next. The release half of the swap publishes the slot's contents.
    fn publish(self: *SlotMailbox) void {
        std.debug.assert(self.back < slot_count);
        const old = self.shared.swap(pack(self.back, true), .acq_rel);
        self.back = @intCast(old >> 1);
        std.debug.assert(self.back < slot_count);
    }

    // Consumer: the newest filled slot, or null if nothing new since the last take.
    // Single consumer, so the fresh bit cannot clear between the load and the swap.
    fn take(self: *SlotMailbox) ?u8 {
        std.debug.assert(self.front < slot_count);
        if (self.shared.load(.acquire) & 1 == 0) return null;
        const got = self.shared.swap(pack(self.front, false), .acq_rel);
        std.debug.assert(got & 1 != 0);
        self.front = @intCast(got >> 1);
        std.debug.assert(self.front < slot_count);
        return self.front;
    }

    fn pack(index: u8, fresh: bool) u32 {
        std.debug.assert(index < slot_count);
        return (@as(u32, index) << 1) | @intFromBool(fresh);
    }
};

// Imported CV texture refs in flight, released as the ring cycles past. A ref is
// dropped only after the ring has moved max_frames_in_flight + 1 slots on, by which
// point the command buffer that last sampled it has completed (the drawable pool is
// the throttle, one step behind the build-phase import) - so the IOSurface is never
// recycled mid-read. Derived from the pinned pool depth so the two cannot drift.
const ring_count: u8 = @intCast(renderer.max_frames_in_flight + 1);

const CvSlot = struct {
    luma: ?*anyopaque = null, // CVMetalTexture refs we own; release frees the binding
    chroma: ?*anyopaque = null,
};

pub const FrameSource = struct {
    renderer: *renderer.Renderer,

    // Newest-wins handoff of decoder CVPixelBuffers. We hold one ref per slot until
    // the slot is overwritten; the mailbox guarantees producer and consumer never
    // touch the same slot, so a held buffer is stable while the consumer reads it.
    bufs: [SlotMailbox.slot_count]?*anyopaque = .{null} ** SlotMailbox.slot_count,
    csc: [SlotMailbox.slot_count][3][4]f32 = .{.{.{ 0, 0, 0, 0 }} ** 3} ** SlotMailbox.slot_count,
    mailbox: SlotMailbox = .{},

    // Render-thread only: imported texture refs in flight + the frame in use now.
    ring: [ring_count]CvSlot = .{CvSlot{}} ** ring_count,
    ring_at: u8 = 0,
    cur_tex: ?*anyopaque = null,
    cur_chroma: ?*anyopaque = null,
    cur_csc: [3][4]f32 = .{.{ 0, 0, 0, 0 }} ** 3,
    cur_w: u32 = 0,
    cur_h: u32 = 0,

    pub fn init(r: *renderer.Renderer) FrameSource {
        return .{ .renderer = r };
    }

    // Call after the producer thread has stopped: drops the held CVPixelBuffers and
    // the imported texture refs.
    pub fn deinit(self: *FrameSource) void {
        for (&self.bufs) |*b| {
            if (b.*) |pb| renderer.Renderer.release_surface(pb);
            b.* = null;
        }
        for (&self.ring) |*slot| free_cv_slot(slot);
    }

    // Producer side (decode thread). Hands off a decoder NV12 CVPixelBuffer
    // (IOSurface-backed) newest-wins, dropping the previous frame if the consumer has
    // not taken it. We retain it until the slot is reused. `meta` picks the matrix.
    pub fn submit_surface(self: *FrameSource, pixel_buffer: *anyopaque, meta: FrameMeta) void {
        const slot = self.mailbox.producer_slot();
        std.debug.assert(slot < SlotMailbox.slot_count);
        renderer.Renderer.retain_surface(pixel_buffer);
        if (self.bufs[slot]) |prev| renderer.Renderer.release_surface(prev);
        self.bufs[slot] = pixel_buffer;
        self.csc[slot] = csc_rows(meta);
        self.mailbox.publish();
    }

    // Consumer side (render thread). Returns the newest frame, the last one still if
    // nothing new arrived, or null before the first frame. Call once per rendered
    // frame: a fresh frame is imported here.
    pub fn acquire(self: *FrameSource) ?Current {
        if (self.mailbox.take()) |slot| self.import(slot);
        const tex = self.cur_tex orelse return null;
        std.debug.assert(self.cur_w > 0); // a set cur_tex always carries real dims
        std.debug.assert(self.cur_h > 0);
        return .{
            .tex = tex,
            .tex_cbcr = self.cur_chroma,
            .csc = self.cur_csc,
            .width = @floatFromInt(self.cur_w),
            .height = @floatFromInt(self.cur_h),
        };
    }

    // Render-thread only: import buffer `slot` zero-copy into the next ring entry and
    // make it current. Skips silently if the slot is empty or the import fails.
    fn import(self: *FrameSource, slot: u8) void {
        std.debug.assert(slot < SlotMailbox.slot_count);
        std.debug.assert(self.ring_at < ring_count);
        const pb = self.bufs[slot] orelse return;
        const imp = self.renderer.import_nv12(pb) orelse return;

        // The entry we are about to reuse last fed a frame ring_count draws ago,
        // which the GPU has finished; drop its refs before storing the new ones.
        const r = &self.ring[self.ring_at];
        free_cv_slot(r);
        r.* = .{ .luma = imp.cv_luma, .chroma = imp.cv_chroma };
        self.cur_tex = imp.luma;
        self.cur_chroma = imp.chroma;
        self.cur_csc = self.csc[slot];
        self.cur_w = imp.width;
        self.cur_h = imp.height;
        self.ring_at = (self.ring_at + 1) % ring_count;
        self.renderer.flush_texture_cache();
    }
};

fn free_cv_slot(slot: *CvSlot) void {
    if (slot.luma) |x| renderer.Renderer.release_cv_texture(x);
    if (slot.chroma) |x| renderer.Renderer.release_cv_texture(x);
    slot.* = .{};
}

test "slot mailbox: newest-wins handoff keeps the permutation invariant" {
    const t = std.testing;
    const check = struct {
        fn perm(m: *const SlotMailbox) !void {
            const mid: u8 = @intCast(m.shared.load(.acquire) >> 1);
            try t.expect(m.front < SlotMailbox.slot_count);
            try t.expect(m.back < SlotMailbox.slot_count);
            try t.expect(mid < SlotMailbox.slot_count);
            try t.expect(m.front != m.back);
            try t.expect(m.front != mid);
            try t.expect(m.back != mid);
        }
    }.perm;

    var m = SlotMailbox{};
    try check(&m);
    try t.expect(m.take() == null); // nothing produced yet

    const first = m.producer_slot();
    m.publish();
    try check(&m);
    try t.expectEqual(first, m.take().?);
    try t.expect(m.take() == null); // already drained
    try check(&m);

    // Two produces, one take: the consumer gets the latest, the middle is dropped.
    _ = m.producer_slot();
    m.publish();
    const newest = m.producer_slot();
    m.publish();
    try check(&m);
    try t.expectEqual(newest, m.take().?);
    try check(&m);

    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        _ = m.producer_slot();
        m.publish();
        _ = m.take();
        try check(&m);
    }
}

test "csc maps the luma extremes to black and white" {
    const t = std.testing;
    const apply = struct {
        fn rgb(rows: [3][4]f32, y: f32, cb: f32, cr: f32) [3]f32 {
            var out: [3]f32 = undefined;
            for (0..3) |c| out[c] = rows[c][0] * y + rows[c][1] * cb + rows[c][2] * cr + rows[c][3];
            return out;
        }
    }.rgb;

    // Limited range: neutral chroma at the luma floor is black, at the ceiling
    // white. The exact endpoints prove the range scale and offsets are right.
    const lim = csc_rows(.{ .colorspace = .bt709, .range = .limited });
    const black = apply(lim, 16.0 / 255.0, 128.0 / 255.0, 128.0 / 255.0);
    const white = apply(lim, 235.0 / 255.0, 128.0 / 255.0, 128.0 / 255.0);
    for (0..3) |c| {
        try t.expectApproxEqAbs(@as(f32, 0.0), black[c], 0.005);
        try t.expectApproxEqAbs(@as(f32, 1.0), white[c], 0.005);
    }

    // Full range uses the whole 0..255: black at Y=0, white at Y=1.
    const full = csc_rows(.{ .colorspace = .bt709, .range = .full });
    const fb = apply(full, 0.0, 0.5, 0.5);
    const fw = apply(full, 1.0, 0.5, 0.5);
    for (0..3) |c| {
        try t.expectApproxEqAbs(@as(f32, 0.0), fb[c], 0.005);
        try t.expectApproxEqAbs(@as(f32, 1.0), fw[c], 0.005);
    }

    // Pure red in 709 limited: max Cr, neutral Cb, mid luma stays a believable red
    // (R high, G/B low) - guards against a swapped Cb/Cr column.
    const red = apply(lim, 0.5, 128.0 / 255.0, 240.0 / 255.0);
    try t.expect(red[0] > 0.8);
    try t.expect(red[2] < red[0]);
}
