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

// CPU-filled BGRA surface; its D3D texture is reused so live video does not churn
// GPU objects while frames arrive.
pub const BgraSurface = struct {
    width: u32,
    height: u32,
    stride: u32,
    pixels: [*]u8,
    tex: ?*anyopaque = null,
    srv: ?*anyopaque = null,
    // Owner + mailbox + GPU ring share this; producer writes only at owner ref.
    refs: std.atomic.Value(u32) = std.atomic.Value(u32).init(1),

    pub fn init(width: u32, height: u32, stride: u32, pixels: [*]u8) BgraSurface {
        std.debug.assert(width > 0);
        std.debug.assert(height > 0);
        std.debug.assert(stride >= width * 4);
        return .{ .width = width, .height = height, .stride = stride, .pixels = pixels };
    }

    pub fn available(self: *const BgraSurface) bool {
        std.debug.assert(self.refs.load(.acquire) >= 1);
        return self.refs.load(.acquire) == 1;
    }

    pub fn deinit(self: *BgraSurface) void {
        std.debug.assert(self.refs.load(.acquire) == 1);
        com.release(&self.srv);
        com.release(&self.tex);
    }
};

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

    quad_pipeline: Pipeline = .{},
    text_pipeline: Pipeline = .{},
    color_sprite_pipeline: Pipeline = .{},
    polyline_pipeline: Pipeline = .{},
    line_pipeline: Pipeline = .{},
    ring_pipeline: Pipeline = .{},
    frame_pipeline: Pipeline = .{},

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

        return self;
    }

    pub fn deinit(self: *Renderer) void {
        com.release(&self.rtv);
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
            &self.quad_pipeline,     &self.text_pipeline, &self.color_sprite_pipeline,
            &self.polyline_pipeline, &self.line_pipeline, &self.ring_pipeline,
            &self.frame_pipeline,    &self.blit_pipeline, &self.blur_h_pipeline,
            &self.blur_v_pipeline,
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

    // The shared facade keeps the macOS import name; Windows accepts this BGRA
    // surface shape and returns one SRV.
    pub const Nv12Textures = struct {
        luma: *anyopaque,
        chroma: ?*anyopaque,
        cv_luma: *anyopaque,
        cv_chroma: ?*anyopaque,
        width: u32,
        height: u32,
    };

    pub fn import_nv12(self: *Renderer, pixel_buffer: *anyopaque) ?Nv12Textures {
        const surface: *BgraSurface = @ptrCast(@alignCast(pixel_buffer));
        std.debug.assert(surface.width > 0);
        std.debug.assert(surface.height > 0);
        return self.import_bgra(surface);
    }

    pub fn release_cv_texture(ref: *anyopaque) void {
        const surface: *BgraSurface = @ptrCast(@alignCast(ref));
        const old = surface.refs.fetchSub(1, .acq_rel);
        std.debug.assert(old > 1);
    }

    pub fn retain_surface(pixel_buffer: *anyopaque) void {
        const surface: *BgraSurface = @ptrCast(@alignCast(pixel_buffer));
        const old = surface.refs.fetchAdd(1, .acq_rel);
        std.debug.assert(old >= 1);
    }

    pub fn release_surface(pixel_buffer: *anyopaque) void {
        const surface: *BgraSurface = @ptrCast(@alignCast(pixel_buffer));
        const old = surface.refs.fetchSub(1, .acq_rel);
        std.debug.assert(old > 1);
    }

    pub fn flush_texture_cache(self: *Renderer) void {
        _ = self;
    }

    fn import_bgra(self: *Renderer, surface: *BgraSurface) ?Nv12Textures {
        std.debug.assert(surface.width > 0);
        std.debug.assert(surface.height > 0);
        std.debug.assert(surface.stride >= surface.width * 4);
        self.ensure_bgra_surface(surface);
        const tex = surface.tex orelse return null;
        const srv = surface.srv orelse return null;
        self.context.update_subresource(tex, 0, null, surface.pixels, surface.stride, 0);
        const old = surface.refs.fetchAdd(1, .acq_rel);
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

    fn ensure_bgra_surface(self: *Renderer, surface: *BgraSurface) void {
        if (surface.tex != null and surface.srv != null) return;
        std.debug.assert(surface.tex == null);
        std.debug.assert(surface.srv == null);
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
        if (com.failed(self.device.create_texture2d(&desc, null, &surface.tex))) return;
        const srv_desc = d3d11.D3D11_SHADER_RESOURCE_VIEW_DESC{
            .Format = dxgi.DXGI_FORMAT_B8G8R8A8_UNORM,
            .ViewDimension = d3d11.D3D11_SRV_DIMENSION_TEXTURE2D,
            .u0 = 0,
            .u1 = 1,
        };
        if (com.failed(self.device.create_srv(surface.tex.?, &srv_desc, &surface.srv))) {
            com.release(&surface.tex);
        }
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
        self.context.vs_set_shader(self.frame_pipeline.vs);
        self.context.ps_set_shader(self.frame_pipeline.ps);
        var frame_cbs = [_]?*anyopaque{cb};
        self.context.vs_set_constant_buffers(1, 1, &frame_cbs);
        self.context.ps_set_constant_buffers(1, 1, &frame_cbs);
        for (batch) |prim| {
            const f = prim.frame;
            if (f.tex_cbcr != null) continue;
            const srv = f.tex orelse continue;
            if (!self.update_frame_cb(cb, f)) continue;
            var srvs = [_]?*anyopaque{srv};
            self.context.ps_set_shader_resources(0, 1, &srvs);
            self.context.draw_instanced(6, 1, 0, 0);
            self.context.ps_set_shader_resources(0, 1, &null_srv);
        }
    }

    fn update_frame_cb(self: *Renderer, cb: *anyopaque, f: primitives.Frame) bool {
        var mapped: d3d11.D3D11_MAPPED_SUBRESOURCE = undefined;
        if (com.failed(self.context.map(cb, 0, d3d11.D3D11_MAP_WRITE_DISCARD, &mapped)))
            return false;
        const dst: *FrameGpu = @ptrCast(@alignCast(mapped.pData.?));
        dst.* = .{
            .bounds = f.bounds,
            .clip_bounds = f.clip_bounds,
            .opacity = f.opacity,
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
