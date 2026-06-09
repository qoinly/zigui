const std = @import("std");
const objc = @import("objc.zig");
const primitives = @import("../../primitives.zig");

const Id = objc.Id;
const NSUInteger = objc.NSUInteger;
const Quad = primitives.Quad;
const MonochromeSprite = primitives.MonochromeSprite;
const PolychromeSprite = primitives.PolychromeSprite;
const Polyline = primitives.Polyline;
const LineSegment = primitives.LineSegment;
const RingChart = primitives.RingChart;
const Frame = primitives.Frame;
const Primitive = primitives.Primitive;

pub const MTLPixelFormat = struct {
    pub const R8Unorm: NSUInteger = 10; // NV12 luma plane
    pub const RG8Unorm: NSUInteger = 30; // NV12 chroma plane (Cb, Cr interleaved)
    pub const BGRA8Unorm: NSUInteger = 80;
};

// A CVPixelBuffer imported zero-copy as NV12. `luma`/`chroma` are the MTLTextures
// to sample; they stay valid only while `cv_luma`/`cv_chroma` (the owning CV refs)
// live, so the caller keeps those refs until the GPU is done, then releases them
// with release_cv_texture.
pub const Nv12Textures = struct {
    luma: *anyopaque,
    chroma: *anyopaque,
    cv_luma: *anyopaque,
    cv_chroma: *anyopaque,
    width: u32,
    height: u32,
};

pub const MTLLoadAction = struct {
    pub const Clear: NSUInteger = 2;
};

pub const MTLStoreAction = struct {
    pub const Store: NSUInteger = 1;
};

pub const MTLResourceOptions = struct {
    pub const StorageModeShared: NSUInteger = 0 << 4;
};

pub const MTLPrimitiveType = struct {
    pub const Triangle: NSUInteger = 3;
};

pub const MTLSamplerMinMagFilter = struct {
    pub const Linear: NSUInteger = 1;
};

pub const MTLTextureUsage = struct {
    pub const ShaderRead: NSUInteger = 1;
    pub const ShaderWrite: NSUInteger = 2;
    pub const RenderTarget: NSUInteger = 4;
};

pub const MTLStorageMode = struct {
    pub const Shared: NSUInteger = 0;
    pub const Private: NSUInteger = 2;
};

// MPS sigma is in points, not pixels - it scales itself by backing scale.
const BLUR_SIGMA: f32 = 12.0;
const MPSImageEdgeModeClamp: NSUInteger = 1;

pub const MTLClearColor = extern struct {
    red: f64,
    green: f64,
    blue: f64,
    alpha: f64,

    pub fn init(r: f64, g: f64, b: f64, a: f64) MTLClearColor {
        return .{ .red = r, .green = g, .blue = b, .alpha = a };
    }
};

const MTLScissorRect = extern struct {
    x: NSUInteger,
    y: NSUInteger,
    width: NSUInteger,
    height: NSUInteger,
};

const MTLRegion = extern struct {
    origin: extern struct { x: NSUInteger, y: NSUInteger, z: NSUInteger },
    size: extern struct { width: NSUInteger, height: NSUInteger, depth: NSUInteger },
};

const MAX_QUADS = 1024;
const MAX_SPRITES = 4096;
const MAX_COLOR_SPRITES = 256;
const MAX_POLYLINES = 1024;
const MAX_LINES = 1024;
const MAX_RINGS = 256;
const MAX_FRAMES = 8;

// Drawables the layer keeps in flight. Pinned (not left to the CAMetalLayer
// default) because the external-frame texture ring sizes itself off this to know
// when a slot is safe to overwrite; an unpinned value would silently break that.
pub const max_frames_in_flight: NSUInteger = 3;

// CPU->GPU uniform for one external-frame draw; mirrors FrameUniform in
// shaders.metal. 96 bytes (multiple of 16) so each element stays float4-aligned at
// its per-draw buffer offset. csc is the YUV->RGB matrix for the NV12 path (three
// rows of m0,m1,m2,offset); unused by the BGRA path.
const FrameGpu = extern struct {
    bounds: [4]f32,
    clip_bounds: [4]f32,
    opacity: f32,
    _pad: [3]f32 = .{ 0, 0, 0 },
    csc: [3][4]f32 = .{.{ 0, 0, 0, 0 }} ** 3,

    comptime {
        // The shader reads this raw; a size/offset drift silently corrupts the draw.
        std.debug.assert(@sizeOf(FrameGpu) == 96);
        std.debug.assert(@offsetOf(FrameGpu, "csc") == 48);
    }
};

pub const Renderer = struct {
    device: Id,
    command_queue: Id,
    layer: Id,
    quad_pipeline_state: ?Id,
    text_pipeline_state: ?Id,
    color_sprite_pipeline_state: ?Id,
    polyline_pipeline_state: ?Id,
    line_pipeline_state: ?Id,
    ring_pipeline_state: ?Id,
    unit_vertex_buffer: Id,
    viewport_size: [2]f32,
    last_drawable_width: objc.CGFloat = 0,
    last_drawable_height: objc.CGFloat = 0,
    quad_buffer: Id,
    sprite_buffer: Id,
    color_sprite_buffer: Id,
    polyline_buffer: Id,
    line_buffer: Id,
    ring_buffer: Id,
    viewport_buffer: Id,
    frame_buffer: Id,
    sampler_state: ?Id,
    quad_offset: usize = 0,
    sprite_offset: usize = 0,
    color_sprite_offset: usize = 0,
    polyline_offset: usize = 0,
    line_offset: usize = 0,
    ring_offset: usize = 0,
    frame_offset: usize = 0,
    dirty: bool = true,
    blit_pipeline_state: ?Id = null,
    frame_pipeline_state: ?Id = null,
    frame_nv12_pipeline_state: ?Id = null,
    metal_texture_cache: ?*anyopaque = null,
    blur_kernel: ?Id = null,
    offscreen_tex: ?Id = null,
    offscreen_blur_tex: ?Id = null,
    offscreen_w: NSUInteger = 0,
    offscreen_h: NSUInteger = 0,

    pub const Error = error{
        NoMetalDevice,
        FailedToCreateCommandQueue,
    };

    pub fn init(metal_layer: Id) Error!Renderer {
        const device = MTLCreateSystemDefaultDevice() orelse return error.NoMetalDevice;

        const command_queue = objc.msg_send(Id, device, "newCommandQueue", .{});
        if (@intFromPtr(command_queue) == 0) return error.FailedToCreateCommandQueue;

        objc.msg_send(void, metal_layer, "setDevice:", .{device});
        objc.msg_send(void, metal_layer, "setPixelFormat:", .{
            MTLPixelFormat.BGRA8Unorm,
        });
        objc.msg_send(void, metal_layer, "setFramebufferOnly:", .{objc.YES});
        objc.msg_send(void, metal_layer, "setMaximumDrawableCount:", .{max_frames_in_flight});

        const unit_vertex_buffer = objc.msg_send(
            Id,
            device,
            "newBufferWithBytes:length:options:",
            .{
                @as(*const anyopaque, @ptrCast(&primitives.quad_vertices)),
                @as(NSUInteger, @sizeOf(@TypeOf(primitives.quad_vertices))),
                MTLResourceOptions.StorageModeShared,
            },
        );

        const quad_buffer = objc.msg_send(Id, device, "newBufferWithLength:options:", .{
            @as(NSUInteger, MAX_QUADS * @sizeOf(Quad)),
            MTLResourceOptions.StorageModeShared,
        });

        const sprite_buffer = objc.msg_send(Id, device, "newBufferWithLength:options:", .{
            @as(NSUInteger, MAX_SPRITES * @sizeOf(MonochromeSprite)),
            MTLResourceOptions.StorageModeShared,
        });

        const color_sprite_buffer = objc.msg_send(Id, device, "newBufferWithLength:options:", .{
            @as(NSUInteger, MAX_COLOR_SPRITES * @sizeOf(PolychromeSprite)),
            MTLResourceOptions.StorageModeShared,
        });

        const polyline_buffer = objc.msg_send(Id, device, "newBufferWithLength:options:", .{
            @as(NSUInteger, MAX_POLYLINES * @sizeOf(Polyline)),
            MTLResourceOptions.StorageModeShared,
        });

        const line_buffer = objc.msg_send(Id, device, "newBufferWithLength:options:", .{
            @as(NSUInteger, MAX_LINES * @sizeOf(LineSegment)),
            MTLResourceOptions.StorageModeShared,
        });

        const ring_buffer = objc.msg_send(Id, device, "newBufferWithLength:options:", .{
            @as(NSUInteger, MAX_RINGS * @sizeOf(RingChart)),
            MTLResourceOptions.StorageModeShared,
        });

        const viewport_buffer = objc.msg_send(Id, device, "newBufferWithLength:options:", .{
            @as(NSUInteger, @sizeOf([2]f32)),
            MTLResourceOptions.StorageModeShared,
        });

        const frame_buffer = objc.msg_send(Id, device, "newBufferWithLength:options:", .{
            @as(NSUInteger, MAX_FRAMES * @sizeOf(FrameGpu)),
            MTLResourceOptions.StorageModeShared,
        });

        var renderer = Renderer{
            .device = device,
            .command_queue = command_queue,
            .layer = metal_layer,
            .quad_pipeline_state = null,
            .text_pipeline_state = null,
            .color_sprite_pipeline_state = null,
            .polyline_pipeline_state = null,
            .line_pipeline_state = null,
            .ring_pipeline_state = null,
            .unit_vertex_buffer = unit_vertex_buffer,
            .viewport_size = .{ 800, 600 },
            .quad_buffer = quad_buffer,
            .sprite_buffer = sprite_buffer,
            .color_sprite_buffer = color_sprite_buffer,
            .polyline_buffer = polyline_buffer,
            .line_buffer = line_buffer,
            .ring_buffer = ring_buffer,
            .viewport_buffer = viewport_buffer,
            .frame_buffer = frame_buffer,
            .sampler_state = null,
        };

        renderer.quad_pipeline_state = renderer.create_pipeline_state(
            "quad_vertex",
            "quad_fragment",
        );
        renderer.text_pipeline_state = renderer.create_pipeline_state(
            "text_vertex",
            "text_fragment",
        );
        renderer.color_sprite_pipeline_state = renderer.create_pipeline_state(
            "color_sprite_vertex",
            "color_sprite_fragment",
        );
        renderer.polyline_pipeline_state = renderer.create_pipeline_state(
            "polyline_vertex",
            "polyline_fragment",
        );
        renderer.line_pipeline_state = renderer.create_pipeline_state(
            "line_segment_vertex",
            "line_segment_fragment",
        );
        renderer.ring_pipeline_state = renderer.create_pipeline_state(
            "ring_chart_vertex",
            "ring_chart_fragment",
        );
        renderer.sampler_state = renderer.create_sampler_state();
        renderer.blit_pipeline_state = renderer.create_pipeline_state(
            "blit_vertex",
            "blit_fragment",
        );
        renderer.frame_pipeline_state = renderer.create_pipeline_state(
            "frame_vertex",
            "frame_fragment",
        );
        renderer.frame_nv12_pipeline_state = renderer.create_pipeline_state(
            "frame_vertex",
            "frame_nv12_fragment",
        );
        var cache: ?*anyopaque = null;
        if (CVMetalTextureCacheCreate(null, null, device, null, &cache) == 0) {
            renderer.metal_texture_cache = cache;
        }

        return renderer;
    }

    // The device is objc.Id, erased to *anyopaque only because the cross-platform
    // renderer facade forces one get_device signature (Windows returns an
    // ID3D11Device here). device_from_opaque is the sanctioned inverse - the one
    // way to round-trip the handle back to its real type.
    pub fn get_device(self: *Renderer) *anyopaque {
        return @ptrCast(self.device);
    }

    pub fn device_from_opaque(ptr: *anyopaque) Id {
        return @ptrCast(@alignCast(ptr));
    }

    // Bind an NV12 CVPixelBuffer to Metal textures with no copy. Returns null if
    // the cache is absent or either plane fails to map. The caller owns the two CV
    // refs and must release them (after the GPU is done) with release_cv_texture.
    pub fn import_nv12(self: *Renderer, pixel_buffer: *anyopaque) ?Nv12Textures {
        const cache = self.metal_texture_cache orelse return null;
        const w = CVPixelBufferGetWidth(pixel_buffer);
        const h = CVPixelBufferGetHeight(pixel_buffer);
        std.debug.assert(w > 0);
        std.debug.assert(h > 0);

        // CreateTextureFromImage returns the ref +1; this is an optional, not an
        // error union, so every failure exit releases by hand (errdefer would not
        // fire on `return null`).
        var cv_luma: ?*anyopaque = null;
        if (CVMetalTextureCacheCreateTextureFromImage(
            null,
            cache,
            pixel_buffer,
            null,
            MTLPixelFormat.R8Unorm,
            w,
            h,
            0,
            &cv_luma,
        ) != 0) return null;

        var cv_chroma: ?*anyopaque = null;
        if (CVMetalTextureCacheCreateTextureFromImage(
            null,
            cache,
            pixel_buffer,
            null,
            MTLPixelFormat.RG8Unorm,
            w / 2,
            h / 2,
            1,
            &cv_chroma,
        ) != 0) {
            CFRelease(cv_luma);
            return null;
        }

        const luma = CVMetalTextureGetTexture(cv_luma) orelse {
            CFRelease(cv_luma);
            CFRelease(cv_chroma);
            return null;
        };
        const chroma = CVMetalTextureGetTexture(cv_chroma) orelse {
            CFRelease(cv_luma);
            CFRelease(cv_chroma);
            return null;
        };
        return .{
            .luma = @ptrCast(luma),
            .chroma = @ptrCast(chroma),
            .cv_luma = cv_luma.?,
            .cv_chroma = cv_chroma.?,
            .width = @intCast(w),
            .height = @intCast(h),
        };
    }

    // Release a CV ref returned in Nv12Textures once the GPU no longer reads it.
    pub fn release_cv_texture(ref: *anyopaque) void {
        CFRelease(ref);
    }

    // Hold/drop a ref on a decoder's CVPixelBuffer so its IOSurface is not recycled
    // while a slot still points at it.
    pub fn retain_surface(pixel_buffer: *anyopaque) void {
        _ = CVBufferRetain(pixel_buffer);
    }

    pub fn release_surface(pixel_buffer: *anyopaque) void {
        CVBufferRelease(pixel_buffer);
    }

    // Recycle internal CV texture-cache bookkeeping; call once a frame.
    pub fn flush_texture_cache(self: *Renderer) void {
        if (self.metal_texture_cache) |cache| CVMetalTextureCacheFlush(cache, 0);
    }

    // layer is owned by the view, not us - never release it. Everything else here
    // came back +1 from a new*/Create call, so release exactly once; device last,
    // after the buffers/textures/pipelines built from it.
    pub fn deinit(self: *Renderer) void {
        const owned = [_]Id{
            self.command_queue,
            self.unit_vertex_buffer,
            self.quad_buffer,
            self.sprite_buffer,
            self.color_sprite_buffer,
            self.polyline_buffer,
            self.line_buffer,
            self.ring_buffer,
            self.viewport_buffer,
            self.frame_buffer,
        };
        for (owned) |obj| objc.msg_send(void, obj, "release", .{});
        const optional = [_]?Id{
            self.quad_pipeline_state,
            self.text_pipeline_state,
            self.color_sprite_pipeline_state,
            self.polyline_pipeline_state,
            self.line_pipeline_state,
            self.ring_pipeline_state,
            self.sampler_state,
            self.blit_pipeline_state,
            self.frame_pipeline_state,
            self.frame_nv12_pipeline_state,
            self.blur_kernel,
            self.offscreen_tex,
            self.offscreen_blur_tex,
        };
        for (optional) |maybe| if (maybe) |obj| objc.msg_send(void, obj, "release", .{});
        if (self.metal_texture_cache) |cache| CFRelease(cache);
        objc.msg_send(void, self.device, "release", .{});
        self.* = undefined;
    }

    pub fn request_redraw(self: *Renderer) void {
        self.dirty = true;
    }

    pub fn draw_frame(
        self: *Renderer,
        clear_color: MTLClearColor,
        prims: []const Primitive,
        sprites: []const MonochromeSprite,
        mono_atlas_texture: ?*anyopaque,
        color_sprites: []const PolychromeSprite,
        color_atlas_texture: ?*anyopaque,
    ) void {
        self.draw_frame_impl(
            clear_color,
            prims,
            sprites,
            mono_atlas_texture,
            color_sprites,
            color_atlas_texture,
            false,
            0,
            0,
            0,
            0,
        );
    }

    // Modal frame: prims/sprites before the split render blurred (backdrop); the
    // rest draw crisp on top. The top crisp_top points stay unblurred (the title
    // bar sits above the modal, like macOS - it never frosts).
    pub fn draw_frame_modal(
        self: *Renderer,
        clear_color: MTLClearColor,
        prims: []const Primitive,
        sprites: []const MonochromeSprite,
        mono_atlas_texture: ?*anyopaque,
        color_sprites: []const PolychromeSprite,
        color_atlas_texture: ?*anyopaque,
        split_prims: usize,
        split_sprites: usize,
        split_color: usize,
        crisp_top: f32,
    ) void {
        self.draw_frame_impl(
            clear_color,
            prims,
            sprites,
            mono_atlas_texture,
            color_sprites,
            color_atlas_texture,
            true,
            split_prims,
            split_sprites,
            split_color,
            crisp_top,
        );
    }

    fn draw_frame_impl(
        self: *Renderer,
        clear_color: MTLClearColor,
        prims: []const Primitive,
        sprites: []const MonochromeSprite,
        mono_atlas_texture: ?*anyopaque,
        color_sprites: []const PolychromeSprite,
        color_atlas_texture: ?*anyopaque,
        blur: bool,
        split_prims: usize,
        split_sprites: usize,
        split_color: usize,
        crisp_top: f32,
    ) void {
        const mono_atlas_id: ?Id = if (mono_atlas_texture) |p| @ptrCast(p) else null;
        const color_atlas_id: ?Id = if (color_atlas_texture) |p| @ptrCast(p) else null;
        const pool = objc.autorelease_pool_push();
        defer objc.autorelease_pool_pop(pool);

        const scale: objc.CGFloat = objc.msg_send(objc.CGFloat, self.layer, "contentsScale", .{});
        const CGRect = extern struct {
            origin: extern struct { x: objc.CGFloat, y: objc.CGFloat },
            size: extern struct { width: objc.CGFloat, height: objc.CGFloat },
        };
        const CGSize = extern struct { width: objc.CGFloat, height: objc.CGFloat };
        const bounds: CGRect = objc.msg_send(CGRect, self.layer, "bounds", .{});

        const new_width = bounds.size.width * scale;
        const new_height = bounds.size.height * scale;
        if (new_width != self.last_drawable_width or new_height != self.last_drawable_height) {
            const drawable_size = CGSize{ .width = new_width, .height = new_height };
            objc.msg_send(void, self.layer, "setDrawableSize:", .{drawable_size});
            self.last_drawable_width = new_width;
            self.last_drawable_height = new_height;
            self.dirty = true;
        }

        if (!self.dirty) return;

        // Drawable starvation: drop this frame, retry on next vsync.
        const drawable = objc.msg_send(?Id, self.layer, "nextDrawable", .{}) orelse return;
        const texture = objc.msg_send(Id, drawable, "texture", .{});

        self.viewport_size = .{ @floatCast(bounds.size.width), @floatCast(bounds.size.height) };

        const command_buffer = objc.msg_send(Id, self.command_queue, "commandBuffer", .{});

        const viewport_ptr = objc.msg_send(*anyopaque, self.viewport_buffer, "contents", .{});
        const viewport_contents: *[2]f32 = @ptrCast(@alignCast(viewport_ptr));
        viewport_contents.* = self.viewport_size;

        // Instance-buffer offsets stay continuous across both passes (same
        // shared buffers), so reset only once per frame.
        self.quad_offset = 0;
        self.sprite_offset = 0;
        self.color_sprite_offset = 0;
        self.polyline_offset = 0;
        self.line_offset = 0;
        self.ring_offset = 0;
        self.frame_offset = 0;

        const want_blur = blur and self.blit_pipeline_state != null and
            split_prims <= prims.len and split_sprites <= sprites.len and
            split_color <= color_sprites.len;
        if (want_blur) self.ensure_offscreen(new_width, new_height);
        const do_blur = want_blur and self.offscreen_tex != null and
            self.offscreen_blur_tex != null and self.ensure_blur();

        if (do_blur) {
            const off = self.offscreen_tex.?;
            const blurred = self.offscreen_blur_tex.?;
            const enc1 = self.begin_pass(command_buffer, off, clear_color) orelse return;
            self.encode_scene(
                enc1,
                prims[0..split_prims],
                sprites[0..split_sprites],
                color_sprites[0..split_color],
                mono_atlas_id,
                color_atlas_id,
            );
            objc.msg_send(void, enc1, "endEncoding", .{});
            objc.msg_send(
                void,
                self.blur_kernel.?,
                "encodeToCommandBuffer:sourceTexture:destinationTexture:",
                .{ command_buffer, off, blurred },
            );
            // Top strip re-blits the UNBLURRED backdrop so the title bar stays
            // crisp above the modal (scissor is pixels, top-left origin).
            const enc2 = self.begin_pass(command_buffer, texture, clear_color) orelse return;
            self.encode_blit(enc2, blurred);
            const top_px: f64 = @as(f64, crisp_top) * scale;
            if (top_px >= 1) {
                const dw: NSUInteger = @intFromFloat(new_width);
                const dh: NSUInteger = @intFromFloat(new_height);
                const th: NSUInteger = @intFromFloat(@min(top_px, new_height));
                const strip = MTLScissorRect{ .x = 0, .y = 0, .width = dw, .height = th };
                const full = MTLScissorRect{ .x = 0, .y = 0, .width = dw, .height = dh };
                objc.msg_send(void, enc2, "setScissorRect:", .{strip});
                self.encode_blit(enc2, off);
                objc.msg_send(void, enc2, "setScissorRect:", .{full});
            }
            self.encode_scene(
                enc2,
                prims[split_prims..],
                sprites[split_sprites..],
                color_sprites[split_color..],
                mono_atlas_id,
                color_atlas_id,
            );
            objc.msg_send(void, enc2, "endEncoding", .{});
        } else {
            const enc = self.begin_pass(command_buffer, texture, clear_color) orelse return;
            self.encode_scene(enc, prims, sprites, color_sprites, mono_atlas_id, color_atlas_id);
            objc.msg_send(void, enc, "endEncoding", .{});
        }

        objc.msg_send(void, command_buffer, "presentDrawable:", .{drawable});
        objc.msg_send(void, command_buffer, "commit", .{});
        self.dirty = false;
    }

    fn begin_pass(self: *Renderer, cmd: Id, tex: Id, clear: MTLClearColor) ?Id {
        _ = self;
        const RPD = objc.get_class("MTLRenderPassDescriptor") orelse return null;
        const desc = objc.msg_send(Id, RPD, "renderPassDescriptor", .{});
        const atts = objc.msg_send(Id, desc, "colorAttachments", .{});
        const a0 = objc.msg_send(Id, atts, "objectAtIndexedSubscript:", .{@as(NSUInteger, 0)});
        objc.msg_send(void, a0, "setTexture:", .{tex});
        objc.msg_send(void, a0, "setLoadAction:", .{MTLLoadAction.Clear});
        objc.msg_send(void, a0, "setStoreAction:", .{MTLStoreAction.Store});
        objc.msg_send(void, a0, "setClearColor:", .{clear});
        return objc.msg_send(Id, cmd, "renderCommandEncoderWithDescriptor:", .{desc});
    }

    fn encode_scene(
        self: *Renderer,
        encoder: Id,
        prims: []const Primitive,
        sprites: []const MonochromeSprite,
        color_sprites: []const PolychromeSprite,
        mono_atlas_id: ?Id,
        color_atlas_id: ?Id,
    ) void {
        var i: usize = 0;
        while (i < prims.len) {
            const start = i;
            const prim_type = prims[i];
            const tag = std.meta.activeTag(prim_type);
            while (i < prims.len and std.meta.activeTag(prims[i]) == tag) {
                i += 1;
            }
            std.debug.assert(i > start); // the run always includes prims[start]; loop must advance
            const batch = prims[start..i];
            switch (prim_type) {
                .quad => if (self.quad_pipeline_state) |p|
                    self.encode_quad_batch(encoder, p, batch),
                .polyline => if (self.polyline_pipeline_state) |p|
                    self.encode_polyline_batch(encoder, p, batch),
                .line_segment => if (self.line_pipeline_state) |p|
                    self.encode_line_batch(encoder, p, batch),
                .ring_chart => if (self.ring_pipeline_state) |p|
                    self.encode_ring_batch(encoder, p, batch),
                .frame => self.encode_frame_batch(encoder, batch),
            }
        }
        if (self.text_pipeline_state) |p| {
            if (sprites.len > 0 and mono_atlas_id != null)
                self.encode_sprites(encoder, p, sprites, mono_atlas_id.?);
        }
        if (self.color_sprite_pipeline_state) |p| {
            if (color_sprites.len > 0 and color_atlas_id != null)
                self.encode_color_sprites(encoder, p, color_sprites, color_atlas_id.?);
        }
    }

    fn encode_blit(self: *Renderer, encoder: Id, tex: Id) void {
        const pipeline = self.blit_pipeline_state orelse return;
        objc.msg_send(void, encoder, "setRenderPipelineState:", .{pipeline});
        objc.msg_send(void, encoder, "setFragmentTexture:atIndex:", .{ tex, @as(NSUInteger, 0) });
        objc.msg_send(void, encoder, "drawPrimitives:vertexStart:vertexCount:instanceCount:", .{
            MTLPrimitiveType.Triangle, @as(NSUInteger, 0), @as(NSUInteger, 6), @as(NSUInteger, 1),
        });
    }

    // External frames each carry their own texture(s), so they can't share one
    // instanced draw - bind + draw one per primitive. The pipeline is chosen per
    // frame (BGRA vs NV12), so a mixed batch is fine. Bounded by MAX_FRAMES.
    fn encode_frame_batch(self: *Renderer, encoder: Id, batch: []const Primitive) void {
        const ptr = objc.msg_send(*anyopaque, self.frame_buffer, "contents", .{});
        const frames: [*]FrameGpu = @ptrCast(@alignCast(ptr));
        for (batch) |prim| {
            const f = prim.frame;
            const tex = f.tex orelse continue;
            const nv12 = f.tex_cbcr != null;
            const want = if (nv12) self.frame_nv12_pipeline_state else self.frame_pipeline_state;
            const p = want orelse continue;
            if (self.frame_offset >= MAX_FRAMES) return; // a UI never stacks this many

            frames[self.frame_offset] = .{
                .bounds = f.bounds,
                .clip_bounds = f.clip_bounds,
                .opacity = f.opacity,
                .csc = f.csc,
            };
            const off = self.frame_offset * @sizeOf(FrameGpu);
            objc.msg_send(void, encoder, "setRenderPipelineState:", .{p});
            objc.msg_send(void, encoder, "setVertexBuffer:offset:atIndex:", .{
                self.unit_vertex_buffer, @as(NSUInteger, 0), @as(NSUInteger, 0),
            });
            objc.msg_send(void, encoder, "setVertexBuffer:offset:atIndex:", .{
                self.frame_buffer, @as(NSUInteger, off), @as(NSUInteger, 1),
            });
            objc.msg_send(void, encoder, "setVertexBuffer:offset:atIndex:", .{
                self.viewport_buffer, @as(NSUInteger, 0), @as(NSUInteger, 2),
            });
            objc.msg_send(void, encoder, "setFragmentTexture:atIndex:", .{
                @as(Id, @ptrCast(tex)), @as(NSUInteger, 0),
            });
            if (f.tex_cbcr) |chroma| {
                // Only NV12 needs the csc uniform and the second plane in the
                // fragment stage; the BGRA pipeline binds neither.
                objc.msg_send(void, encoder, "setFragmentBuffer:offset:atIndex:", .{
                    self.frame_buffer, @as(NSUInteger, off), @as(NSUInteger, 0),
                });
                objc.msg_send(void, encoder, "setFragmentTexture:atIndex:", .{
                    @as(Id, @ptrCast(chroma)), @as(NSUInteger, 1),
                });
            }
            if (self.sampler_state) |sampler| {
                objc.msg_send(void, encoder, "setFragmentSamplerState:atIndex:", .{
                    sampler, @as(NSUInteger, 0),
                });
            }
            objc.msg_send(void, encoder, "drawPrimitives:vertexStart:vertexCount:instanceCount:", .{
                MTLPrimitiveType.Triangle, @as(NSUInteger, 0),
                @as(NSUInteger, 6),        @as(NSUInteger, 1),
            });
            self.frame_offset += 1;
        }
    }

    fn ensure_offscreen(self: *Renderer, w_f: objc.CGFloat, h_f: objc.CGFloat) void {
        const w: NSUInteger = @intFromFloat(w_f);
        const h: NSUInteger = @intFromFloat(h_f);
        if (w == 0 or h == 0) return;
        if (self.offscreen_tex != null and self.offscreen_w == w and self.offscreen_h == h) return;
        const TD = objc.get_class("MTLTextureDescriptor") orelse return;
        const desc = objc.msg_send(
            Id,
            TD,
            "texture2DDescriptorWithPixelFormat:width:height:mipmapped:",
            .{ MTLPixelFormat.BGRA8Unorm, w, h, objc.NO },
        );
        const usage = MTLTextureUsage.RenderTarget | MTLTextureUsage.ShaderRead |
            MTLTextureUsage.ShaderWrite;
        objc.msg_send(void, desc, "setUsage:", .{usage});
        objc.msg_send(void, desc, "setStorageMode:", .{MTLStorageMode.Private});
        const t1 = objc.msg_send(?Id, self.device, "newTextureWithDescriptor:", .{desc}) orelse
            return;
        const t2 = objc.msg_send(?Id, self.device, "newTextureWithDescriptor:", .{desc}) orelse
            return;
        if (self.offscreen_tex) |old| objc.msg_send(void, old, "release", .{});
        if (self.offscreen_blur_tex) |old| objc.msg_send(void, old, "release", .{});
        self.offscreen_tex = t1;
        self.offscreen_blur_tex = t2;
        self.offscreen_w = w;
        self.offscreen_h = h;
    }

    fn ensure_blur(self: *Renderer) bool {
        if (self.blur_kernel != null) return true;
        const cls = objc.get_class("MPSImageGaussianBlur") orelse return false;
        const k = objc.msg_send(?Id, objc.alloc(cls), "initWithDevice:sigma:", .{
            self.device,
            BLUR_SIGMA,
        }) orelse return false;
        objc.msg_send(void, k, "setEdgeMode:", .{MPSImageEdgeModeClamp});
        self.blur_kernel = k;
        return true;
    }

    fn create_sampler_state(self: *Renderer) ?Id {
        const MTLSamplerDescriptor = objc.get_class("MTLSamplerDescriptor") orelse return null;
        const desc = objc.msg_send(Id, MTLSamplerDescriptor, "new", .{});

        objc.msg_send(void, desc, "setMinFilter:", .{MTLSamplerMinMagFilter.Linear});
        objc.msg_send(void, desc, "setMagFilter:", .{MTLSamplerMinMagFilter.Linear});

        return objc.msg_send(?Id, self.device, "newSamplerStateWithDescriptor:", .{desc});
    }

    fn create_pipeline_state(
        self: *Renderer,
        vertex_name: [:0]const u8,
        fragment_name: [:0]const u8,
    ) ?Id {
        const shader_source = @embedFile("shaders.metal");

        const NSString = objc.get_class("NSString") orelse return null;
        const source_str = objc.msg_send(Id, NSString, "stringWithUTF8String:", .{
            shader_source.ptr,
        });

        const MTLCompileOptions = objc.get_class("MTLCompileOptions") orelse return null;
        const options = objc.msg_send(Id, MTLCompileOptions, "new", .{});
        // The pipeline state retains what it needs, so these build-time objects
        // (options/library/functions/descriptor) are released once it is built.
        defer objc.msg_send(void, options, "release", .{});

        var error_ptr: ?Id = null;
        const library = objc.msg_send(?Id, self.device, "newLibraryWithSource:options:error:", .{
            source_str, options, &error_ptr,
        });

        if (library == null) {
            if (error_ptr) |err| {
                const desc = objc.msg_send(Id, err, "localizedDescription", .{});
                const cstr = objc.msg_send([*:0]const u8, desc, "UTF8String", .{});
                std.debug.print("shader compile error: {s}\n", .{cstr});
            }
            return null;
        }
        defer objc.msg_send(void, library.?, "release", .{});

        const v_name = objc.msg_send(Id, NSString, "stringWithUTF8String:", .{vertex_name.ptr});
        const f_name = objc.msg_send(Id, NSString, "stringWithUTF8String:", .{fragment_name.ptr});

        const vertex_func = objc.msg_send(?Id, library.?, "newFunctionWithName:", .{v_name});
        defer if (vertex_func) |o| objc.msg_send(void, o, "release", .{});
        const fragment_func = objc.msg_send(?Id, library.?, "newFunctionWithName:", .{f_name});
        defer if (fragment_func) |o| objc.msg_send(void, o, "release", .{});

        if (vertex_func == null or fragment_func == null) {
            std.debug.print("missing shader func: {s} / {s}\n", .{ vertex_name, fragment_name });
            return null;
        }

        const MTLRenderPipelineDescriptor =
            objc.get_class("MTLRenderPipelineDescriptor") orelse return null;
        const desc = objc.msg_send(Id, MTLRenderPipelineDescriptor, "new", .{});
        defer objc.msg_send(void, desc, "release", .{});

        objc.msg_send(void, desc, "setVertexFunction:", .{vertex_func.?});
        objc.msg_send(void, desc, "setFragmentFunction:", .{fragment_func.?});

        const color_attachments = objc.msg_send(Id, desc, "colorAttachments", .{});
        const color_attachment0 = objc.msg_send(
            Id,
            color_attachments,
            "objectAtIndexedSubscript:",
            .{@as(NSUInteger, 0)},
        );
        objc.msg_send(void, color_attachment0, "setPixelFormat:", .{MTLPixelFormat.BGRA8Unorm});

        // Premultiplied alpha: src + dst*(1-src.a).
        objc.msg_send(void, color_attachment0, "setBlendingEnabled:", .{objc.YES});
        objc.msg_send(void, color_attachment0, "setSourceRGBBlendFactor:", .{@as(NSUInteger, 4)});
        objc.msg_send(void, color_attachment0, "setDestinationRGBBlendFactor:", .{
            @as(NSUInteger, 5),
        });
        objc.msg_send(void, color_attachment0, "setSourceAlphaBlendFactor:", .{@as(NSUInteger, 1)});
        objc.msg_send(void, color_attachment0, "setDestinationAlphaBlendFactor:", .{
            @as(NSUInteger, 5),
        });

        var pipeline_error: ?Id = null;
        const pipeline_state = objc.msg_send(
            ?Id,
            self.device,
            "newRenderPipelineStateWithDescriptor:error:",
            .{ desc, &pipeline_error },
        );

        if (pipeline_state == null) {
            std.debug.print("pipeline state creation failed\n", .{});
            return null;
        }

        return pipeline_state;
    }

    fn encode_quad_batch(
        self: *Renderer,
        encoder: Id,
        pipeline: Id,
        batch: []const Primitive,
    ) void {
        std.debug.assert(self.quad_offset + batch.len <= MAX_QUADS);
        if (self.quad_offset + batch.len > MAX_QUADS) return;

        objc.msg_send(void, encoder, "setRenderPipelineState:", .{pipeline});

        const quad_ptr = objc.msg_send(*anyopaque, self.quad_buffer, "contents", .{});
        const quad_contents: [*]Quad = @ptrCast(@alignCast(quad_ptr));
        for (batch, 0..) |prim, idx| {
            quad_contents[self.quad_offset + idx] = prim.quad;
        }

        const buffer_offset = self.quad_offset * @sizeOf(Quad);
        objc.msg_send(void, encoder, "setVertexBuffer:offset:atIndex:", .{
            self.unit_vertex_buffer, @as(NSUInteger, 0), @as(NSUInteger, 0),
        });
        objc.msg_send(void, encoder, "setVertexBuffer:offset:atIndex:", .{
            self.quad_buffer, @as(NSUInteger, buffer_offset), @as(NSUInteger, 1),
        });
        objc.msg_send(void, encoder, "setVertexBuffer:offset:atIndex:", .{
            self.viewport_buffer, @as(NSUInteger, 0), @as(NSUInteger, 2),
        });

        objc.msg_send(void, encoder, "drawPrimitives:vertexStart:vertexCount:instanceCount:", .{
            MTLPrimitiveType.Triangle,
            @as(NSUInteger, 0),
            @as(NSUInteger, 6),
            @as(NSUInteger, batch.len),
        });

        self.quad_offset += batch.len;
    }

    fn encode_sprites(
        self: *Renderer,
        encoder: Id,
        pipeline: Id,
        sprites: []const MonochromeSprite,
        atlas: Id,
    ) void {
        std.debug.assert(self.sprite_offset + sprites.len <= MAX_SPRITES);
        if (self.sprite_offset + sprites.len > MAX_SPRITES) return;

        objc.msg_send(void, encoder, "setRenderPipelineState:", .{pipeline});

        const sprite_ptr = objc.msg_send(*anyopaque, self.sprite_buffer, "contents", .{});
        const sprite_contents: [*]MonochromeSprite = @ptrCast(@alignCast(sprite_ptr));
        @memcpy(sprite_contents[self.sprite_offset..][0..sprites.len], sprites);

        const buffer_offset = self.sprite_offset * @sizeOf(MonochromeSprite);
        objc.msg_send(void, encoder, "setVertexBuffer:offset:atIndex:", .{
            self.unit_vertex_buffer, @as(NSUInteger, 0), @as(NSUInteger, 0),
        });
        objc.msg_send(void, encoder, "setVertexBuffer:offset:atIndex:", .{
            self.sprite_buffer, @as(NSUInteger, buffer_offset), @as(NSUInteger, 1),
        });
        objc.msg_send(void, encoder, "setVertexBuffer:offset:atIndex:", .{
            self.viewport_buffer, @as(NSUInteger, 0), @as(NSUInteger, 2),
        });

        objc.msg_send(void, encoder, "setFragmentTexture:atIndex:", .{ atlas, @as(NSUInteger, 0) });

        if (self.sampler_state) |sampler| {
            objc.msg_send(void, encoder, "setFragmentSamplerState:atIndex:", .{
                sampler,
                @as(NSUInteger, 0),
            });
        }

        objc.msg_send(void, encoder, "drawPrimitives:vertexStart:vertexCount:instanceCount:", .{
            MTLPrimitiveType.Triangle,
            @as(NSUInteger, 0),
            @as(NSUInteger, 6),
            @as(NSUInteger, sprites.len),
        });

        self.sprite_offset += sprites.len;
    }

    fn encode_color_sprites(
        self: *Renderer,
        encoder: Id,
        pipeline: Id,
        sprites: []const PolychromeSprite,
        atlas: Id,
    ) void {
        std.debug.assert(self.color_sprite_offset + sprites.len <= MAX_COLOR_SPRITES);
        if (self.color_sprite_offset + sprites.len > MAX_COLOR_SPRITES) return;

        objc.msg_send(void, encoder, "setRenderPipelineState:", .{pipeline});

        const contents_ptr = objc.msg_send(*anyopaque, self.color_sprite_buffer, "contents", .{});
        const contents: [*]PolychromeSprite = @ptrCast(@alignCast(contents_ptr));
        @memcpy(contents[self.color_sprite_offset..][0..sprites.len], sprites);

        const buffer_offset = self.color_sprite_offset * @sizeOf(PolychromeSprite);
        objc.msg_send(void, encoder, "setVertexBuffer:offset:atIndex:", .{
            self.unit_vertex_buffer, @as(NSUInteger, 0), @as(NSUInteger, 0),
        });
        objc.msg_send(void, encoder, "setVertexBuffer:offset:atIndex:", .{
            self.color_sprite_buffer, @as(NSUInteger, buffer_offset), @as(NSUInteger, 1),
        });
        objc.msg_send(void, encoder, "setVertexBuffer:offset:atIndex:", .{
            self.viewport_buffer, @as(NSUInteger, 0), @as(NSUInteger, 2),
        });

        objc.msg_send(void, encoder, "setFragmentTexture:atIndex:", .{ atlas, @as(NSUInteger, 0) });

        if (self.sampler_state) |sampler| {
            objc.msg_send(void, encoder, "setFragmentSamplerState:atIndex:", .{
                sampler,
                @as(NSUInteger, 0),
            });
        }

        objc.msg_send(void, encoder, "drawPrimitives:vertexStart:vertexCount:instanceCount:", .{
            MTLPrimitiveType.Triangle,
            @as(NSUInteger, 0),
            @as(NSUInteger, 6),
            @as(NSUInteger, sprites.len),
        });

        self.color_sprite_offset += sprites.len;
    }

    fn encode_polyline_batch(
        self: *Renderer,
        encoder: Id,
        pipeline: Id,
        batch: []const Primitive,
    ) void {
        std.debug.assert(self.polyline_offset + batch.len <= MAX_POLYLINES);
        if (self.polyline_offset + batch.len > MAX_POLYLINES) return;

        objc.msg_send(void, encoder, "setRenderPipelineState:", .{pipeline});

        const contents_ptr = objc.msg_send(*anyopaque, self.polyline_buffer, "contents", .{});
        const contents: [*]Polyline = @ptrCast(@alignCast(contents_ptr));
        for (batch, 0..) |prim, idx| {
            contents[self.polyline_offset + idx] = prim.polyline;
        }

        const buffer_offset = self.polyline_offset * @sizeOf(Polyline);
        objc.msg_send(void, encoder, "setVertexBuffer:offset:atIndex:", .{
            self.unit_vertex_buffer, @as(NSUInteger, 0), @as(NSUInteger, 0),
        });
        objc.msg_send(void, encoder, "setVertexBuffer:offset:atIndex:", .{
            self.polyline_buffer, @as(NSUInteger, buffer_offset), @as(NSUInteger, 1),
        });
        objc.msg_send(void, encoder, "setVertexBuffer:offset:atIndex:", .{
            self.viewport_buffer, @as(NSUInteger, 0), @as(NSUInteger, 2),
        });

        objc.msg_send(void, encoder, "drawPrimitives:vertexStart:vertexCount:instanceCount:", .{
            MTLPrimitiveType.Triangle,
            @as(NSUInteger, 0),
            @as(NSUInteger, 6),
            @as(NSUInteger, batch.len),
        });

        self.polyline_offset += batch.len;
    }

    fn encode_line_batch(
        self: *Renderer,
        encoder: Id,
        pipeline: Id,
        batch: []const Primitive,
    ) void {
        std.debug.assert(self.line_offset + batch.len <= MAX_LINES);
        if (self.line_offset + batch.len > MAX_LINES) return;

        objc.msg_send(void, encoder, "setRenderPipelineState:", .{pipeline});

        const contents_ptr = objc.msg_send(*anyopaque, self.line_buffer, "contents", .{});
        const contents: [*]LineSegment = @ptrCast(@alignCast(contents_ptr));
        for (batch, 0..) |prim, idx| {
            contents[self.line_offset + idx] = prim.line_segment;
        }

        const buffer_offset = self.line_offset * @sizeOf(LineSegment);
        objc.msg_send(void, encoder, "setVertexBuffer:offset:atIndex:", .{
            self.unit_vertex_buffer, @as(NSUInteger, 0), @as(NSUInteger, 0),
        });
        objc.msg_send(void, encoder, "setVertexBuffer:offset:atIndex:", .{
            self.line_buffer, @as(NSUInteger, buffer_offset), @as(NSUInteger, 1),
        });
        objc.msg_send(void, encoder, "setVertexBuffer:offset:atIndex:", .{
            self.viewport_buffer, @as(NSUInteger, 0), @as(NSUInteger, 2),
        });

        objc.msg_send(void, encoder, "drawPrimitives:vertexStart:vertexCount:instanceCount:", .{
            MTLPrimitiveType.Triangle,
            @as(NSUInteger, 0),
            @as(NSUInteger, 6),
            @as(NSUInteger, batch.len),
        });

        self.line_offset += batch.len;
    }

    fn encode_ring_batch(
        self: *Renderer,
        encoder: Id,
        pipeline: Id,
        batch: []const Primitive,
    ) void {
        std.debug.assert(self.ring_offset + batch.len <= MAX_RINGS);
        if (self.ring_offset + batch.len > MAX_RINGS) return;

        objc.msg_send(void, encoder, "setRenderPipelineState:", .{pipeline});

        const contents_ptr = objc.msg_send(*anyopaque, self.ring_buffer, "contents", .{});
        const contents: [*]RingChart = @ptrCast(@alignCast(contents_ptr));
        for (batch, 0..) |prim, idx| {
            contents[self.ring_offset + idx] = prim.ring_chart;
        }

        const buffer_offset = self.ring_offset * @sizeOf(RingChart);
        objc.msg_send(void, encoder, "setVertexBuffer:offset:atIndex:", .{
            self.unit_vertex_buffer, @as(NSUInteger, 0), @as(NSUInteger, 0),
        });
        objc.msg_send(void, encoder, "setVertexBuffer:offset:atIndex:", .{
            self.ring_buffer, @as(NSUInteger, buffer_offset), @as(NSUInteger, 1),
        });
        objc.msg_send(void, encoder, "setVertexBuffer:offset:atIndex:", .{
            self.viewport_buffer, @as(NSUInteger, 0), @as(NSUInteger, 2),
        });

        objc.msg_send(void, encoder, "drawPrimitives:vertexStart:vertexCount:instanceCount:", .{
            MTLPrimitiveType.Triangle,
            @as(NSUInteger, 0),
            @as(NSUInteger, 6),
            @as(NSUInteger, batch.len),
        });

        self.ring_offset += batch.len;
    }
};

extern "c" fn MTLCreateSystemDefaultDevice() ?Id;

// CoreVideo zero-copy import. A CVPixelBuffer (IOSurface-backed) is bound to Metal
// textures through the cache without a copy; the plane textures stay valid only
// while their CVMetalTexture refs live, so the caller holds those refs until the
// GPU is done. CV refs are CF objects, released with CFRelease.
const CVReturn = i32;
extern "CoreVideo" fn CVMetalTextureCacheCreate(
    allocator: ?*anyopaque,
    cache_attrs: ?*anyopaque,
    device: Id,
    texture_attrs: ?*anyopaque,
    cache_out: *?*anyopaque,
) CVReturn;
extern "CoreVideo" fn CVMetalTextureCacheCreateTextureFromImage(
    allocator: ?*anyopaque,
    cache: ?*anyopaque,
    image: ?*anyopaque,
    texture_attrs: ?*anyopaque,
    pixel_format: NSUInteger,
    width: usize,
    height: usize,
    plane_index: usize,
    texture_out: *?*anyopaque,
) CVReturn;
extern "CoreVideo" fn CVMetalTextureGetTexture(image: ?*anyopaque) ?Id;
extern "CoreVideo" fn CVMetalTextureCacheFlush(cache: ?*anyopaque, options: u64) void;
extern "CoreVideo" fn CVPixelBufferGetWidth(pixel_buffer: ?*anyopaque) usize;
extern "CoreVideo" fn CVPixelBufferGetHeight(pixel_buffer: ?*anyopaque) usize;
extern "CoreVideo" fn CVBufferRetain(buffer: ?*anyopaque) ?*anyopaque;
extern "CoreVideo" fn CVBufferRelease(buffer: ?*anyopaque) void;
extern "CoreFoundation" fn CFRelease(cf: ?*anyopaque) void;
