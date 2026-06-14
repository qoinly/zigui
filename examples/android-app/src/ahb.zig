// The producer half of the zero-copy frame path: synthesizes a small pool of YUV
// AHardwareBuffers (the frames a decoder would feed) and wraps each as a zigui
// frame surface the renderer imports with no copy. Each buffer holds one phase of
// a scrolling pattern; the page cycles them per frame for a live animation - and
// because every buffer is filled once up front, nothing ever rewrites a buffer
// the GPU is still sampling, so the cycle needs no producer/consumer fencing.
const std = @import("std");
const zigui = @import("zigui");

// libandroid (AHardwareBuffer, since API 26). lockPlanes hands per-plane pointers
// + strides, so the same fill works whether the driver lays the buffer out as
// NV12 (interleaved chroma, pixel_stride 2) or I420 (planar, pixel_stride 1).
const Desc = extern struct {
    width: u32,
    height: u32,
    layers: u32,
    format: u32,
    usage: u64,
    stride: u32,
    rfu0: u32 = 0,
    rfu1: u32 = 0,
};
const Plane = extern struct { data: ?*anyopaque, pixel_stride: u32, row_stride: u32 };
const Planes = extern struct { plane_count: u32, planes: [4]Plane };
const Buffer = opaque {};

extern fn AHardwareBuffer_allocate(*const Desc, *?*Buffer) c_int;
extern fn AHardwareBuffer_lockPlanes(*Buffer, u64, i32, ?*const anyopaque, *Planes) c_int;
extern fn AHardwareBuffer_unlock(*Buffer, ?*i32) c_int;

const FORMAT_Y8Cb8Cr8_420: u32 = 0x23;
const USAGE_CPU_WRITE_OFTEN: u64 = 0x30;
const USAGE_GPU_SAMPLED_IMAGE: u64 = 0x100;

// Even dimensions: NV12 chroma is half-resolution in both axes.
const W: u32 = 256;
const H: u32 = 256;
// One buffer per animation phase; the pool dwarfs the frames-in-flight, so a
// buffer is long free again by the time the cycle returns to it.
const FRAMES: u32 = 12;
// Vsyncs each phase holds (the loop runs at the display refresh).
const HOLD: u32 = 3;

var surfaces: [FRAMES]zigui.FrameSurface = undefined;
var source: zigui.FrameSource = undefined;
var tick: u32 = 0;
var state: enum { cold, ready, failed } = .cold;

// A frame node showing the imported pool, or a label when the device cannot
// import an AHardwareBuffer. Cycles a new phase onto the source each call.
pub fn frame_node() *zigui.Node {
    ensure();
    if (state != .ready) {
        return zigui.text("AHardwareBuffer import unsupported here.", .{ .size = 16 });
    }
    const phase = (tick / HOLD) % FRAMES;
    tick +%= 1;
    source.submit_surface(@ptrCast(&surfaces[phase]), .{});
    return zigui.frame(&source, .{ .fit = .contain });
}

fn ensure() void {
    if (state != .cold) return;
    state = .failed; // a failed step leaves it here; only full success flips to ready
    const r = zigui.renderer_handle();
    if (!r.ahb_supported()) return;
    source = zigui.FrameSource.init(r);
    var i: u32 = 0;
    while (i < FRAMES) : (i += 1) {
        const buf = alloc_filled(i) orelse return;
        surfaces[i] = r.create_ahb_nv12_surface(@ptrCast(buf), W, H) orelse return;
    }
    state = .ready;
}

// Allocates one buffer and fills phase i; the buffer is intentionally never
// released (process-lived, the surface aliases it for the app's lifetime).
fn alloc_filled(phase: u32) ?*Buffer {
    var buf: ?*Buffer = null;
    const desc = Desc{
        .width = W,
        .height = H,
        .layers = 1,
        .format = FORMAT_Y8Cb8Cr8_420,
        .usage = USAGE_CPU_WRITE_OFTEN | USAGE_GPU_SAMPLED_IMAGE,
        .stride = 0,
    };
    if (AHardwareBuffer_allocate(&desc, &buf) != 0) return null;
    if (!fill(buf.?, phase)) return null;
    return buf;
}

// A horizontal luma ramp scrolled by the phase, under a neutral top half and a
// red-tinted bottom half: the moving ramp proves luma sampling and animation, the
// static tint split proves chroma sampling and the half-resolution plane geometry.
fn fill(buf: *Buffer, phase: u32) bool {
    var planes: Planes = undefined;
    if (AHardwareBuffer_lockPlanes(buf, USAGE_CPU_WRITE_OFTEN, -1, null, &planes) != 0) {
        return false;
    }
    std.debug.assert(planes.plane_count >= 3); // Y, Cb, Cr
    std.debug.assert(planes.planes[0].row_stride >= W); // the luma plane spans the row
    const yb: [*]u8 = @ptrCast(planes.planes[0].data.?);
    const cb: [*]u8 = @ptrCast(planes.planes[1].data.?);
    const cr: [*]u8 = @ptrCast(planes.planes[2].data.?);
    const y_row = planes.planes[0].row_stride;
    const y_pix = planes.planes[0].pixel_stride;
    const shift = phase * W / FRAMES; // the ramp's per-phase scroll offset
    var y: u32 = 0;
    while (y < H) : (y += 1) {
        var x: u32 = 0;
        while (x < W) : (x += 1) {
            const col = (x + shift) % W;
            const ramp = 16 + (col * 219) / (W - 1); // 16..235, the limited-range luma span
            yb[y * y_row + x * y_pix] = @intCast(ramp);
        }
    }
    // The chroma planes are half-width; guard their driver strides like the luma.
    std.debug.assert(planes.planes[1].row_stride >= (W / 2) * planes.planes[1].pixel_stride);
    std.debug.assert(planes.planes[2].row_stride >= (W / 2) * planes.planes[2].pixel_stride);
    var cy: u32 = 0;
    while (cy < H / 2) : (cy += 1) {
        const red = cy >= H / 4; // bottom half of the chroma plane reddens
        var cx: u32 = 0;
        while (cx < W / 2) : (cx += 1) {
            cb[cy * planes.planes[1].row_stride + cx * planes.planes[1].pixel_stride] = 128;
            cr[cy * planes.planes[2].row_stride + cx * planes.planes[2].pixel_stride] =
                if (red) @as(u8, 200) else 128;
        }
    }
    return AHardwareBuffer_unlock(buf, null) == 0;
}
