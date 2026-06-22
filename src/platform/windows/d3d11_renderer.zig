// The Direct3D 11 renderer: the metal.zig analogue. Instanced draw from one
// dynamic StructuredBuffer (Map WRITE_DISCARD per batch) keeps it to a single
// upload per batch, no per-draw allocation. Geometry stays in points and the
// viewport constant is in points, so DPI scaling falls out of the NDC math with
// no extra uniform.

const std = @import("std");
const win32 = @import("win32.zig");
const com = @import("com.zig");
const dxgi = @import("dxgi.zig");
const d3d11 = @import("d3d11.zig");
const primitives = @import("../../primitives.zig");

const Quad = primitives.Quad;
const MonochromeSprite = primitives.MonochromeSprite;
const PolychromeSprite = primitives.PolychromeSprite;
const Polyline = primitives.Polyline;
const LineSegment = primitives.LineSegment;
const RingChart = primitives.RingChart;
const Primitive = primitives.Primitive;

const MAX_QUADS = 1024;
const MAX_SPRITES = 4096;
const MAX_COLOR_SPRITES = 256;
const MAX_POLYLINES = 1024;
const MAX_LINES = 1024;
const MAX_RINGS = 256;
const MAX_FRAMES = 8;
// A frame dimension past this is a programmer error, not a real decoder output.
const MAX_FRAME_DIM: u32 = 16384;

pub const max_frames_in_flight: u32 = 3;

// Modal-backdrop blur radius in points; scaled to pixels at draw time so the
// frost tracks DPI. Mirrors the macOS MPSImageGaussianBlur sigma (12px at 2x).
const BLUR_SIGMA_PT: f32 = 6.0;

pub const ClearColor = extern struct {
    rgba: [4]f32,

    pub fn init(r: f32, g: f32, b: f32, a: f32) ClearColor {
        return .{ .rgba = .{ r, g, b, a } };
    }
};

const Pipeline = struct {
    vs: ?*anyopaque = null,
    ps: ?*anyopaque = null,
};

const InstanceBuffer = struct {
    buffer: ?*anyopaque = null,
    srv: ?*anyopaque = null,
    stride: u32 = 0,
    capacity: u32 = 0,
};

const FrameSurfaceState = struct {
    tex: ?*anyopaque = null,
    srv: ?*anyopaque = null,
    chroma_tex: ?*anyopaque = null,
    chroma_srv: ?*anyopaque = null,
    mutex: ?*dxgi.IDXGIKeyedMutex = null,
    chroma_mutex: ?*dxgi.IDXGIKeyedMutex = null,
    owner_tex: ?*anyopaque = null,
    owner_chroma_tex: ?*anyopaque = null,
    owner_mutex: ?*dxgi.IDXGIKeyedMutex = null,
    owner_chroma_mutex: ?*dxgi.IDXGIKeyedMutex = null,
    shared_acquired: bool = false,
    // imported_nv12 copy tier only: the decode texture CopySubresourceRegion reads
    // each frame, and the array slice within it. null/0 for the zero-copy tiers.
    copy_src: ?*anyopaque = null,
    copy_slice: u32 = 0,
    // Owner + mailbox + GPU ring share this; producer writes only at owner ref.
    refs: std.atomic.Value(u32) = std.atomic.Value(u32).init(1),
};

// imported_nv12 wraps a producer's own NV12 texture (one texture, two plane SRVs)
// instead of staging CPU pixels: the decoder's GPU frame is sampled directly.
const SurfaceFormat = enum { bgra, nv12, shared_nv12, imported_nv12 };
const Plane = enum { luma, chroma };
// Shared-handle surfaces never read CPU pixels, but the legacy field stays
// non-null so old pointer-shape checks cannot trip over this format.
const shared_frame_pixel: u8 = 0;

// External frame surface. CPU-backed surfaces reuse upload textures; shared
// surfaces cache opened SRVs for a decoder-owned DXGI handle.
pub const FrameSurface = struct {
    format: SurfaceFormat,
    width: u32,
    height: u32,
    stride: u32,
    pixels: [*]u8,
    chroma_stride: u32 = 0,
    chroma_pixels: ?[*]u8 = null,
    shared_luma: ?win32.HANDLE = null,
    shared_chroma: ?win32.HANDLE = null,
    shared_acquire_key: u64 = 0,
    shared_release_key: u64 = 0,
    state: FrameSurfaceState = .{},

    pub fn init_bgra(width: u32, height: u32, stride: u32, pixels: [*]u8) FrameSurface {
        std.debug.assert(width > 0);
        std.debug.assert(height > 0);
        std.debug.assert(stride >= width * 4);
        return .{
            .format = .bgra,
            .width = width,
            .height = height,
            .stride = stride,
            .pixels = pixels,
        };
    }

    pub fn init_nv12(
        width: u32,
        height: u32,
        y_stride: u32,
        y_pixels: [*]u8,
        uv_stride: u32,
        uv_pixels: [*]u8,
    ) FrameSurface {
        std.debug.assert(width > 0);
        std.debug.assert(height > 0);
        std.debug.assert(width % 2 == 0);
        std.debug.assert(height % 2 == 0);
        std.debug.assert(y_stride >= width);
        std.debug.assert(uv_stride >= width);
        return .{
            .format = .nv12,
            .width = width,
            .height = height,
            .stride = y_stride,
            .pixels = y_pixels,
            .chroma_stride = uv_stride,
            .chroma_pixels = uv_pixels,
        };
    }

    pub fn init_shared_nv12(
        width: u32,
        height: u32,
        luma: win32.HANDLE,
        chroma: win32.HANDLE,
        acquire_key: u64,
        release_key: u64,
    ) FrameSurface {
        std.debug.assert(width > 0);
        std.debug.assert(height > 0);
        std.debug.assert(width % 2 == 0);
        std.debug.assert(height % 2 == 0);
        return .{
            .format = .shared_nv12,
            .width = width,
            .height = height,
            .stride = width,
            .pixels = @ptrCast(@constCast(&shared_frame_pixel)),
            .chroma_stride = width,
            .shared_luma = luma,
            .shared_chroma = chroma,
            .shared_acquire_key = acquire_key,
            .shared_release_key = release_key,
        };
    }

    pub fn init_imported_nv12(
        width: u32,
        height: u32,
        acquire_key: u64,
        release_key: u64,
    ) FrameSurface {
        std.debug.assert(width > 0);
        std.debug.assert(height > 0);
        std.debug.assert(width % 2 == 0);
        std.debug.assert(height % 2 == 0);
        return .{
            .format = .imported_nv12,
            .width = width,
            .height = height,
            .stride = width,
            .pixels = @ptrCast(@constCast(&shared_frame_pixel)),
            .chroma_stride = width,
            .shared_acquire_key = acquire_key,
            .shared_release_key = release_key,
        };
    }

    pub fn available(self: *const FrameSurface) bool {
        std.debug.assert(self.state.refs.load(.acquire) >= 1);
        return self.state.refs.load(.acquire) == 1;
    }

    pub fn deinit(self: *FrameSurface) void {
        std.debug.assert(self.state.refs.load(.acquire) == 1);
        release_shared_sync(self);
        release_shared_owner(self);
        release_shared_import(self);
        com.release(&self.state.chroma_srv);
        com.release(&self.state.chroma_tex);
        com.release(&self.state.srv);
        com.release(&self.state.tex);
        com.release(&self.state.copy_src);
    }

    fn release_shared_owner(self: *FrameSurface) void {
        com.release(&self.state.owner_chroma_mutex);
        com.release(&self.state.owner_mutex);
        com.release(&self.state.owner_chroma_tex);
        com.release(&self.state.owner_tex);
    }

    fn release_shared_import(self: *FrameSurface) void {
        com.release(&self.state.chroma_mutex);
        com.release(&self.state.mutex);
    }
};

fn query_keyed_mutex(tex: *anyopaque, out: *?*dxgi.IDXGIKeyedMutex) win32.HRESULT {
    var raw: ?*anyopaque = null;
    const hr = com.query_interface(tex, &dxgi.IID_IDXGIKeyedMutex, &raw);
    if (com.failed(hr)) return hr;
    out.* = @ptrCast(@alignCast(raw.?));
    return hr;
}

fn shared_handle(tex: *anyopaque) ?win32.HANDLE {
    var raw: ?*anyopaque = null;
    if (com.failed(com.query_interface(tex, &dxgi.IID_IDXGIResource, &raw))) return null;
    var res: ?*dxgi.IDXGIResource = @ptrCast(@alignCast(raw.?));
    defer com.release(&res);
    var handle: ?win32.HANDLE = null;
    if (com.failed(res.?.get_shared_handle(&handle))) return null;
    return handle;
}

fn release_shared_sync(surface: *FrameSurface) void {
    if (!surface.state.shared_acquired) return;
    if (surface.state.chroma_mutex) |mutex| _ = mutex.release_sync(surface.shared_release_key);
    if (surface.state.mutex) |mutex| _ = mutex.release_sync(surface.shared_release_key);
    surface.state.shared_acquired = false;
}

const FrameGpu = extern struct {
    bounds: [4]f32,
    clip_bounds: [4]f32,
    opacity: f32,
    _pad: [3]f32 = .{ 0, 0, 0 },
    csc: [3][4]f32 = .{.{ 0, 0, 0, 0 }} ** 3,

    comptime {
        std.debug.assert(@sizeOf(FrameGpu) == 96);
        std.debug.assert(@offsetOf(FrameGpu, "csc") == 48);
    }
};

// An offscreen color target usable as both a render target and a sampled
// texture: the blur ping-pongs between two of these before compositing.
const Offscreen = struct {
    tex: ?*anyopaque = null,
    rtv: ?*anyopaque = null,
    srv: ?*anyopaque = null,

    fn release(self: *Offscreen) void {
        com.release(&self.srv);
        com.release(&self.rtv);
        com.release(&self.tex);
    }
};

pub const Renderer = struct {
    device: *d3d11.ID3D11Device,
    context: *d3d11.ID3D11DeviceContext,
    swapchain: *dxgi.IDXGISwapChain,
    hwnd: win32.HWND,
    rtv: ?*anyopaque = null,
    // ID3D11Device1 (Windows 8+), QI'd once at init; gates
    // imported_nv12_handle_supported and opens NT-handle shared frames. Null when
    // the runtime lacks the interface.
    device1: ?*d3d11.ID3D11Device1 = null,

    quad_pipeline: Pipeline = .{},
    text_pipeline: Pipeline = .{},
    color_sprite_pipeline: Pipeline = .{},
    polyline_pipeline: Pipeline = .{},
    line_pipeline: Pipeline = .{},
    ring_pipeline: Pipeline = .{},
    frame_pipeline: Pipeline = .{},
    frame_nv12_pipeline: Pipeline = .{},

    quad_buffer: InstanceBuffer = .{},
    sprite_buffer: InstanceBuffer = .{},
    color_sprite_buffer: InstanceBuffer = .{},
    polyline_buffer: InstanceBuffer = .{},
    line_buffer: InstanceBuffer = .{},
    ring_buffer: InstanceBuffer = .{},

    blit_pipeline: Pipeline = .{},
    blur_h_pipeline: Pipeline = .{},
    blur_v_pipeline: Pipeline = .{},

    viewport_cb: ?*anyopaque = null,
    blur_cb: ?*anyopaque = null,
    frame_cb: ?*anyopaque = null,
    blend_state: ?*anyopaque = null,
    raster_state: ?*anyopaque = null,
    raster_state_scissor: ?*anyopaque = null,
    sampler_state: ?*anyopaque = null,

    scene_target: Offscreen = .{},
    blur_target: Offscreen = .{},
    offscreen_w: u32 = 0,
    offscreen_h: u32 = 0,

    last_w: u32 = 0,
    last_h: u32 = 0,
    dirty: bool = true,

    pub const Error = error{
        DeviceCreateFailed,
        SwapchainBufferFailed,
        ShaderCompilerMissing,
        ShaderCompileFailed,
        PipelineCreateFailed,
        BufferCreateFailed,
        StateCreateFailed,
    };

    pub fn init(target: *anyopaque) Error!Renderer {
        const hwnd: win32.HWND = @ptrCast(target);

        var rect: win32.RECT = undefined;
        _ = win32.GetClientRect(hwnd, &rect);
        const w: u32 = @intCast(@max(rect.right - rect.left, 1));
        const h: u32 = @intCast(@max(rect.bottom - rect.top, 1));

        var desc = dxgi.DXGI_SWAP_CHAIN_DESC{
            .BufferDesc = .{ .Width = w, .Height = h, .Format = dxgi.DXGI_FORMAT_B8G8R8A8_UNORM },
            .SampleDesc = .{ .Count = 1, .Quality = 0 },
            .BufferUsage = dxgi.DXGI_USAGE_RENDER_TARGET_OUTPUT,
            .BufferCount = 2,
            .OutputWindow = hwnd,
            .Windowed = win32.TRUE,
            .SwapEffect = dxgi.DXGI_SWAP_EFFECT_FLIP_DISCARD,
            .Flags = 0,
        };

        const levels = [_]u32{d3d11.D3D_FEATURE_LEVEL_11_0};
        var swapchain: ?*dxgi.IDXGISwapChain = null;
        var device: ?*d3d11.ID3D11Device = null;
        var context: ?*d3d11.ID3D11DeviceContext = null;
        const hr = d3d11.D3D11CreateDeviceAndSwapChain(
            null,
            d3d11.D3D_DRIVER_TYPE_HARDWARE,
            null,
            0,
            &levels,
            levels.len,
            d3d11.D3D11_SDK_VERSION,
            &desc,
            &swapchain,
            &device,
            null,
            &context,
        );
        if (com.failed(hr) or device == null or swapchain == null or context == null) {
            return error.DeviceCreateFailed;
        }

        var self = Renderer{
            .device = device.?,
            .context = context.?,
            .swapchain = swapchain.?,
            .hwnd = hwnd,
            .last_w = w,
            .last_h = h,
        };
        errdefer self.deinit();

        try self.ensure_rtv();
        try self.build_pipelines();
        try self.build_instance_buffers();
        try self.build_states();

        // imported_nv12 needs ID3D11Device1::OpenSharedResource1; its absence just
        // disables that path, leaving the CPU staging path as the fallback.
        var dev1: ?*anyopaque = null;
        if (com.succeeded(com.query_interface(self.device, &d3d11.IID_ID3D11Device1, &dev1))) {
            self.device1 = @ptrCast(@alignCast(dev1.?));
        }

        return self;
    }

    pub fn deinit(self: *Renderer) void {
        com.release(&self.rtv);
        com.release(&self.device1);
        com.release(&self.viewport_cb);
        com.release(&self.blur_cb);
        com.release(&self.frame_cb);
        com.release(&self.blend_state);
        com.release(&self.raster_state);
        com.release(&self.raster_state_scissor);
        com.release(&self.sampler_state);
        self.scene_target.release();
        self.blur_target.release();
        for ([_]*InstanceBuffer{
            &self.quad_buffer,     &self.sprite_buffer, &self.color_sprite_buffer,
            &self.polyline_buffer, &self.line_buffer,   &self.ring_buffer,
        }) |ib| {
            com.release(&ib.srv);
            com.release(&ib.buffer);
        }
        for ([_]*Pipeline{
            &self.quad_pipeline,     &self.text_pipeline,       &self.color_sprite_pipeline,
            &self.polyline_pipeline, &self.line_pipeline,       &self.ring_pipeline,
            &self.frame_pipeline,    &self.frame_nv12_pipeline, &self.blit_pipeline,
            &self.blur_h_pipeline,   &self.blur_v_pipeline,
        }) |p| {
            com.release(&p.vs);
            com.release(&p.ps);
        }
        _ = self.swapchain.vtable.Release(self.swapchain);
        _ = self.context.vtable.Release(self.context);
        _ = self.device.vtable.Release(self.device);
    }

    pub fn get_device(self: *Renderer) *anyopaque {
        return @ptrCast(self.device);
    }

    pub fn create_shared_nv12_surface(self: *Renderer, width: u32, height: u32) ?FrameSurface {
        std.debug.assert(width > 0);
        std.debug.assert(height > 0);
        std.debug.assert(width % 2 == 0);
        std.debug.assert(height % 2 == 0);

        var out = FrameSurface.init_shared_nv12(
            width,
            height,
            @ptrFromInt(1),
            @ptrFromInt(1),
            0,
            0,
        );
        if (!self.create_shared_plane(width, height, .luma, &out)) {
            out.deinit();
            return null;
        }
        if (!self.create_shared_plane(width / 2, height / 2, .chroma, &out)) {
            out.deinit();
            return null;
        }
        std.debug.assert(out.shared_luma != null);
        std.debug.assert(out.shared_chroma != null);
        return out;
    }

    pub fn update_shared_nv12_surface(
        self: *Renderer,
        surface: *FrameSurface,
        y: [*]const u8,
        y_stride: u32,
        uv: [*]const u8,
        uv_stride: u32,
    ) bool {
        std.debug.assert(surface.format == .shared_nv12);
        std.debug.assert(surface.width > 0);
        std.debug.assert(surface.height > 0);
        std.debug.assert(y_stride >= surface.width);
        std.debug.assert(uv_stride >= surface.width);
        const tex = surface.state.owner_tex orelse return false;
        const chroma_tex = surface.state.owner_chroma_tex orelse return false;
        const mutex = surface.state.owner_mutex orelse return false;
        const chroma_mutex = surface.state.owner_chroma_mutex orelse return false;
        if (com.failed(mutex.acquire_sync(surface.shared_release_key, 0))) return false;
        var chroma_acquired = false;
        defer {
            if (chroma_acquired) _ = chroma_mutex.release_sync(surface.shared_acquire_key);
            _ = mutex.release_sync(surface.shared_acquire_key);
        }
        if (com.failed(chroma_mutex.acquire_sync(surface.shared_release_key, 0))) return false;
        chroma_acquired = true;
        self.context.update_subresource(tex, 0, null, y, y_stride, 0);
        self.context.update_subresource(chroma_tex, 0, null, uv, uv_stride, 0);
        return true;
    }

    // The shared facade keeps the macOS import name; Windows accepts CPU-backed
    // frame surfaces and returns the SRVs needed by their format.
    pub const Nv12Textures = struct {
        luma: *anyopaque,
        chroma: ?*anyopaque,
        cv_luma: *anyopaque,
        cv_chroma: ?*anyopaque,
        width: u32,
        height: u32,
    };

    pub fn import_nv12(self: *Renderer, pixel_buffer: *anyopaque) ?Nv12Textures {
        const surface: *FrameSurface = @ptrCast(@alignCast(pixel_buffer));
        std.debug.assert(surface.width > 0);
        std.debug.assert(surface.height > 0);
        return switch (surface.format) {
            .bgra => self.import_bgra(surface),
            .nv12 => self.import_nv12_surface(surface),
            .shared_nv12 => self.import_shared_nv12_surface(surface),
            .imported_nv12 => self.import_imported_nv12_surface(surface),
        };
    }

    pub fn release_cv_texture(ref: *anyopaque) void {
        const surface: *FrameSurface = @ptrCast(@alignCast(ref));
        if (surface.format == .shared_nv12 or surface.format == .imported_nv12)
            release_shared_sync(surface);
        const old = surface.state.refs.fetchSub(1, .acq_rel);
        std.debug.assert(old > 1);
    }

    pub fn retain_surface(pixel_buffer: *anyopaque) void {
        const surface: *FrameSurface = @ptrCast(@alignCast(pixel_buffer));
        const old = surface.state.refs.fetchAdd(1, .acq_rel);
        std.debug.assert(old >= 1);
    }

    pub fn release_surface(pixel_buffer: *anyopaque) void {
        const surface: *FrameSurface = @ptrCast(@alignCast(pixel_buffer));
        const old = surface.state.refs.fetchSub(1, .acq_rel);
        std.debug.assert(old > 1);
    }

    pub fn flush_texture_cache(self: *Renderer) void {
        _ = self;
    }

    fn import_bgra(self: *Renderer, surface: *FrameSurface) ?Nv12Textures {
        std.debug.assert(surface.width > 0);
        std.debug.assert(surface.height > 0);
        std.debug.assert(surface.stride >= surface.width * 4);
        self.ensure_bgra_surface(surface);
        const tex = surface.state.tex orelse return null;
        const srv = surface.state.srv orelse return null;
        self.context.update_subresource(tex, 0, null, surface.pixels, surface.stride, 0);
        const old = surface.state.refs.fetchAdd(1, .acq_rel);
        std.debug.assert(old >= 1);
        return .{
            .luma = srv,
            .chroma = null,
            .cv_luma = @ptrCast(surface),
            .cv_chroma = null,
            .width = surface.width,
            .height = surface.height,
        };
    }

    fn import_nv12_surface(self: *Renderer, surface: *FrameSurface) ?Nv12Textures {
        std.debug.assert(surface.width % 2 == 0);
        std.debug.assert(surface.height % 2 == 0);
        std.debug.assert(surface.stride >= surface.width);
        std.debug.assert(surface.chroma_stride >= surface.width);
        std.debug.assert(surface.chroma_pixels != null);
        self.ensure_nv12_surface(surface);
        const luma = surface.state.srv orelse return null;
        const chroma = surface.state.chroma_srv orelse return null;
        self.context.update_subresource(
            surface.state.tex.?,
            0,
            null,
            surface.pixels,
            surface.stride,
            0,
        );
        self.context.update_subresource(
            surface.state.chroma_tex.?,
            0,
            null,
            surface.chroma_pixels.?,
            surface.chroma_stride,
            0,
        );
        const old = surface.state.refs.fetchAdd(1, .acq_rel);
        std.debug.assert(old >= 1);
        return .{
            .luma = luma,
            .chroma = chroma,
            .cv_luma = @ptrCast(surface),
            .cv_chroma = null,
            .width = surface.width,
            .height = surface.height,
        };
    }

    fn import_shared_nv12_surface(self: *Renderer, surface: *FrameSurface) ?Nv12Textures {
        std.debug.assert(surface.width % 2 == 0);
        std.debug.assert(surface.height % 2 == 0);
        std.debug.assert(surface.shared_luma != null);
        std.debug.assert(surface.shared_chroma != null);
        self.ensure_shared_nv12_surface(surface);
        const luma = surface.state.srv orelse return null;
        const chroma = surface.state.chroma_srv orelse return null;
        const mutex = surface.state.mutex orelse return null;
        const chroma_mutex = surface.state.chroma_mutex orelse return null;
        std.debug.assert(!surface.state.shared_acquired);
        if (com.failed(mutex.acquire_sync(surface.shared_acquire_key, 0))) return null;
        if (com.failed(chroma_mutex.acquire_sync(surface.shared_acquire_key, 0))) {
            _ = mutex.release_sync(surface.shared_release_key);
            return null;
        }
        surface.state.shared_acquired = true;
        const old = surface.state.refs.fetchAdd(1, .acq_rel);
        std.debug.assert(old >= 1);
        return .{
            .luma = luma,
            .chroma = chroma,
            .cv_luma = @ptrCast(surface),
            .cv_chroma = null,
            .width = surface.width,
            .height = surface.height,
        };
    }

    fn ensure_bgra_surface(self: *Renderer, surface: *FrameSurface) void {
        if (surface.state.tex != null and surface.state.srv != null) return;
        std.debug.assert(surface.state.tex == null);
        std.debug.assert(surface.state.srv == null);
        const desc = d3d11.D3D11_TEXTURE2D_DESC{
            .Width = surface.width,
            .Height = surface.height,
            .MipLevels = 1,
            .ArraySize = 1,
            .Format = dxgi.DXGI_FORMAT_B8G8R8A8_UNORM,
            .SampleDesc = .{ .Count = 1, .Quality = 0 },
            .Usage = d3d11.D3D11_USAGE_DEFAULT,
            .BindFlags = d3d11.D3D11_BIND_SHADER_RESOURCE,
            .CPUAccessFlags = 0,
            .MiscFlags = 0,
        };
        if (com.failed(self.device.create_texture2d(&desc, null, &surface.state.tex))) return;
        const srv_desc = d3d11.D3D11_SHADER_RESOURCE_VIEW_DESC{
            .Format = dxgi.DXGI_FORMAT_B8G8R8A8_UNORM,
            .ViewDimension = d3d11.D3D11_SRV_DIMENSION_TEXTURE2D,
            .u0 = 0,
            .u1 = 1,
        };
        const hr = self.device.create_srv(surface.state.tex.?, &srv_desc, &surface.state.srv);
        if (com.failed(hr)) {
            com.release(&surface.state.tex);
        }
    }

    fn ensure_nv12_surface(self: *Renderer, surface: *FrameSurface) void {
        if (surface.state.tex != null and surface.state.chroma_tex != null) return;
        std.debug.assert(surface.state.tex == null);
        std.debug.assert(surface.state.chroma_tex == null);
        self.ensure_plane(surface, .luma);
        self.ensure_plane(surface, .chroma);
        if (surface.state.tex == null or surface.state.chroma_tex == null) {
            com.release(&surface.state.chroma_srv);
            com.release(&surface.state.chroma_tex);
            com.release(&surface.state.srv);
            com.release(&surface.state.tex);
        }
    }

    fn ensure_shared_nv12_surface(self: *Renderer, surface: *FrameSurface) void {
        if (surface.state.srv != null and surface.state.chroma_srv != null) return;
        std.debug.assert(surface.state.tex == null);
        std.debug.assert(surface.state.chroma_tex == null);
        self.open_shared_plane(surface, .luma);
        self.open_shared_plane(surface, .chroma);
        if (surface.state.srv == null or surface.state.chroma_srv == null) {
            com.release(&surface.state.chroma_srv);
            com.release(&surface.state.chroma_tex);
            com.release(&surface.state.chroma_mutex);
            com.release(&surface.state.srv);
            com.release(&surface.state.tex);
            com.release(&surface.state.mutex);
        }
    }

    fn ensure_plane(self: *Renderer, surface: *FrameSurface, plane: Plane) void {
        const chroma = plane == .chroma;
        const width = if (chroma) surface.width / 2 else surface.width;
        const height = if (chroma) surface.height / 2 else surface.height;
        const format = if (chroma) dxgi.DXGI_FORMAT_R8G8_UNORM else dxgi.DXGI_FORMAT_R8_UNORM;
        std.debug.assert(width > 0);
        std.debug.assert(height > 0);
        const desc = d3d11.D3D11_TEXTURE2D_DESC{
            .Width = width,
            .Height = height,
            .MipLevels = 1,
            .ArraySize = 1,
            .Format = format,
            .SampleDesc = .{ .Count = 1, .Quality = 0 },
            .Usage = d3d11.D3D11_USAGE_DEFAULT,
            .BindFlags = d3d11.D3D11_BIND_SHADER_RESOURCE,
            .CPUAccessFlags = 0,
            .MiscFlags = 0,
        };
        const tex_slot = if (chroma) &surface.state.chroma_tex else &surface.state.tex;
        const srv_slot = if (chroma) &surface.state.chroma_srv else &surface.state.srv;
        if (com.failed(self.device.create_texture2d(&desc, null, tex_slot))) return;
        const srv_desc = d3d11.D3D11_SHADER_RESOURCE_VIEW_DESC{
            .Format = format,
            .ViewDimension = d3d11.D3D11_SRV_DIMENSION_TEXTURE2D,
            .u0 = 0,
            .u1 = 1,
        };
        const hr = self.device.create_srv(tex_slot.*.?, &srv_desc, srv_slot);
        if (com.failed(hr)) {
            com.release(tex_slot);
        }
    }

    fn open_shared_plane(self: *Renderer, surface: *FrameSurface, plane: Plane) void {
        const chroma = plane == .chroma;
        const handle = if (chroma) surface.shared_chroma else surface.shared_luma;
        const format = if (chroma) dxgi.DXGI_FORMAT_R8G8_UNORM else dxgi.DXGI_FORMAT_R8_UNORM;
        const tex_slot = if (chroma) &surface.state.chroma_tex else &surface.state.tex;
        const srv_slot = if (chroma) &surface.state.chroma_srv else &surface.state.srv;
        const mutex_slot = if (chroma) &surface.state.chroma_mutex else &surface.state.mutex;
        std.debug.assert(handle != null);
        if (com.failed(self.device.open_shared_resource(
            handle.?,
            &dxgi.IID_ID3D11Texture2D,
            tex_slot,
        ))) return;
        if (!valid_shared_plane_desc(tex_slot.*.?, surface, plane)) {
            com.release(tex_slot);
            return;
        }
        if (com.failed(query_keyed_mutex(tex_slot.*.?, mutex_slot))) {
            com.release(tex_slot);
            return;
        }
        const srv_desc = d3d11.D3D11_SHADER_RESOURCE_VIEW_DESC{
            .Format = format,
            .ViewDimension = d3d11.D3D11_SRV_DIMENSION_TEXTURE2D,
            .u0 = 0,
            .u1 = 1,
        };
        if (com.failed(self.device.create_srv(tex_slot.*.?, &srv_desc, srv_slot))) {
            com.release(mutex_slot);
            com.release(tex_slot);
        }
    }

    fn create_shared_plane(
        self: *Renderer,
        width: u32,
        height: u32,
        plane: Plane,
        surface: *FrameSurface,
    ) bool {
        std.debug.assert(width > 0);
        std.debug.assert(height > 0);
        const chroma = plane == .chroma;
        const format = if (chroma) dxgi.DXGI_FORMAT_R8G8_UNORM else dxgi.DXGI_FORMAT_R8_UNORM;
        const tex_slot = if (chroma) &surface.state.owner_chroma_tex else &surface.state.owner_tex;
        const mutex_slot = if (chroma)
            &surface.state.owner_chroma_mutex
        else
            &surface.state.owner_mutex;
        const handle_slot = if (chroma) &surface.shared_chroma else &surface.shared_luma;
        const desc = d3d11.D3D11_TEXTURE2D_DESC{
            .Width = width,
            .Height = height,
            .MipLevels = 1,
            .ArraySize = 1,
            .Format = format,
            .SampleDesc = .{ .Count = 1, .Quality = 0 },
            .Usage = d3d11.D3D11_USAGE_DEFAULT,
            .BindFlags = d3d11.D3D11_BIND_SHADER_RESOURCE,
            .CPUAccessFlags = 0,
            .MiscFlags = d3d11.D3D11_RESOURCE_MISC_SHARED_KEYEDMUTEX,
        };
        if (com.failed(self.device.create_texture2d(&desc, null, tex_slot))) return false;
        if (com.failed(query_keyed_mutex(tex_slot.*.?, mutex_slot))) {
            com.release(tex_slot);
            return false;
        }
        handle_slot.* = shared_handle(tex_slot.*.?) orelse {
            com.release(mutex_slot);
            com.release(tex_slot);
            return false;
        };
        return true;
    }

    fn valid_shared_plane_desc(tex: *anyopaque, surface: *FrameSurface, plane: Plane) bool {
        const chroma = plane == .chroma;
        const want_w = if (chroma) surface.width / 2 else surface.width;
        const want_h = if (chroma) surface.height / 2 else surface.height;
        const want_format = if (chroma) dxgi.DXGI_FORMAT_R8G8_UNORM else dxgi.DXGI_FORMAT_R8_UNORM;
        var desc: d3d11.D3D11_TEXTURE2D_DESC = undefined;
        const t: *d3d11.ID3D11Texture2D = @ptrCast(@alignCast(tex));
        t.get_desc(&desc);
        if (desc.Width != want_w or desc.Height != want_h) return false;
        if (desc.MipLevels != 1 or desc.ArraySize != 1) return false;
        if (desc.Format != want_format) return false;
        if (desc.SampleDesc.Count != 1) return false;
        if (desc.BindFlags & d3d11.D3D11_BIND_SHADER_RESOURCE == 0) return false;
        if (desc.MiscFlags & d3d11.D3D11_RESOURCE_MISC_SHARED_KEYEDMUTEX == 0) return false;
        return true;
    }

    // True when the device exposes ID3D11Device1 (Windows 8+): the prerequisite for
    // opening an NT-handle shared frame (create_imported_nv12_surface with .handle).
    // The same-device .texture path needs no such probe. False -> use CPU staging.
    pub fn imported_nv12_handle_supported(self: *const Renderer) bool {
        return self.device1 != null;
    }

    // What a producer hands out for a decoded NV12 frame. Exactly one source is
    // set: `handle` is a cross-process NT handle from CreateSharedHandle (consumed
    // by create_imported_nv12_surface); `texture` is a same-device ID3D11Texture2D
    // bound with no handle round-trip. array_slice picks a decoder-array slot; the
    // keys drive the keyed mutex when the producer exports one.
    pub const ImportedNv12Desc = struct {
        handle: ?win32.HANDLE = null,
        texture: ?*anyopaque = null,
        width: u32,
        height: u32,
        array_slice: u32 = 0,
        acquire_key: u64 = 0,
        release_key: u64 = 0,
    };

    // Wraps a producer's NV12 frame as a sampled surface: a shader-readable single
    // texture is sampled directly (zero copy), a decoder-only array is copied
    // GPU->GPU into a sampleable texture. desc.handle is ALWAYS consumed - closed
    // on success and on failure - so the caller dups it first if it still needs it
    // and never closes it afterward (the dmabuf-fd contract).
    pub fn create_imported_nv12_surface(self: *Renderer, desc: ImportedNv12Desc) ?FrameSurface {
        std.debug.assert(desc.width > 0);
        std.debug.assert(desc.height > 0);
        std.debug.assert(desc.width % 2 == 0);
        std.debug.assert(desc.height % 2 == 0);
        std.debug.assert(desc.width <= MAX_FRAME_DIM);
        std.debug.assert(desc.height <= MAX_FRAME_DIM);
        std.debug.assert((desc.handle == null) != (desc.texture == null));

        var from_handle = false;
        const source = self.resolve_imported_source(desc, &from_handle) orelse return null;

        var out = FrameSurface.init_imported_nv12(
            desc.width,
            desc.height,
            desc.acquire_key,
            desc.release_key,
        );
        // The setup stores every owned ref (the opened source, the copy target,
        // an add-ref'd borrowed source) onto the surface, so out.deinit frees them
        // on its own failure too - there is no separate cleanup path to forget.
        const ok = if (imported_is_sampleable(source, desc))
            self.setup_imported_direct(&out, source, from_handle)
        else
            self.setup_imported_copy(&out, source, from_handle, desc.array_slice);
        if (!ok) {
            out.deinit();
            return null;
        }
        return out;
    }

    // Resolves the producer's NV12 texture and ALWAYS consumes desc.handle: an NT
    // handle is closed right after the open takes its own reference, and also on
    // failure. The close happens here once, so no later branch must remember to.
    // The returned texture is an owned ref only when from_handle is set.
    fn resolve_imported_source(
        self: *Renderer,
        desc: ImportedNv12Desc,
        from_handle: *bool,
    ) ?*anyopaque {
        if (desc.handle) |handle| {
            from_handle.* = true;
            const dev1 = self.device1 orelse {
                _ = win32.CloseHandle(handle);
                return null;
            };
            var out: ?*anyopaque = null;
            const hr = dev1.open_shared_resource1(handle, &dxgi.IID_ID3D11Texture2D, &out);
            _ = win32.CloseHandle(handle);
            if (com.failed(hr)) return null;
            std.debug.assert(out != null);
            return out;
        }
        from_handle.* = false;
        std.debug.assert(desc.texture != null);
        return desc.texture.?;
    }

    // A producer texture is sampled directly only when it is shader-readable, a
    // single (non-array) NV12 surface, with no array slice requested. Anything else
    // (a BIND_DECODER array) is routed to the GPU-side copy tier.
    fn imported_is_sampleable(source: *anyopaque, desc: ImportedNv12Desc) bool {
        var d: d3d11.D3D11_TEXTURE2D_DESC = undefined;
        const tex: *d3d11.ID3D11Texture2D = @ptrCast(@alignCast(source));
        tex.get_desc(&d);
        std.debug.assert(d.Format == dxgi.DXGI_FORMAT_NV12);
        std.debug.assert(d.Width == desc.width);
        std.debug.assert(d.Height == desc.height);
        std.debug.assert(desc.array_slice < d.ArraySize);
        if (d.BindFlags & d3d11.D3D11_BIND_SHADER_RESOURCE == 0) return false;
        if (d.ArraySize != 1) return false;
        if (desc.array_slice != 0) return false;
        return true;
    }

    // Direct tiers (same-device texture or opened NT handle): two plane SRVs on the
    // producer texture, no copy. An owned (handle-opened) source is parked in `tex`
    // so deinit frees it; a borrowed texture is kept alive by the SRVs alone.
    fn setup_imported_direct(
        self: *Renderer,
        surface: *FrameSurface,
        source: *anyopaque,
        from_handle: bool,
    ) bool {
        std.debug.assert(surface.format == .imported_nv12);
        std.debug.assert(surface.state.tex == null);
        if (from_handle) surface.state.tex = source;
        if (!self.create_plane_srv(source, .luma, &surface.state.srv)) return false;
        if (!self.create_plane_srv(source, .chroma, &surface.state.chroma_srv)) return false;
        // A pool of same-device textures may carry no keyed mutex; the import then
        // samples without acquiring and relies on the caller's availability gating.
        _ = query_keyed_mutex(source, &surface.state.mutex);
        return true;
    }

    // Copy tier (decoder-only or array source): a sampleable NV12 target we own,
    // filled by CopySubresourceRegion each import. The source is parked in copy_src
    // (with an added ref for a borrowed texture) so deinit frees it on failure too.
    fn setup_imported_copy(
        self: *Renderer,
        surface: *FrameSurface,
        source: *anyopaque,
        from_handle: bool,
        array_slice: u32,
    ) bool {
        std.debug.assert(surface.format == .imported_nv12);
        std.debug.assert(surface.state.copy_src == null);
        if (!from_handle) com.add_ref(source);
        surface.state.copy_src = source;
        surface.state.copy_slice = array_slice;
        if (!self.create_copy_target(surface)) return false;
        _ = query_keyed_mutex(source, &surface.state.mutex);
        return true;
    }

    // The copy tier's own sampleable NV12 texture plus its two plane SRVs. Cleans
    // up its partial allocations on failure; copy_src is owned by the caller path.
    fn create_copy_target(self: *Renderer, surface: *FrameSurface) bool {
        std.debug.assert(surface.state.tex == null);
        std.debug.assert(surface.width % 2 == 0);
        const desc = d3d11.D3D11_TEXTURE2D_DESC{
            .Width = surface.width,
            .Height = surface.height,
            .MipLevels = 1,
            .ArraySize = 1,
            .Format = dxgi.DXGI_FORMAT_NV12,
            .SampleDesc = .{ .Count = 1, .Quality = 0 },
            .Usage = d3d11.D3D11_USAGE_DEFAULT,
            .BindFlags = d3d11.D3D11_BIND_SHADER_RESOURCE,
            .CPUAccessFlags = 0,
            .MiscFlags = 0,
        };
        if (com.failed(self.device.create_texture2d(&desc, null, &surface.state.tex)))
            return false;
        if (!self.create_plane_srv(surface.state.tex.?, .luma, &surface.state.srv)) {
            com.release(&surface.state.tex);
            return false;
        }
        if (!self.create_plane_srv(surface.state.tex.?, .chroma, &surface.state.chroma_srv)) {
            com.release(&surface.state.srv);
            com.release(&surface.state.tex);
            return false;
        }
        return true;
    }

    // One NV12 plane SRV. The SRV format selects the plane: R8 is the luma plane,
    // R8G8 the half-size chroma plane (D3D11 NV12 has no plane-slice field).
    fn create_plane_srv(self: *Renderer, tex: *anyopaque, plane: Plane, out: *?*anyopaque) bool {
        std.debug.assert(out.* == null);
        const format = if (plane == .chroma)
            dxgi.DXGI_FORMAT_R8G8_UNORM
        else
            dxgi.DXGI_FORMAT_R8_UNORM;
        const srv_desc = d3d11.D3D11_SHADER_RESOURCE_VIEW_DESC{
            .Format = format,
            .ViewDimension = d3d11.D3D11_SRV_DIMENSION_TEXTURE2D,
            .u0 = 0,
            .u1 = 1,
        };
        const ok = com.succeeded(self.device.create_srv(tex, &srv_desc, out));
        std.debug.assert(!ok or out.* != null);
        return ok;
    }

    fn import_imported_nv12_surface(self: *Renderer, surface: *FrameSurface) ?Nv12Textures {
        std.debug.assert(surface.format == .imported_nv12);
        std.debug.assert(surface.width % 2 == 0);
        const luma = surface.state.srv orelse return null;
        const chroma = surface.state.chroma_srv orelse return null;
        if (surface.state.copy_src) |src| {
            if (!self.copy_imported_frame(surface, src)) return null;
        } else if (!acquire_imported_direct(surface)) {
            return null;
        }
        const old = surface.state.refs.fetchAdd(1, .acq_rel);
        std.debug.assert(old >= 1);
        return .{
            .luma = luma,
            .chroma = chroma,
            .cv_luma = @ptrCast(surface),
            .cv_chroma = null,
            .width = surface.width,
            .height = surface.height,
        };
    }

    // Direct tiers sample the producer texture across the GPU in-flight window, so
    // the keyed mutex (when present) is held until the ring releases it. With no
    // keyed mutex the surface relies on the caller's pool availability gating.
    fn acquire_imported_direct(surface: *FrameSurface) bool {
        std.debug.assert(surface.format == .imported_nv12);
        const mutex = surface.state.mutex orelse return true;
        std.debug.assert(!surface.state.shared_acquired);
        // AcquireSync returns WAIT_TIMEOUT (a non-negative HRESULT) when the key is
        // contended, so only S_OK means the key is actually held.
        if (mutex.acquire_sync(surface.shared_acquire_key, 0) != com.S_OK) return false;
        surface.state.shared_acquired = true;
        return true;
    }

    // Copy tier samples our own texture, so it holds the producer's keyed mutex
    // only across the GPU->GPU copy (released here, not across the ring). The keyed
    // mutex orders the copy before the producer's next write; with none, same-device
    // command order plus the caller's pool keep the source stable during the copy.
    fn copy_imported_frame(self: *Renderer, surface: *FrameSurface, src: *anyopaque) bool {
        std.debug.assert(surface.format == .imported_nv12);
        std.debug.assert(surface.width > 0);
        const dst = surface.state.tex orelse return false;
        // Only S_OK holds the key; WAIT_TIMEOUT (a non-negative HRESULT) does not.
        if (surface.state.mutex) |mutex| {
            if (mutex.acquire_sync(surface.shared_acquire_key, 0) != com.S_OK) return false;
        }
        self.context.copy_subresource_region(dst, 0, 0, 0, 0, src, surface.state.copy_slice, null);
        if (surface.state.mutex) |mutex| _ = mutex.release_sync(surface.shared_release_key);
        return true;
    }

    pub fn request_redraw(self: *Renderer) void {
        self.dirty = true;
    }

    fn ensure_rtv(self: *Renderer) Error!void {
        var backbuffer: ?*anyopaque = null;
        if (com.failed(self.swapchain.get_buffer(0, &dxgi.IID_ID3D11Texture2D, &backbuffer))) {
            return error.SwapchainBufferFailed;
        }
        defer com.release(&backbuffer);
        var rtv: ?*anyopaque = null;
        if (com.failed(self.device.create_rtv(backbuffer.?, &rtv)))
            return error.SwapchainBufferFailed;
        self.rtv = rtv;
    }

    fn resize(self: *Renderer, w: u32, h: u32) void {
        com.release(&self.rtv);
        if (com.failed(self.swapchain.resize_buffers(0, w, h, dxgi.DXGI_FORMAT_UNKNOWN, 0))) {
            std.log.warn("d3d11: resize_buffers failed ({d}x{d})", .{ w, h });
        }
        // A null RTV after this turns draw_frame into a no-op; surface why instead
        // of swallowing it into silent dead frames.
        self.ensure_rtv() catch |err|
            std.log.warn("d3d11: RTV rebuild failed: {s}", .{@errorName(err)});
        self.last_w = w;
        self.last_h = h;
    }

    fn scale_factor(self: *Renderer) f32 {
        const dpi = win32.GetDpiForWindow(self.hwnd);
        if (dpi == 0) return 1.0;
        return @as(f32, @floatFromInt(dpi)) / win32.USER_DEFAULT_SCREEN_DPI;
    }

    // prims/sprites before the split are the backdrop (blurred); the rest draw
    // crisp on top. crisp_top points stay unblurred so the title bar never frosts.
    const Modal = struct {
        split_prims: usize,
        split_sprites: usize,
        split_color: usize,
        crisp_top: f32,
    };

    pub fn draw_frame(
        self: *Renderer,
        clear: ClearColor,
        prims: []const Primitive,
        sprites: []const MonochromeSprite,
        mono_atlas: ?*anyopaque,
        color_sprites: []const PolychromeSprite,
        color_atlas: ?*anyopaque,
    ) void {
        self.draw_frame_impl(clear, prims, sprites, mono_atlas, color_sprites, color_atlas, null);
    }

    pub fn draw_frame_modal(
        self: *Renderer,
        clear: ClearColor,
        prims: []const Primitive,
        sprites: []const MonochromeSprite,
        mono_atlas: ?*anyopaque,
        color_sprites: []const PolychromeSprite,
        color_atlas: ?*anyopaque,
        split_prims: usize,
        split_sprites: usize,
        split_color: usize,
        crisp_top: f32,
    ) void {
        self.draw_frame_impl(clear, prims, sprites, mono_atlas, color_sprites, color_atlas, .{
            .split_prims = split_prims,
            .split_sprites = split_sprites,
            .split_color = split_color,
            .crisp_top = crisp_top,
        });
    }

    // No frost machinery on this backend (the frosted bars are iOS/Metal-only); render
    // the frame as usual so the shared paint seam stays uniform across renderers.
    pub fn draw_frame_frost(
        self: *Renderer,
        clear: ClearColor,
        prims: []const Primitive,
        sprites: []const MonochromeSprite,
        mono_atlas: ?*anyopaque,
        color_sprites: []const PolychromeSprite,
        color_atlas: ?*anyopaque,
        split_prims: usize,
        split_sprites: usize,
        split_color: usize,
        frosts: []const [6]f32,
    ) void {
        _ = .{ split_prims, split_sprites, split_color, frosts };
        self.draw_frame(clear, prims, sprites, mono_atlas, color_sprites, color_atlas);
    }

    fn draw_frame_impl(
        self: *Renderer,
        clear: ClearColor,
        prims: []const Primitive,
        sprites: []const MonochromeSprite,
        mono_atlas: ?*anyopaque,
        color_sprites: []const PolychromeSprite,
        color_atlas: ?*anyopaque,
        modal: ?Modal,
    ) void {
        var rect: win32.RECT = undefined;
        _ = win32.GetClientRect(self.hwnd, &rect);
        const w: u32 = @intCast(@max(rect.right - rect.left, 1));
        const h: u32 = @intCast(@max(rect.bottom - rect.top, 1));
        if (w != self.last_w or h != self.last_h) {
            self.resize(w, h);
            self.dirty = true;
        }
        if (!self.dirty) return;
        const rtv = self.rtv orelse return;

        const scale = self.scale_factor();
        const w_pt = @as(f32, @floatFromInt(w)) / scale;
        const h_pt = @as(f32, @floatFromInt(h)) / scale;
        self.update_viewport(w_pt, h_pt);

        const viewport = d3d11.D3D11_VIEWPORT{
            .TopLeftX = 0,
            .TopLeftY = 0,
            .Width = @floatFromInt(w),
            .Height = @floatFromInt(h),
            .MinDepth = 0,
            .MaxDepth = 1,
        };
        var viewports = [_]d3d11.D3D11_VIEWPORT{viewport};
        self.context.rs_set_viewports(1, &viewports);

        self.context.om_set_blend_state(self.blend_state, null, 0xFFFFFFFF);
        self.context.ia_set_primitive_topology(d3d11.D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
        var cbs = [_]?*anyopaque{self.viewport_cb};
        self.context.vs_set_constant_buffers(0, 1, &cbs);
        var samplers = [_]?*anyopaque{self.sampler_state};
        self.context.ps_set_samplers(0, 1, &samplers);

        const drew_modal = if (modal) |m| self.draw_modal(
            clear,
            prims,
            sprites,
            mono_atlas,
            color_sprites,
            color_atlas,
            m,
            w,
            h,
            scale,
            rtv,
        ) else false;

        if (!drew_modal) {
            self.context.rs_set_state(self.raster_state);
            var rtvs = [_]?*anyopaque{rtv};
            self.context.om_set_render_targets(1, &rtvs, null);
            self.context.clear_render_target_view(rtv, &clear.rgba);
            self.encode_scene(prims, sprites, mono_atlas, color_sprites, color_atlas);
        }

        _ = self.swapchain.present(0, 0);
        self.dirty = false;
    }

    // Render backdrop -> offscreen, separable-blur it, composite onto the
    // backbuffer, re-blit the crisp top strip, then draw the modal crisp on top.
    // Returns false (caller falls back to a plain crisp frame) if the offscreen
    // targets could not be set up.
    fn draw_modal(
        self: *Renderer,
        clear: ClearColor,
        prims: []const Primitive,
        sprites: []const MonochromeSprite,
        mono_atlas: ?*anyopaque,
        color_sprites: []const PolychromeSprite,
        color_atlas: ?*anyopaque,
        m: Modal,
        w: u32,
        h: u32,
        scale: f32,
        rtv: *anyopaque,
    ) bool {
        if (m.split_prims > prims.len or m.split_sprites > sprites.len or
            m.split_color > color_sprites.len) return false;
        if (self.blit_pipeline.vs == null) return false;
        self.ensure_offscreen(w, h);
        const scene_rtv = self.scene_target.rtv orelse return false;
        const scene_srv = self.scene_target.srv orelse return false;
        const aux_rtv = self.blur_target.rtv orelse return false;
        const aux_srv = self.blur_target.srv orelse return false;

        var null_srv = [_]?*anyopaque{null};
        // D3D11 errors if a subresource is bound as SRV and RTV at once; unbind first.
        self.context.ps_set_shader_resources(0, 1, &null_srv);

        // Pass A: backdrop into the scene target.
        self.context.rs_set_state(self.raster_state);
        var a_rtvs = [_]?*anyopaque{scene_rtv};
        self.context.om_set_render_targets(1, &a_rtvs, null);
        self.context.clear_render_target_view(scene_rtv, &clear.rgba);
        self.encode_scene(
            prims[0..m.split_prims],
            sprites[0..m.split_sprites],
            mono_atlas,
            color_sprites[0..m.split_color],
            color_atlas,
        );

        self.update_blur(w, h, BLUR_SIGMA_PT * scale);
        var blur_cbs = [_]?*anyopaque{self.blur_cb};
        self.context.ps_set_constant_buffers(1, 1, &blur_cbs);

        // Pass H: horizontal blur scene -> aux.
        var h_rtvs = [_]?*anyopaque{aux_rtv};
        self.context.om_set_render_targets(1, &h_rtvs, null);
        self.fullscreen_pass(self.blur_h_pipeline, scene_srv);

        // Backbuffer: clear, then vertical blur aux -> backbuffer (full).
        var b_rtvs = [_]?*anyopaque{rtv};
        self.context.om_set_render_targets(1, &b_rtvs, null);
        self.context.clear_render_target_view(rtv, &clear.rgba);
        self.fullscreen_pass(self.blur_v_pipeline, aux_srv);

        // Crisp title-bar strip: re-blit the unblurred backdrop over the top band.
        const top_px = m.crisp_top * scale;
        if (top_px >= 1) {
            self.context.rs_set_state(self.raster_state_scissor);
            const strip = win32.RECT{
                .left = 0,
                .top = 0,
                .right = @intCast(w),
                .bottom = @intFromFloat(@min(top_px, @as(f32, @floatFromInt(h)))),
            };
            var rects = [_]win32.RECT{strip};
            self.context.rs_set_scissor_rects(1, &rects);
            self.fullscreen_pass(self.blit_pipeline, scene_srv);
            self.context.rs_set_state(self.raster_state);
        }

        // Crisp modal content on top.
        self.context.ps_set_shader_resources(0, 1, &null_srv);
        self.encode_scene(
            prims[m.split_prims..],
            sprites[m.split_sprites..],
            mono_atlas,
            color_sprites[m.split_color..],
            color_atlas,
        );
        return true;
    }

    fn fullscreen_pass(self: *Renderer, pipeline: Pipeline, src_srv: ?*anyopaque) void {
        self.context.vs_set_shader(pipeline.vs);
        self.context.ps_set_shader(pipeline.ps);
        var srvs = [_]?*anyopaque{src_srv};
        self.context.ps_set_shader_resources(0, 1, &srvs);
        self.context.draw_instanced(6, 1, 0, 0);
    }

    fn update_blur(self: *Renderer, w: u32, h: u32, sigma_px: f32) void {
        const cb = self.blur_cb orelse return;
        var mapped: d3d11.D3D11_MAPPED_SUBRESOURCE = undefined;
        if (com.failed(self.context.map(cb, 0, d3d11.D3D11_MAP_WRITE_DISCARD, &mapped))) return;
        const dst: [*]f32 = @ptrCast(@alignCast(mapped.pData.?));
        dst[0] = 1.0 / @as(f32, @floatFromInt(w));
        dst[1] = 1.0 / @as(f32, @floatFromInt(h));
        dst[2] = @max(sigma_px, 0.5);
        dst[3] = 0;
        self.context.unmap(cb, 0);
    }

    fn ensure_offscreen(self: *Renderer, w: u32, h: u32) void {
        if (w == 0 or h == 0) return;
        if (self.scene_target.tex != null and self.offscreen_w == w and self.offscreen_h == h)
            return;
        self.scene_target.release();
        self.blur_target.release();
        self.offscreen_w = 0;
        self.offscreen_h = 0;
        self.scene_target = self.make_offscreen(w, h) orelse return;
        self.blur_target = self.make_offscreen(w, h) orelse {
            self.scene_target.release();
            self.scene_target = .{};
            return;
        };
        self.offscreen_w = w;
        self.offscreen_h = h;
    }

    fn make_offscreen(self: *Renderer, w: u32, h: u32) ?Offscreen {
        const desc = d3d11.D3D11_TEXTURE2D_DESC{
            .Width = w,
            .Height = h,
            .MipLevels = 1,
            .ArraySize = 1,
            .Format = dxgi.DXGI_FORMAT_B8G8R8A8_UNORM,
            .SampleDesc = .{ .Count = 1, .Quality = 0 },
            .Usage = d3d11.D3D11_USAGE_DEFAULT,
            .BindFlags = d3d11.D3D11_BIND_RENDER_TARGET | d3d11.D3D11_BIND_SHADER_RESOURCE,
            .CPUAccessFlags = 0,
            .MiscFlags = 0,
        };
        var tex: ?*anyopaque = null;
        if (com.failed(self.device.create_texture2d(&desc, null, &tex))) return null;
        var ot = Offscreen{ .tex = tex };
        var rtv: ?*anyopaque = null;
        if (com.failed(self.device.create_rtv(tex.?, &rtv))) {
            ot.release();
            return null;
        }
        ot.rtv = rtv;
        const srv_desc = d3d11.D3D11_SHADER_RESOURCE_VIEW_DESC{
            .Format = dxgi.DXGI_FORMAT_B8G8R8A8_UNORM,
            .ViewDimension = d3d11.D3D11_SRV_DIMENSION_TEXTURE2D,
            .u0 = 0,
            .u1 = 1,
        };
        var srv: ?*anyopaque = null;
        if (com.failed(self.device.create_srv(tex.?, &srv_desc, &srv))) {
            ot.release();
            return null;
        }
        ot.srv = srv;
        return ot;
    }

    fn encode_scene(
        self: *Renderer,
        prims: []const Primitive,
        sprites: []const MonochromeSprite,
        mono_atlas: ?*anyopaque,
        color_sprites: []const PolychromeSprite,
        color_atlas: ?*anyopaque,
    ) void {
        var i: usize = 0;
        while (i < prims.len) {
            const start = i;
            const tag = std.meta.activeTag(prims[i]);
            while (i < prims.len and std.meta.activeTag(prims[i]) == tag) i += 1;
            const batch = prims[start..i];
            switch (tag) {
                .quad => self.encode_prim_batch(
                    Quad,
                    "quad",
                    &self.quad_buffer,
                    self.quad_pipeline,
                    batch,
                ),
                .polyline => self.encode_prim_batch(
                    Polyline,
                    "polyline",
                    &self.polyline_buffer,
                    self.polyline_pipeline,
                    batch,
                ),
                .line_segment => self.encode_prim_batch(
                    LineSegment,
                    "line_segment",
                    &self.line_buffer,
                    self.line_pipeline,
                    batch,
                ),
                .ring_chart => self.encode_prim_batch(
                    RingChart,
                    "ring_chart",
                    &self.ring_buffer,
                    self.ring_pipeline,
                    batch,
                ),
                .frame => self.encode_frame_batch(batch),
            }
        }
        if (sprites.len > 0) {
            if (mono_atlas) |atlas| self.encode_sprites(
                MonochromeSprite,
                &self.sprite_buffer,
                self.text_pipeline,
                sprites,
                atlas,
            );
        }
        if (color_sprites.len > 0) {
            if (color_atlas) |atlas| self.encode_sprites(
                PolychromeSprite,
                &self.color_sprite_buffer,
                self.color_sprite_pipeline,
                color_sprites,
                atlas,
            );
        }
    }

    fn encode_frame_batch(self: *Renderer, batch: []const Primitive) void {
        const cb = self.frame_cb orelse return;
        if (batch.len > MAX_FRAMES) return;
        var null_srv = [_]?*anyopaque{null};
        var frame_cbs = [_]?*anyopaque{cb};
        self.context.vs_set_constant_buffers(1, 1, &frame_cbs);
        self.context.ps_set_constant_buffers(1, 1, &frame_cbs);
        for (batch) |prim| {
            const f = prim.frame;
            const nv12 = f.tex_cbcr != null;
            const pipeline = if (nv12) self.frame_nv12_pipeline else self.frame_pipeline;
            const vs = pipeline.vs orelse continue;
            const ps = pipeline.ps orelse continue;
            const srv = f.tex orelse continue;
            if (!self.update_frame_cb(cb, f)) continue;
            self.context.vs_set_shader(vs);
            self.context.ps_set_shader(ps);
            var srvs = [_]?*anyopaque{srv};
            self.context.ps_set_shader_resources(0, 1, &srvs);
            if (f.tex_cbcr) |chroma| {
                var chroma_srvs = [_]?*anyopaque{chroma};
                self.context.ps_set_shader_resources(1, 1, &chroma_srvs);
            }
            self.context.draw_instanced(6, 1, 0, 0);
            self.context.ps_set_shader_resources(0, 1, &null_srv);
            self.context.ps_set_shader_resources(1, 1, &null_srv);
        }
    }

    fn update_frame_cb(self: *Renderer, cb: *anyopaque, f: primitives.Frame) bool {
        var mapped: d3d11.D3D11_MAPPED_SUBRESOURCE = undefined;
        if (com.failed(self.context.map(cb, 0, d3d11.D3D11_MAP_WRITE_DISCARD, &mapped)))
            return false;
        const ptr = mapped.pData orelse {
            self.context.unmap(cb, 0);
            return false;
        };
        const dst: *FrameGpu = @ptrCast(@alignCast(ptr));
        dst.* = .{
            .bounds = f.bounds,
            .clip_bounds = f.clip_bounds,
            .opacity = f.opacity,
            // BGRA ignores this; NV12 reads the same uniform layout.
            .csc = f.csc,
        };
        self.context.unmap(cb, 0);
        return true;
    }

    fn encode_prim_batch(
        self: *Renderer,
        comptime T: type,
        comptime field: []const u8,
        ib: *InstanceBuffer,
        pipeline: Pipeline,
        batch: []const Primitive,
    ) void {
        // The MAX_* caps are a soft budget, not a caller contract. A batch over the
        // cap is skipped whole for this frame (no clamp), so a dense scene loses
        // that primitive class - same trade-off as the macOS batch encoders.
        if (batch.len == 0 or batch.len > ib.capacity) return;
        const buffer = ib.buffer orelse return;

        var mapped: d3d11.D3D11_MAPPED_SUBRESOURCE = undefined;
        if (com.failed(self.context.map(buffer, 0, d3d11.D3D11_MAP_WRITE_DISCARD, &mapped)))
            return;
        const dst: [*]T = @ptrCast(@alignCast(mapped.pData.?));
        for (batch, 0..) |prim, idx| dst[idx] = @field(prim, field);
        self.context.unmap(buffer, 0);

        self.bind_and_draw(ib, pipeline, @intCast(batch.len), null);
    }

    fn encode_sprites(
        self: *Renderer,
        comptime T: type,
        ib: *InstanceBuffer,
        pipeline: Pipeline,
        sprites: []const T,
        atlas: *anyopaque,
    ) void {
        if (sprites.len == 0 or sprites.len > ib.capacity) return;
        const buffer = ib.buffer orelse return;

        var mapped: d3d11.D3D11_MAPPED_SUBRESOURCE = undefined;
        if (com.failed(self.context.map(buffer, 0, d3d11.D3D11_MAP_WRITE_DISCARD, &mapped)))
            return;
        const dst: [*]T = @ptrCast(@alignCast(mapped.pData.?));
        @memcpy(dst[0..sprites.len], sprites);
        self.context.unmap(buffer, 0);

        self.bind_and_draw(ib, pipeline, @intCast(sprites.len), atlas);
    }

    fn bind_and_draw(
        self: *Renderer,
        ib: *InstanceBuffer,
        pipeline: Pipeline,
        count: u32,
        atlas: ?*anyopaque,
    ) void {
        self.context.vs_set_shader(pipeline.vs);
        self.context.ps_set_shader(pipeline.ps);
        var srvs = [_]?*anyopaque{ib.srv};
        self.context.vs_set_shader_resources(0, 1, &srvs);
        if (atlas) |a| {
            var tex = [_]?*anyopaque{a};
            self.context.ps_set_shader_resources(0, 1, &tex);
        }
        self.context.draw_instanced(6, count, 0, 0);
    }

    fn update_viewport(self: *Renderer, w_pt: f32, h_pt: f32) void {
        const cb = self.viewport_cb orelse return;
        var mapped: d3d11.D3D11_MAPPED_SUBRESOURCE = undefined;
        if (com.failed(self.context.map(cb, 0, d3d11.D3D11_MAP_WRITE_DISCARD, &mapped))) return;
        const dst: [*]f32 = @ptrCast(@alignCast(mapped.pData.?));
        dst[0] = w_pt;
        dst[1] = h_pt;
        dst[2] = 0;
        dst[3] = 0;
        self.context.unmap(cb, 0);
    }

    fn build_pipelines(self: *Renderer) Error!void {
        const module = win32.LoadLibraryA("d3dcompiler_47.dll") orelse
            return error.ShaderCompilerMissing;
        const proc = win32.GetProcAddress(module, "D3DCompile") orelse
            return error.ShaderCompilerMissing;
        const compile: d3d11.PFN_D3DCompile = @ptrCast(proc);

        self.quad_pipeline = try self.make_pipeline(compile, "quad_vertex", "quad_fragment");
        self.text_pipeline = try self.make_pipeline(compile, "text_vertex", "text_fragment");
        self.color_sprite_pipeline = try self.make_pipeline(
            compile,
            "color_sprite_vertex",
            "color_sprite_fragment",
        );
        self.polyline_pipeline = try self.make_pipeline(
            compile,
            "polyline_vertex",
            "polyline_fragment",
        );
        self.line_pipeline = try self.make_pipeline(
            compile,
            "line_segment_vertex",
            "line_segment_fragment",
        );
        self.ring_pipeline = try self.make_pipeline(
            compile,
            "ring_chart_vertex",
            "ring_chart_fragment",
        );
        self.frame_pipeline = try self.make_pipeline(compile, "frame_vertex", "frame_fragment");
        self.frame_nv12_pipeline = try self.make_pipeline(
            compile,
            "frame_vertex",
            "frame_nv12_fragment",
        );
        self.blit_pipeline = try self.make_pipeline(compile, "blit_vertex", "blit_fragment");
        self.blur_h_pipeline = try self.make_pipeline(compile, "blit_vertex", "blur_h_fragment");
        self.blur_v_pipeline = try self.make_pipeline(compile, "blit_vertex", "blur_v_fragment");
    }

    fn make_pipeline(
        self: *Renderer,
        compile: d3d11.PFN_D3DCompile,
        vs_entry: [*:0]const u8,
        ps_entry: [*:0]const u8,
    ) Error!Pipeline {
        const source = @embedFile("shaders.hlsl");
        var pipeline = Pipeline{};

        var vs_blob = try compile_blob(compile, source, vs_entry, "vs_5_0");
        defer vs_blob.release();
        var vs: ?*anyopaque = null;
        if (com.failed(self.device.create_vertex_shader(
            vs_blob.buffer_pointer(),
            vs_blob.buffer_size(),
            &vs,
        ))) {
            return error.PipelineCreateFailed;
        }
        pipeline.vs = vs;

        var ps_blob = try compile_blob(compile, source, ps_entry, "ps_5_0");
        defer ps_blob.release();
        var ps: ?*anyopaque = null;
        if (com.failed(self.device.create_pixel_shader(
            ps_blob.buffer_pointer(),
            ps_blob.buffer_size(),
            &ps,
        ))) {
            return error.PipelineCreateFailed;
        }
        pipeline.ps = ps;

        return pipeline;
    }

    fn compile_blob(
        compile: d3d11.PFN_D3DCompile,
        source: []const u8,
        entry: [*:0]const u8,
        target: [*:0]const u8,
    ) Error!*d3d11.ID3DBlob {
        var code: ?*d3d11.ID3DBlob = null;
        var errors: ?*d3d11.ID3DBlob = null;
        const hr = compile(
            source.ptr,
            source.len,
            "shaders.hlsl",
            null,
            null,
            entry,
            target,
            0,
            0,
            &code,
            &errors,
        );
        if (errors) |e| {
            const ptr: [*]const u8 = @ptrCast(e.buffer_pointer());
            std.debug.print("HLSL compile ({s}): {s}\n", .{ entry, ptr[0..e.buffer_size()] });
            e.release();
        }
        if (com.failed(hr) or code == null) return error.ShaderCompileFailed;
        return code.?;
    }

    fn build_instance_buffers(self: *Renderer) Error!void {
        self.quad_buffer = try self.make_instance_buffer(@sizeOf(Quad), MAX_QUADS);
        self.sprite_buffer = try self.make_instance_buffer(@sizeOf(MonochromeSprite), MAX_SPRITES);
        self.color_sprite_buffer = try self.make_instance_buffer(
            @sizeOf(PolychromeSprite),
            MAX_COLOR_SPRITES,
        );
        self.polyline_buffer = try self.make_instance_buffer(@sizeOf(Polyline), MAX_POLYLINES);
        self.line_buffer = try self.make_instance_buffer(@sizeOf(LineSegment), MAX_LINES);
        self.ring_buffer = try self.make_instance_buffer(@sizeOf(RingChart), MAX_RINGS);

        // The viewport constant buffer holds [w, h, pad, pad] in points.
        const cb_desc = d3d11.D3D11_BUFFER_DESC{
            .ByteWidth = 16,
            .Usage = d3d11.D3D11_USAGE_DYNAMIC,
            .BindFlags = d3d11.D3D11_BIND_CONSTANT_BUFFER,
            .CPUAccessFlags = d3d11.D3D11_CPU_ACCESS_WRITE,
            .MiscFlags = 0,
            .StructureByteStride = 0,
        };
        var cb: ?*anyopaque = null;
        if (com.failed(self.device.create_buffer(&cb_desc, null, &cb)))
            return error.BufferCreateFailed;
        self.viewport_cb = cb;

        // Blur params: [texel.x, texel.y, sigma, pad].
        var blur_cb: ?*anyopaque = null;
        if (com.failed(self.device.create_buffer(&cb_desc, null, &blur_cb)))
            return error.BufferCreateFailed;
        self.blur_cb = blur_cb;

        const frame_cb_desc = d3d11.D3D11_BUFFER_DESC{
            .ByteWidth = @sizeOf(FrameGpu),
            .Usage = d3d11.D3D11_USAGE_DYNAMIC,
            .BindFlags = d3d11.D3D11_BIND_CONSTANT_BUFFER,
            .CPUAccessFlags = d3d11.D3D11_CPU_ACCESS_WRITE,
            .MiscFlags = 0,
            .StructureByteStride = 0,
        };
        var frame_cb: ?*anyopaque = null;
        if (com.failed(self.device.create_buffer(&frame_cb_desc, null, &frame_cb)))
            return error.BufferCreateFailed;
        self.frame_cb = frame_cb;
    }

    fn make_instance_buffer(self: *Renderer, stride: u32, capacity: u32) Error!InstanceBuffer {
        const desc = d3d11.D3D11_BUFFER_DESC{
            .ByteWidth = stride * capacity,
            .Usage = d3d11.D3D11_USAGE_DYNAMIC,
            .BindFlags = d3d11.D3D11_BIND_SHADER_RESOURCE,
            .CPUAccessFlags = d3d11.D3D11_CPU_ACCESS_WRITE,
            .MiscFlags = d3d11.D3D11_RESOURCE_MISC_BUFFER_STRUCTURED,
            .StructureByteStride = stride,
        };
        var buffer: ?*anyopaque = null;
        if (com.failed(self.device.create_buffer(&desc, null, &buffer)))
            return error.BufferCreateFailed;

        const srv_desc = d3d11.D3D11_SHADER_RESOURCE_VIEW_DESC{
            .Format = dxgi.DXGI_FORMAT_UNKNOWN,
            .ViewDimension = d3d11.D3D11_SRV_DIMENSION_BUFFER,
            .u0 = 0,
            .u1 = capacity,
        };
        var srv: ?*anyopaque = null;
        if (com.failed(self.device.create_srv(buffer.?, &srv_desc, &srv)))
            return error.BufferCreateFailed;

        return .{ .buffer = buffer, .srv = srv, .stride = stride, .capacity = capacity };
    }

    fn build_states(self: *Renderer) Error!void {
        // Straight-alpha "over": Src.rgb*Src.a + Dst.rgb*(1-Src.a). Matches the
        // macOS pipeline blend factors exactly.
        var blend_desc = std.mem.zeroes(d3d11.D3D11_BLEND_DESC);
        blend_desc.RenderTarget[0] = .{
            .BlendEnable = win32.TRUE,
            .SrcBlend = d3d11.D3D11_BLEND_SRC_ALPHA,
            .DestBlend = d3d11.D3D11_BLEND_INV_SRC_ALPHA,
            .BlendOp = d3d11.D3D11_BLEND_OP_ADD,
            .SrcBlendAlpha = d3d11.D3D11_BLEND_ONE,
            .DestBlendAlpha = d3d11.D3D11_BLEND_INV_SRC_ALPHA,
            .BlendOpAlpha = d3d11.D3D11_BLEND_OP_ADD,
            .RenderTargetWriteMask = d3d11.D3D11_COLOR_WRITE_ENABLE_ALL,
        };
        var blend: ?*anyopaque = null;
        if (com.failed(self.device.create_blend_state(&blend_desc, &blend)))
            return error.StateCreateFailed;
        self.blend_state = blend;

        const raster_desc = d3d11.D3D11_RASTERIZER_DESC{
            .FillMode = d3d11.D3D11_FILL_SOLID,
            .CullMode = d3d11.D3D11_CULL_NONE,
            .FrontCounterClockwise = win32.FALSE,
            .DepthBias = 0,
            .DepthBiasClamp = 0,
            .SlopeScaledDepthBias = 0,
            .DepthClipEnable = win32.TRUE,
            .ScissorEnable = win32.FALSE,
            .MultisampleEnable = win32.FALSE,
            .AntialiasedLineEnable = win32.FALSE,
        };
        var raster: ?*anyopaque = null;
        if (com.failed(self.device.create_rasterizer_state(&raster_desc, &raster)))
            return error.StateCreateFailed;
        self.raster_state = raster;

        // Same state with the scissor test on, for the crisp title-bar strip that
        // re-blits the unblurred backdrop over the frosted modal.
        var scissor_desc = raster_desc;
        scissor_desc.ScissorEnable = win32.TRUE;
        var raster_scissor: ?*anyopaque = null;
        if (com.failed(self.device.create_rasterizer_state(&scissor_desc, &raster_scissor)))
            return error.StateCreateFailed;
        self.raster_state_scissor = raster_scissor;

        const sampler_desc = d3d11.D3D11_SAMPLER_DESC{
            .Filter = d3d11.D3D11_FILTER_MIN_MAG_MIP_LINEAR,
            .AddressU = d3d11.D3D11_TEXTURE_ADDRESS_CLAMP,
            .AddressV = d3d11.D3D11_TEXTURE_ADDRESS_CLAMP,
            .AddressW = d3d11.D3D11_TEXTURE_ADDRESS_CLAMP,
            .MipLODBias = 0,
            .MaxAnisotropy = 1,
            .ComparisonFunc = d3d11.D3D11_COMPARISON_NEVER,
            .BorderColor = .{ 0, 0, 0, 0 },
            .MinLOD = 0,
            .MaxLOD = 0,
        };
        var sampler: ?*anyopaque = null;
        if (com.failed(self.device.create_sampler_state(&sampler_desc, &sampler)))
            return error.StateCreateFailed;
        self.sampler_state = sampler;
    }
};

// Proves imported_nv12 delivers a producer's exact NV12 pixels into a sampleable
// texture for each tier: same-device direct, decoder-array GPU copy, and a shared
// NT-handle. A synthetic producer fills a known pattern; the import is read back
// and compared byte-for-byte. Skips when no D3D11 device is available (headless
// CI). Plane-SRV sampling and CSC are the existing shared_nv12 path, verified
// separately, so this isolates the new open/copy/handle/keyed-mutex logic.
test "imported nv12 import delivers the producer pixels per tier" {
    const V = struct {
        const w: u32 = 64;
        const h: u32 = 64;
        const luma_bytes: u32 = w * h;
        const total_bytes: u32 = w * h * 3 / 2;
        const tolerance: u8 = 4;
        const match_min: f32 = 0.998;

        extern "d3d11" fn D3D11CreateDevice(
            adapter: ?*anyopaque,
            driver_type: u32,
            software: ?win32.HMODULE,
            flags: u32,
            levels: ?[*]const u32,
            num_levels: u32,
            sdk: u32,
            device: *?*d3d11.ID3D11Device,
            out_level: ?*u32,
            context: *?*d3d11.ID3D11DeviceContext,
        ) callconv(.winapi) win32.HRESULT;

        const Trio = struct {
            device: *d3d11.ID3D11Device,
            context: *d3d11.ID3D11DeviceContext,
            device1: ?*d3d11.ID3D11Device1,
        };

        // A deterministic NV12 buffer: Y then a half-size interleaved CbCr plane.
        fn pattern() [total_bytes]u8 {
            var buf: [total_bytes]u8 = undefined;
            var i: u32 = 0;
            while (i < luma_bytes) : (i += 1) buf[i] = @truncate(i *% 7 +% 11);
            while (i < total_bytes) : (i += 1) buf[i] = @truncate(i *% 5 +% 3);
            return buf;
        }

        fn make_device() ?Trio {
            const levels = [_]u32{d3d11.D3D_FEATURE_LEVEL_11_0};
            for ([_]u32{ d3d11.D3D_DRIVER_TYPE_HARDWARE, 5 }) |driver| {
                var device: ?*d3d11.ID3D11Device = null;
                var context: ?*d3d11.ID3D11DeviceContext = null;
                const hr = D3D11CreateDevice(
                    null,
                    driver,
                    null,
                    0,
                    &levels,
                    levels.len,
                    d3d11.D3D11_SDK_VERSION,
                    &device,
                    null,
                    &context,
                );
                if (com.failed(hr) or device == null or context == null) continue;
                var raw: ?*anyopaque = null;
                _ = com.query_interface(device.?, &d3d11.IID_ID3D11Device1, &raw);
                return .{
                    .device = device.?,
                    .context = context.?,
                    .device1 = if (raw) |p| @ptrCast(@alignCast(p)) else null,
                };
            }
            return null;
        }

        // An NV12 source the producer fills; misc carries the share flags (0 for a
        // same-device source). Returns null if the driver rejects the format.
        fn make_source(dev: *d3d11.ID3D11Device, slices: u32, misc: u32) ?*anyopaque {
            std.debug.assert(slices >= 1);
            const desc = d3d11.D3D11_TEXTURE2D_DESC{
                .Width = w,
                .Height = h,
                .MipLevels = 1,
                .ArraySize = slices,
                .Format = dxgi.DXGI_FORMAT_NV12,
                .SampleDesc = .{ .Count = 1, .Quality = 0 },
                .Usage = d3d11.D3D11_USAGE_DEFAULT,
                .BindFlags = d3d11.D3D11_BIND_SHADER_RESOURCE,
                .CPUAccessFlags = 0,
                .MiscFlags = misc,
            };
            var tex: ?*anyopaque = null;
            if (com.failed(dev.create_texture2d(&desc, null, &tex))) return null;
            return tex;
        }

        fn fill(
            ctx: *d3d11.ID3D11DeviceContext,
            tex: *anyopaque,
            slice: u32,
            p: *const [total_bytes]u8,
        ) void {
            ctx.update_subresource(tex, slice, null, p, w, luma_bytes);
        }

        // Acquires the keyed mutex (key 0 is free at creation) before writing a
        // share-target source, then releases the key the consumer will acquire.
        fn fill_shared(
            ctx: *d3d11.ID3D11DeviceContext,
            tex: *anyopaque,
            key: u64,
            p: *const [total_bytes]u8,
        ) bool {
            var mutex: ?*dxgi.IDXGIKeyedMutex = null;
            if (com.failed(query_keyed_mutex(tex, &mutex))) return false;
            defer com.release(&mutex);
            if (com.failed(mutex.?.acquire_sync(0, 0))) return false;
            ctx.update_subresource(tex, 0, null, p, w, luma_bytes);
            return com.succeeded(mutex.?.release_sync(key));
        }

        fn shared_handle(tex: *anyopaque) ?win32.HANDLE {
            var raw: ?*anyopaque = null;
            if (com.failed(com.query_interface(tex, &dxgi.IID_IDXGIResource1, &raw))) return null;
            var res: ?*dxgi.IDXGIResource1 = @ptrCast(@alignCast(raw.?));
            defer com.release(&res);
            var handle: ?win32.HANDLE = null;
            const access = dxgi.DXGI_SHARED_RESOURCE_READ | dxgi.DXGI_SHARED_RESOURCE_WRITE;
            if (com.failed(res.?.create_shared_handle(access, &handle))) return null;
            return handle;
        }

        // Reads `tex` back through a staging copy and returns the fraction of bytes
        // within tolerance of the expected pattern (both planes).
        fn match_fraction(
            dev: *d3d11.ID3D11Device,
            ctx: *d3d11.ID3D11DeviceContext,
            tex: *anyopaque,
            p: *const [total_bytes]u8,
        ) f32 {
            const desc = d3d11.D3D11_TEXTURE2D_DESC{
                .Width = w,
                .Height = h,
                .MipLevels = 1,
                .ArraySize = 1,
                .Format = dxgi.DXGI_FORMAT_NV12,
                .SampleDesc = .{ .Count = 1, .Quality = 0 },
                .Usage = 3,
                .BindFlags = 0,
                .CPUAccessFlags = 0x20000,
                .MiscFlags = 0,
            };
            var staging: ?*anyopaque = null;
            if (com.failed(dev.create_texture2d(&desc, null, &staging))) return 0;
            defer com.release(&staging);
            ctx.copy_resource(staging.?, tex);
            var mapped: d3d11.D3D11_MAPPED_SUBRESOURCE = undefined;
            if (com.failed(ctx.map(staging.?, 0, 1, &mapped))) return 0;
            defer ctx.unmap(staging.?, 0);
            const base: [*]const u8 = @ptrCast(mapped.pData.?);
            const pitch = mapped.RowPitch;
            std.debug.assert(pitch >= w);
            var ok: u32 = 0;
            var total: u32 = 0;
            var row: u32 = 0;
            while (row < h + h / 2) : (row += 1) {
                var col: u32 = 0;
                while (col < w) : (col += 1) {
                    const got = base[row * pitch + col];
                    const want = p[row * w + col];
                    const diff = if (got > want) got - want else want - got;
                    if (diff <= tolerance) ok += 1;
                    total += 1;
                }
            }
            std.debug.assert(total == total_bytes);
            return @as(f32, @floatFromInt(ok)) / @as(f32, @floatFromInt(total));
        }
    };

    const t = std.testing;
    const trio = V.make_device() orelse return;
    var device1 = trio.device1;
    defer {
        com.release(&device1);
        _ = trio.context.vtable.Release(trio.context);
        _ = trio.device.vtable.Release(trio.device);
    }

    var r = Renderer{
        // Only the import path runs here; it reads device/context/device1, never
        // the swapchain or hwnd, so those stay unset and deinit is not called.
        .device = trio.device,
        .context = trio.context,
        .swapchain = undefined,
        .hwnd = undefined,
        .device1 = device1,
    };
    const want = V.pattern();

    // Tier 1: same-device texture, sampled directly with no copy.
    {
        var source: ?*anyopaque = V.make_source(trio.device, 1, 0) orelse return;
        defer com.release(&source);
        V.fill(trio.context, source.?, 0, &want);
        var surf = r.create_imported_nv12_surface(.{
            .texture = source.?,
            .width = V.w,
            .height = V.h,
        }) orelse return;
        defer surf.deinit();
        const got = r.import_nv12(@ptrCast(&surf)) orelse return error.ImportFailed;
        try t.expect(got.cv_luma == @as(*anyopaque, @ptrCast(&surf)));
        try t.expect(V.match_fraction(trio.device, trio.context, source.?, &want) >= V.match_min);
        Renderer.release_cv_texture(got.cv_luma);
        try t.expect(surf.available());
    }

    // Tier 3: a decoder-style array slice copied GPU->GPU into a sampleable target.
    {
        var source: ?*anyopaque = V.make_source(trio.device, 2, 0) orelse return;
        defer com.release(&source);
        V.fill(trio.context, source.?, 1, &want);
        var surf = r.create_imported_nv12_surface(.{
            .texture = source.?,
            .width = V.w,
            .height = V.h,
            .array_slice = 1,
        }) orelse return;
        defer surf.deinit();
        const got = r.import_nv12(@ptrCast(&surf)) orelse return error.ImportFailed;
        const target = surf.state.tex orelse return error.NoCopyTarget;
        const frac = V.match_fraction(trio.device, trio.context, target, &want);
        try t.expect(frac >= V.match_min);
        Renderer.release_cv_texture(got.cv_luma);
        try t.expect(surf.available());
    }

    // Tier 2: a shared NT handle opened on this device, keyed-mutex synchronized.
    if (trio.device1 != null) {
        const misc = d3d11.D3D11_RESOURCE_MISC_SHARED_NTHANDLE |
            d3d11.D3D11_RESOURCE_MISC_SHARED_KEYEDMUTEX;
        var owner: ?*anyopaque = V.make_source(trio.device, 1, misc) orelse return;
        defer com.release(&owner);
        if (!V.fill_shared(trio.context, owner.?, 7, &want)) return;
        const handle = V.shared_handle(owner.?) orelse return;
        var surf = r.create_imported_nv12_surface(.{
            .handle = handle,
            .width = V.w,
            .height = V.h,
            .acquire_key = 7,
            .release_key = 7,
        }) orelse return;
        defer surf.deinit();
        const got = r.import_nv12(@ptrCast(&surf)) orelse return error.ImportFailed;
        const opened = surf.state.tex orelse return error.NoOpenedTexture;
        const frac = V.match_fraction(trio.device, trio.context, opened, &want);
        try t.expect(frac >= V.match_min);
        Renderer.release_cv_texture(got.cv_luma);
        try t.expect(surf.available());
    }
}
