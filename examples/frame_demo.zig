const std = @import("std");
const builtin = @import("builtin");
const zigui = @import("zigui");

extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;

// Pace the producer without pulling in the std async/Io machinery just for a demo.
fn sleep_ms(ms: u32) void {
    if (builtin.os.tag == .windows) {
        Sleep(ms);
    } else {
        var ts = std.c.timespec{ .sec = 0, .nsec = @intCast(@as(u64, ms) * std.time.ns_per_ms) };
        _ = std.c.nanosleep(&ts, null);
    }
}

// CoreVideo, just enough to stand in for a decoder: make IOSurface-backed NV12
// CVPixelBuffers (metal-compatible) and fill their planes. A real client gets these
// straight from VideoToolbox; here the demo synthesizes them. macOS only.
const cv = struct {
    extern "CoreVideo" fn CVPixelBufferCreate(
        allocator: ?*anyopaque,
        width: usize,
        height: usize,
        pixel_format: u32,
        attrs: ?*anyopaque,
        out: *?*anyopaque,
    ) i32;
    extern "CoreVideo" fn CVPixelBufferLockBaseAddress(pb: ?*anyopaque, flags: u64) i32;
    extern "CoreVideo" fn CVPixelBufferUnlockBaseAddress(pb: ?*anyopaque, flags: u64) i32;
    extern "CoreVideo" fn CVPixelBufferGetBaseAddressOfPlane(pb: ?*anyopaque, plane: usize) ?[*]u8;
    extern "CoreVideo" fn CVPixelBufferGetBytesPerRowOfPlane(pb: ?*anyopaque, plane: usize) usize;
    extern "CoreVideo" fn CVBufferRelease(b: ?*anyopaque) void;
    extern "CoreFoundation" fn CFDictionaryCreate(
        allocator: ?*anyopaque,
        keys: [*]const ?*const anyopaque,
        values: [*]const ?*const anyopaque,
        count: isize,
        key_cb: ?*const anyopaque,
        value_cb: ?*const anyopaque,
    ) ?*anyopaque;
    extern "CoreFoundation" fn CFRelease(cf: ?*anyopaque) void;
    extern "CoreFoundation" const kCFTypeDictionaryKeyCallBacks: anyopaque;
    extern "CoreFoundation" const kCFTypeDictionaryValueCallBacks: anyopaque;
    extern "CoreFoundation" const kCFBooleanTrue: ?*anyopaque;
    extern "CoreVideo" const kCVPixelBufferMetalCompatibilityKey: ?*anyopaque;
};

// '420v' - 8-bit bi-planar Y'CbCr 4:2:0, video range (matches bt709 limited).
const nv12_video_range: u32 = 0x34323076;

// 4:3 source so `contain` letterboxing shows in a non-4:3 window. NV12 needs even
// dimensions; chroma is half size in each axis.
const W = 256;
const H = 192;
const CW = W / 2;
const CH = H / 2;

// A small pool so the producer never refills a buffer the source or GPU still
// holds: the live-reference window is the source's slots (3) plus frames in flight
// (max_frames_in_flight + 1 = 4) = 7, so 8 always leaves the refilled one free.
const pool_size = 8;
// Windows and Linux share the renderer-created surface pool; macOS feeds
// CVPixelBuffers from a producer thread instead.
const has_shared_pool = builtin.os.tag == .windows or builtin.os.tag == .linux;
const PoolSurface = if (has_shared_pool) zigui.FrameSurface else struct {};
const Pool = if (has_shared_pool) [pool_size]PoolSurface else void;
const PoolLuma = if (has_shared_pool) [pool_size][W * H]u8 else void;
const PoolChroma = if (has_shared_pool) [pool_size][W * H / 2]u8 else void;

// Keep demo pixels off the main stack; the producer rewrites this fixed pool.
var pool_luma: PoolLuma = if (has_shared_pool) undefined else {};
var pool_chroma: PoolChroma = if (has_shared_pool) undefined else {};

const App = struct {
    source: zigui.FrameSource = undefined,
    started: bool = false,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,
    pool: [pool_size]?*anyopaque = .{null} ** pool_size,
    shared_pool: Pool = if (has_shared_pool) undefined else {},
    shared_count: usize = 0,
    shared_ready: bool = false,
    shared_next: u32 = 0,

    // Called after the window closes (run returns): stop the producer, free the
    // source's refs, then release the pool buffers.
    fn shutdown(self: *App) void {
        self.running.store(false, .release);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        if (self.started) self.source.deinit();
        deinit_shared_pool(self);
        if (builtin.os.tag == .macos) {
            for (&self.pool) |*pb| {
                if (pb.*) |p| cv.CVBufferRelease(p);
                pb.* = null;
            }
        }
    }
};

pub fn main() !void {
    var state: App = .{};
    var app = try zigui.App.init(.{ .title = "Frame demo", .size = .{ 800, 600 } });
    defer app.deinit();
    try app.run(&state, .{ .body = render });
    state.shutdown();
}

fn render(f: *zigui.Frame, app: *App) *zigui.Node {
    _ = f;
    // The renderer is reachable only inside a render pass, so the source and its
    // feeder thread spin up on the first frame. A real client starts its decoder
    // the same way once it has a handle to feed.
    if (!app.started) {
        const renderer = zigui.renderer_handle();
        app.source = zigui.FrameSource.init(renderer);
        if (has_shared_pool) {
            init_shared_pool(app, renderer);
            app.started = true;
        } else {
            app.running.store(true, .release);
            if (std.Thread.spawn(.{}, produce, .{app})) |t| {
                app.thread = t;
                app.started = true;
            } else |_| {
                app.running.store(false, .release);
            }
        }
    }
    if (has_shared_pool) produce_shared(app, zigui.renderer_handle());
    const label = switch (builtin.os.tag) {
        .windows => "External frame: shared NV12, YUV->RGB on D3D11",
        .linux => "External frame: shared NV12, YUV->RGB on Vulkan",
        else => "External frame: zero-copy NV12, YUV->RGB on the gpu",
    };
    return zigui.col(.{ .pad = .lg, .gap = .md, .grow = 1 }, &.{
        zigui.text(label, .{ .size = 16 }),
        zigui.frame(&app.source, .{ .fit = .contain }),
    });
}

// The producer stands in for a decoder emitting NV12 surfaces. It fills a pool
// buffer, hands it off newest-wins, and rotates; the source drops anything the
// render side does not pick up.
fn produce(app: *App) void {
    if (builtin.os.tag != .macos) return; // the CVPixelBuffer source is macOS-only
    for (&app.pool) |*pb| pb.* = create_nv12();
    var t: u32 = 0;
    while (app.running.load(.acquire)) {
        const pb = app.pool[t % pool_size] orelse {
            sleep_ms(16);
            continue;
        };
        fill_nv12(pb, t);
        app.source.submit_surface(pb, .{});
        t +%= 1;
        sleep_ms(16);
    }
}

fn init_shared_pool(app: *App, renderer: *zigui.Renderer) void {
    if (app.shared_ready) return;
    switch (builtin.os.tag) {
        .windows, .linux => for (&app.shared_pool, 0..) |*surface, i| {
            surface.* = renderer.create_shared_nv12_surface(W, H) orelse break;
            app.shared_count = i + 1;
        },
        else => {},
    }
    if (has_shared_pool) app.shared_ready = app.shared_count == pool_size;
}

fn deinit_shared_pool(app: *App) void {
    switch (builtin.os.tag) {
        .windows, .linux => for (app.shared_pool[0..app.shared_count]) |*surface|
            surface.deinit(),
        else => {},
    }
    app.shared_count = 0;
    app.shared_ready = false;
}

fn produce_shared(app: *App, renderer: *zigui.Renderer) void {
    switch (builtin.os.tag) {
        .windows, .linux => {
            if (!app.shared_ready) return;
            var attempts: usize = 0;
            while (attempts < pool_size) : (attempts += 1) {
                const idx = app.shared_next % pool_size;
                const surface = &app.shared_pool[idx];
                if (!surface.available()) {
                    app.shared_next +%= 1;
                    continue;
                }
                fill_nv12_planes(
                    pool_luma[idx][0..],
                    pool_chroma[idx][0..],
                    app.shared_next,
                );
                if (!renderer.update_shared_nv12_surface(
                    surface,
                    pool_luma[idx][0..].ptr,
                    W,
                    pool_chroma[idx][0..].ptr,
                    W,
                )) return;
                app.source.submit_surface(surface, .{});
                app.shared_next +%= 1;
                return;
            }
        },
        else => {},
    }
}

fn fill_nv12_planes(y: []u8, chroma: []u8, t: u32) void {
    switch (builtin.os.tag) {
        .windows, .linux => {
            std.debug.assert(y.len >= W * H);
            std.debug.assert(chroma.len >= W * H / 2);
            const off: usize = t % 32;
            var row: usize = 0;
            while (row < H) : (row += 1) {
                var col: usize = 0;
                while (col < W) : (col += 1) {
                    const grid = ((col + off) % 32 == 0) or ((row + off) % 32 == 0);
                    y[row * W + col] = if (grid) 235 else 110;
                }
            }
            var cy: usize = 0;
            while (cy < CH) : (cy += 1) {
                var cx: usize = 0;
                while (cx < CW) : (cx += 1) {
                    const o = cy * W + cx * 2;
                    chroma[o + 0] = @intCast(16 + cx * 224 / (CW - 1)); // Cb
                    chroma[o + 1] = @intCast(16 + cy * 224 / (CH - 1)); // Cr
                }
            }
        },
        else => {},
    }
}

fn create_nv12() ?*anyopaque {
    const keys = [_]?*const anyopaque{@ptrCast(cv.kCVPixelBufferMetalCompatibilityKey)};
    const vals = [_]?*const anyopaque{@ptrCast(cv.kCFBooleanTrue)};
    const attrs = cv.CFDictionaryCreate(
        null,
        &keys,
        &vals,
        1,
        &cv.kCFTypeDictionaryKeyCallBacks,
        &cv.kCFTypeDictionaryValueCallBacks,
    ) orelse return null;
    defer cv.CFRelease(attrs);
    var pb: ?*anyopaque = null;
    if (cv.CVPixelBufferCreate(null, W, H, nv12_video_range, attrs, &pb) != 0) return null;
    return pb;
}

// Write the test pattern straight into the buffer's planes (respecting each plane's
// row stride): a drifting white grid in luma over a chroma field that ramps blue
// across and red down - colorful only if the YUV->RGB path runs.
fn fill_nv12(pb: *anyopaque, t: u32) void {
    if (cv.CVPixelBufferLockBaseAddress(pb, 0) != 0) return;
    defer _ = cv.CVPixelBufferUnlockBaseAddress(pb, 0);

    const y = cv.CVPixelBufferGetBaseAddressOfPlane(pb, 0) orelse return;
    const y_stride = cv.CVPixelBufferGetBytesPerRowOfPlane(pb, 0);
    const off: usize = t % 32;
    var row: usize = 0;
    while (row < H) : (row += 1) {
        var col: usize = 0;
        while (col < W) : (col += 1) {
            const grid = ((col + off) % 32 == 0) or ((row + off) % 32 == 0);
            y[row * y_stride + col] = if (grid) 235 else 110;
        }
    }

    const c = cv.CVPixelBufferGetBaseAddressOfPlane(pb, 1) orelse return;
    const c_stride = cv.CVPixelBufferGetBytesPerRowOfPlane(pb, 1);
    var cy: usize = 0;
    while (cy < CH) : (cy += 1) {
        var cx: usize = 0;
        while (cx < CW) : (cx += 1) {
            const o = cy * c_stride + cx * 2;
            c[o + 0] = @intCast(16 + cx * 224 / (CW - 1)); // Cb: blue across width
            c[o + 1] = @intCast(16 + cy * 224 / (CH - 1)); // Cr: red down height
        }
    }
}
