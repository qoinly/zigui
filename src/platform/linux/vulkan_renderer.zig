// Vulkan renderer over the Wayland custom shell (the d3d11_renderer.zig
// analogue). Same architecture: instance data streamed into per-class storage
// buffers, the unit square expanded by gl_VertexIndex, one instanced draw per
// batch. Every primitive class has a pipeline (quads, mono + color sprites,
// polylines, line segments, ring charts, external frames). The modal blur
// pass does not exist here - modal frames draw crisp.

const std = @import("std");
const vk = @import("vulkan.zig");
const wl = @import("wayland.zig");
const shell = @import("custom_shell.zig");
const primitives = @import("../../primitives.zig");

const Primitive = primitives.Primitive;
const Quad = primitives.Quad;
const MonochromeSprite = primitives.MonochromeSprite;
const PolychromeSprite = primitives.PolychromeSprite;
const Polyline = primitives.Polyline;
const LineSegment = primitives.LineSegment;
const RingChart = primitives.RingChart;

pub const max_frames_in_flight: u32 = 3;

const MAX_QUADS: u32 = 1024;
const MAX_SPRITES: u32 = 4096;
const MAX_COLOR_SPRITES: u32 = 256;
const MAX_POLYLINES: u32 = 1024;
const MAX_LINES: u32 = 1024;
const MAX_RINGS: u32 = 256;
const MAX_FRAMES: u32 = 8;
const MAX_FRAME_DIM: u32 = 8192;
const MAX_SWAPCHAIN_IMAGES: u32 = 8;
const MAX_PHYSICAL_DEVICES: u32 = 16;
const MAX_QUEUE_FAMILIES: u32 = 32;
const ACQUIRE_ATTEMPTS_MAX: u32 = 2;

pub const ClearColor = extern struct {
    rgba: [4]f32,

    pub fn init(r: f32, g: f32, b: f32, a: f32) ClearColor {
        std.debug.assert(a >= 0);
        std.debug.assert(a <= 1);
        return .{ .rgba = .{ r, g, b, a } };
    }
};

// Embedded SPIR-V must reach Vulkan 4-byte aligned; @embedFile alone is not.
const quad_vert_spv align(@alignOf(u32)) = @embedFile("shaders/quad.vert.spv").*;
const quad_frag_spv align(@alignOf(u32)) = @embedFile("shaders/quad.frag.spv").*;
const text_vert_spv align(@alignOf(u32)) = @embedFile("shaders/text.vert.spv").*;
const text_frag_spv align(@alignOf(u32)) = @embedFile("shaders/text.frag.spv").*;
const frame_vert_spv align(@alignOf(u32)) = @embedFile("shaders/frame.vert.spv").*;
const frame_rgba_frag_spv align(@alignOf(u32)) = @embedFile("shaders/frame_rgba.frag.spv").*;
const frame_nv12_frag_spv align(@alignOf(u32)) = @embedFile("shaders/frame_nv12.frag.spv").*;
const color_vert_spv align(@alignOf(u32)) = @embedFile("shaders/color_sprite.vert.spv").*;
const color_frag_spv align(@alignOf(u32)) = @embedFile("shaders/color_sprite.frag.spv").*;
const polyline_vert_spv align(@alignOf(u32)) = @embedFile("shaders/polyline.vert.spv").*;
const polyline_frag_spv align(@alignOf(u32)) = @embedFile("shaders/polyline.frag.spv").*;
const line_vert_spv align(@alignOf(u32)) = @embedFile("shaders/line.vert.spv").*;
const line_frag_spv align(@alignOf(u32)) = @embedFile("shaders/line.frag.spv").*;
const ring_vert_spv align(@alignOf(u32)) = @embedFile("shaders/ring.vert.spv").*;
const ring_frag_spv align(@alignOf(u32)) = @embedFile("shaders/ring.frag.spv").*;

// What get_device() hands the atlas/text layers on this backend: enough of the
// renderer to allocate and upload GPU resources, never a bare VkDevice.
pub const DeviceContext = struct {
    device: *vk.Device,
    dfns: *const vk.DeviceFns,
    queue: *vk.Queue,
    upload_cmd: *vk.CommandBuffer,
    mem_props: vk.PhysicalDeviceMemoryProperties,

    pub fn find_memory_type(self: *const DeviceContext, type_bits: u32, wanted: u32) ?u32 {
        std.debug.assert(wanted != 0);
        std.debug.assert(self.mem_props.memory_type_count <= 32);
        var index: u32 = 0;
        while (index < self.mem_props.memory_type_count) : (index += 1) {
            const bit = @as(u32, 1) << @intCast(index);
            if (type_bits & bit == 0) continue;
            if (self.mem_props.memory_types[index].property_flags & wanted == wanted)
                return index;
        }
        return null;
    }
};

// Push-constant mirror of the HLSL FrameParams cbuffer plus the viewport the
// other vertex stages take: 112 bytes, inside the 128-byte push-constant floor
// every Vulkan device guarantees, so frames need no per-draw buffer traffic.
const FramePush = extern struct {
    viewport: [2]f32,
    _pad0: [2]f32 = .{ 0, 0 },
    bounds: [4]f32,
    clip_bounds: [4]f32,
    opacity_pad: [4]f32,
    csc: [3][4]f32,

    comptime {
        std.debug.assert(@sizeOf(FramePush) == 112);
        std.debug.assert(@offsetOf(FramePush, "csc") == 64);
    }
};

const SurfaceFormat = enum { bgra, nv12, shared_nv12 };

// "Shared" surfaces own no CPU pixels; the legacy field stays non-null so old
// pointer-shape checks cannot trip over this format (the d3d11 convention).
const shared_frame_pixel: u8 = 0;

const FramePlane = struct {
    image: vk.Image = vk.NULL_HANDLE,
    memory: vk.DeviceMemory = vk.NULL_HANDLE,
    view: vk.ImageView = vk.NULL_HANDLE,
};

const FrameSurfaceState = struct {
    luma: FramePlane = .{},
    chroma: FramePlane = .{},
    staging: vk.Buffer = vk.NULL_HANDLE,
    staging_memory: vk.DeviceMemory = vk.NULL_HANDLE,
    staging_mapped: ?[*]u8 = null,
    // The renderer that allocated the planes; deinit needs its device. A
    // surface must therefore be deinit'd before the renderer that fed it.
    renderer: ?*Renderer = null,
    uploaded: bool = false,
    // Owner + mailbox + GPU ring share this; producer writes only at owner ref.
    refs: std.atomic.Value(u32) = std.atomic.Value(u32).init(1),
};

// External frame surface (the d3d11 FrameSurface analogue). CPU-backed formats
// wrap caller pixels uploaded on import; shared_nv12 owns renderer-created
// planes filled through update_shared_nv12_surface. There is no cross-device
// handle on this backend, so "shared" keeps only the API name and semantics.
// Must not move after import: consumers hold pointers into state (the plane
// views and the refcount), so keep it at a stable address for its lifetime.
pub const FrameSurface = struct {
    format: SurfaceFormat,
    width: u32,
    height: u32,
    stride: u32,
    pixels: [*]const u8,
    chroma_stride: u32 = 0,
    chroma_pixels: ?[*]const u8 = null,
    state: FrameSurfaceState = .{},

    pub fn init_bgra(width: u32, height: u32, stride: u32, pixels: [*]const u8) FrameSurface {
        std.debug.assert(width > 0);
        std.debug.assert(height > 0);
        std.debug.assert(width <= MAX_FRAME_DIM);
        std.debug.assert(height <= MAX_FRAME_DIM);
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
        y_pixels: [*]const u8,
        uv_stride: u32,
        uv_pixels: [*]const u8,
    ) FrameSurface {
        std.debug.assert(width > 0);
        std.debug.assert(height > 0);
        std.debug.assert(width <= MAX_FRAME_DIM);
        std.debug.assert(height <= MAX_FRAME_DIM);
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

    pub fn available(self: *const FrameSurface) bool {
        std.debug.assert(self.state.refs.load(.acquire) >= 1);
        return self.state.refs.load(.acquire) == 1;
    }

    pub fn deinit(self: *FrameSurface) void {
        std.debug.assert(self.state.refs.load(.acquire) == 1);
        const r = self.state.renderer orelse return;
        const device = r.device orelse return;
        // Teardown-only path: drain the queue so no in-flight draw still
        // samples the planes being destroyed (the atlas deinit contract).
        _ = r.dfns.vkDeviceWaitIdle(device);
        destroy_frame_plane(r, &self.state.luma);
        destroy_frame_plane(r, &self.state.chroma);
        if (self.state.staging != vk.NULL_HANDLE)
            r.dfns.vkDestroyBuffer(device, self.state.staging, null);
        if (self.state.staging_memory != vk.NULL_HANDLE)
            r.dfns.vkFreeMemory(device, self.state.staging_memory, null);
        self.state.staging = vk.NULL_HANDLE;
        self.state.staging_memory = vk.NULL_HANDLE;
        self.state.staging_mapped = null;
        self.state.renderer = null;
    }
};

fn destroy_frame_plane(r: *Renderer, plane: *FramePlane) void {
    const device = r.device orelse return;
    if (plane.view != vk.NULL_HANDLE) r.dfns.vkDestroyImageView(device, plane.view, null);
    if (plane.image != vk.NULL_HANDLE) r.dfns.vkDestroyImage(device, plane.image, null);
    if (plane.memory != vk.NULL_HANDLE) r.dfns.vkFreeMemory(device, plane.memory, null);
    plane.* = .{};
}

// One instanced primitive class beyond the founding quad/text pair: its
// persistently mapped storage buffer, descriptors, and pipeline.
const PrimPipe = struct {
    pipeline: vk.Pipeline = vk.NULL_HANDLE,
    layout: vk.PipelineLayout = vk.NULL_HANDLE,
    dsl: vk.DescriptorSetLayout = vk.NULL_HANDLE,
    dset: vk.DescriptorSet = vk.NULL_HANDLE,
    buffer: vk.Buffer = vk.NULL_HANDLE,
    memory: vk.DeviceMemory = vk.NULL_HANDLE,
    mapped: ?[*]u8 = null,
};

pub const Renderer = struct {
    win: *shell.ShellWindow,
    instance: ?*vk.Instance = null,
    ifns: vk.InstanceFns = undefined,
    physical_device: ?*vk.PhysicalDevice = null,
    device: ?*vk.Device = null,
    dfns: vk.DeviceFns = undefined,
    queue: ?*vk.Queue = null,
    queue_family: u32 = 0,
    surface: vk.SurfaceKHR = vk.NULL_HANDLE,

    swapchain: vk.SwapchainKHR = vk.NULL_HANDLE,
    format: u32 = vk.FORMAT_B8G8R8A8_UNORM,
    color_space: u32 = vk.COLOR_SPACE_SRGB_NONLINEAR_KHR,
    images: [MAX_SWAPCHAIN_IMAGES]vk.Image = [_]vk.Image{vk.NULL_HANDLE} ** MAX_SWAPCHAIN_IMAGES,
    views: [MAX_SWAPCHAIN_IMAGES]vk.ImageView =
        [_]vk.ImageView{vk.NULL_HANDLE} ** MAX_SWAPCHAIN_IMAGES,
    framebuffers: [MAX_SWAPCHAIN_IMAGES]vk.Framebuffer =
        [_]vk.Framebuffer{vk.NULL_HANDLE} ** MAX_SWAPCHAIN_IMAGES,
    render_finished: [MAX_SWAPCHAIN_IMAGES]vk.Semaphore =
        [_]vk.Semaphore{vk.NULL_HANDLE} ** MAX_SWAPCHAIN_IMAGES,
    image_count: u32 = 0,
    extent: vk.Extent2D = .{ .width = 0, .height = 0 },

    render_pass: vk.RenderPass = vk.NULL_HANDLE,
    cmd_pool: vk.CommandPool = vk.NULL_HANDLE,
    cmd_buf: ?*vk.CommandBuffer = null,
    image_available: vk.Semaphore = vk.NULL_HANDLE,
    in_flight: vk.Fence = vk.NULL_HANDLE,

    quad_pipeline_layout: vk.PipelineLayout = vk.NULL_HANDLE,
    quad_pipeline: vk.Pipeline = vk.NULL_HANDLE,
    quad_dsl: vk.DescriptorSetLayout = vk.NULL_HANDLE,
    descriptor_pool: vk.DescriptorPool = vk.NULL_HANDLE,
    quad_dset: vk.DescriptorSet = vk.NULL_HANDLE,
    quad_buffer: vk.Buffer = vk.NULL_HANDLE,
    quad_memory: vk.DeviceMemory = vk.NULL_HANDLE,
    quad_mapped: ?[*]Quad = null,

    text_pipeline_layout: vk.PipelineLayout = vk.NULL_HANDLE,
    text_pipeline: vk.Pipeline = vk.NULL_HANDLE,
    text_dsl: vk.DescriptorSetLayout = vk.NULL_HANDLE,
    text_dset: vk.DescriptorSet = vk.NULL_HANDLE,
    sprite_buffer: vk.Buffer = vk.NULL_HANDLE,
    sprite_memory: vk.DeviceMemory = vk.NULL_HANDLE,
    sprite_mapped: ?[*]MonochromeSprite = null,
    sampler: vk.Sampler = vk.NULL_HANDLE,
    bound_atlas_view: vk.ImageView = vk.NULL_HANDLE,
    bound_color_view: vk.ImageView = vk.NULL_HANDLE,

    color_pipe: PrimPipe = .{},
    polyline_pipe: PrimPipe = .{},
    line_pipe: PrimPipe = .{},
    ring_pipe: PrimPipe = .{},

    frame_pipeline_layout: vk.PipelineLayout = vk.NULL_HANDLE,
    frame_pipeline: vk.Pipeline = vk.NULL_HANDLE,
    frame_nv12_pipeline: vk.Pipeline = vk.NULL_HANDLE,
    frame_dsl: vk.DescriptorSetLayout = vk.NULL_HANDLE,
    // One set per frame slot: each set is written then bound at most once per
    // recording, so updates never touch a set the command buffer already holds.
    frame_dsets: [MAX_FRAMES]vk.DescriptorSet = [_]vk.DescriptorSet{vk.NULL_HANDLE} ** MAX_FRAMES,

    upload_cmd: ?*vk.CommandBuffer = null,
    mem_props: vk.PhysicalDeviceMemoryProperties = undefined,
    device_ctx: DeviceContext = undefined,

    dirty: bool = true,

    pub const Error = error{
        LoaderMissing,
        SurfaceCreateFailed,
        DeviceCreateFailed,
        SwapchainCreateFailed,
        PipelineCreateFailed,
        BufferCreateFailed,
        SyncCreateFailed,
    };

    pub fn init(target: *anyopaque) Error!Renderer {
        // target is the ShellWindow behind CustomShellHandle.metal_layer.
        const win: *shell.ShellWindow = @ptrCast(@alignCast(target));
        std.debug.assert(win.in_use);
        std.debug.assert(win.surface != null);
        vk.load() catch return error.LoaderMissing;

        var self = Renderer{ .win = win };
        errdefer self.deinit();

        try self.create_instance();
        try self.create_surface();
        try self.pick_device();
        try self.create_device();
        try self.create_render_pass();
        try self.create_swapchain();
        try self.create_commands_and_sync();
        try self.build_quad_buffer();
        try self.build_quad_pipeline();
        try self.build_text_pipeline();
        try self.build_frame_pipelines();
        try self.build_prim_pipe(
            &self.color_pipe,
            PolychromeSprite,
            MAX_COLOR_SPRITES,
            &color_vert_spv,
            &color_frag_spv,
            true,
        );
        try self.build_prim_pipe(
            &self.polyline_pipe,
            Polyline,
            MAX_POLYLINES,
            &polyline_vert_spv,
            &polyline_frag_spv,
            false,
        );
        try self.build_prim_pipe(
            &self.line_pipe,
            LineSegment,
            MAX_LINES,
            &line_vert_spv,
            &line_frag_spv,
            false,
        );
        try self.build_prim_pipe(
            &self.ring_pipe,
            RingChart,
            MAX_RINGS,
            &ring_vert_spv,
            &ring_frag_spv,
            false,
        );

        shell.renderer_takeover(win);
        return self;
    }

    pub fn deinit(self: *Renderer) void {
        const device = self.device orelse {
            self.destroy_pre_device();
            return;
        };
        _ = self.dfns.vkDeviceWaitIdle(device);
        self.destroy_swapchain_objects();
        if (self.swapchain != vk.NULL_HANDLE)
            self.dfns.vkDestroySwapchainKHR(device, self.swapchain, null);
        if (self.quad_pipeline != vk.NULL_HANDLE)
            self.dfns.vkDestroyPipeline(device, self.quad_pipeline, null);
        if (self.quad_pipeline_layout != vk.NULL_HANDLE)
            self.dfns.vkDestroyPipelineLayout(device, self.quad_pipeline_layout, null);
        if (self.descriptor_pool != vk.NULL_HANDLE)
            self.dfns.vkDestroyDescriptorPool(device, self.descriptor_pool, null);
        if (self.quad_dsl != vk.NULL_HANDLE)
            self.dfns.vkDestroyDescriptorSetLayout(device, self.quad_dsl, null);
        if (self.quad_buffer != vk.NULL_HANDLE)
            self.dfns.vkDestroyBuffer(device, self.quad_buffer, null);
        if (self.quad_memory != vk.NULL_HANDLE)
            self.dfns.vkFreeMemory(device, self.quad_memory, null);
        if (self.text_pipeline != vk.NULL_HANDLE)
            self.dfns.vkDestroyPipeline(device, self.text_pipeline, null);
        if (self.text_pipeline_layout != vk.NULL_HANDLE)
            self.dfns.vkDestroyPipelineLayout(device, self.text_pipeline_layout, null);
        if (self.text_dsl != vk.NULL_HANDLE)
            self.dfns.vkDestroyDescriptorSetLayout(device, self.text_dsl, null);
        self.destroy_prim_pipe(&self.color_pipe);
        self.destroy_prim_pipe(&self.polyline_pipe);
        self.destroy_prim_pipe(&self.line_pipe);
        self.destroy_prim_pipe(&self.ring_pipe);
        if (self.frame_pipeline != vk.NULL_HANDLE)
            self.dfns.vkDestroyPipeline(device, self.frame_pipeline, null);
        if (self.frame_nv12_pipeline != vk.NULL_HANDLE)
            self.dfns.vkDestroyPipeline(device, self.frame_nv12_pipeline, null);
        if (self.frame_pipeline_layout != vk.NULL_HANDLE)
            self.dfns.vkDestroyPipelineLayout(device, self.frame_pipeline_layout, null);
        if (self.frame_dsl != vk.NULL_HANDLE)
            self.dfns.vkDestroyDescriptorSetLayout(device, self.frame_dsl, null);
        if (self.sprite_buffer != vk.NULL_HANDLE)
            self.dfns.vkDestroyBuffer(device, self.sprite_buffer, null);
        if (self.sprite_memory != vk.NULL_HANDLE)
            self.dfns.vkFreeMemory(device, self.sprite_memory, null);
        if (self.sampler != vk.NULL_HANDLE)
            self.dfns.vkDestroySampler(device, self.sampler, null);
        if (self.image_available != vk.NULL_HANDLE)
            self.dfns.vkDestroySemaphore(device, self.image_available, null);
        if (self.in_flight != vk.NULL_HANDLE)
            self.dfns.vkDestroyFence(device, self.in_flight, null);
        if (self.cmd_pool != vk.NULL_HANDLE)
            self.dfns.vkDestroyCommandPool(device, self.cmd_pool, null);
        if (self.render_pass != vk.NULL_HANDLE)
            self.dfns.vkDestroyRenderPass(device, self.render_pass, null);
        self.dfns.vkDestroyDevice(device, null);
        self.device = null;
        self.destroy_pre_device();
    }

    fn destroy_pre_device(self: *Renderer) void {
        const instance = self.instance orelse return;
        if (self.surface != vk.NULL_HANDLE) {
            self.ifns.vkDestroySurfaceKHR(instance, self.surface, null);
            self.surface = vk.NULL_HANDLE;
        }
        self.ifns.vkDestroyInstance(instance, null);
        self.instance = null;
    }

    fn destroy_swapchain_objects(self: *Renderer) void {
        const device = self.device orelse return;
        std.debug.assert(self.image_count <= MAX_SWAPCHAIN_IMAGES);
        var index: u32 = 0;
        while (index < self.image_count) : (index += 1) {
            if (self.framebuffers[index] != vk.NULL_HANDLE)
                self.dfns.vkDestroyFramebuffer(device, self.framebuffers[index], null);
            if (self.views[index] != vk.NULL_HANDLE)
                self.dfns.vkDestroyImageView(device, self.views[index], null);
            if (self.render_finished[index] != vk.NULL_HANDLE)
                self.dfns.vkDestroySemaphore(device, self.render_finished[index], null);
            self.framebuffers[index] = vk.NULL_HANDLE;
            self.views[index] = vk.NULL_HANDLE;
            self.render_finished[index] = vk.NULL_HANDLE;
        }
        self.image_count = 0;
    }

    fn create_instance(self: *Renderer) Error!void {
        std.debug.assert(self.instance == null);
        const extensions = [_][*:0]const u8{ "VK_KHR_surface", "VK_KHR_wayland_surface" };
        const app_info = vk.ApplicationInfo{ .application_name = "zigui" };
        const info = vk.InstanceCreateInfo{
            .application_info = &app_info,
            .enabled_extension_count = extensions.len,
            .enabled_extension_names = &extensions,
        };
        var instance: *vk.Instance = undefined;
        if (vk.global.vkCreateInstance(&info, null, &instance) != vk.SUCCESS)
            return error.DeviceCreateFailed;
        self.instance = instance;
        vk.load_instance_fns(instance, &self.ifns) catch return error.LoaderMissing;
    }

    fn create_surface(self: *Renderer) Error!void {
        std.debug.assert(self.instance != null);
        std.debug.assert(self.surface == vk.NULL_HANDLE);
        const display = wl.conn.display orelse return error.SurfaceCreateFailed;
        const info = vk.WaylandSurfaceCreateInfoKHR{
            .display = @ptrCast(display),
            .surface = @ptrCast(self.win.surface.?),
        };
        const rc = self.ifns.vkCreateWaylandSurfaceKHR(self.instance.?, &info, null, &self.surface);
        if (rc != vk.SUCCESS) return error.SurfaceCreateFailed;
    }

    // First device with a graphics queue that can present to the surface; no
    // discrete-vs-integrated ranking until a machine shows it matters.
    fn pick_device(self: *Renderer) Error!void {
        std.debug.assert(self.instance != null);
        var count: u32 = MAX_PHYSICAL_DEVICES;
        var devices: [MAX_PHYSICAL_DEVICES]*vk.PhysicalDevice = undefined;
        const rc = self.ifns.vkEnumeratePhysicalDevices(self.instance.?, &count, &devices);
        if (rc != vk.SUCCESS or count == 0) return error.DeviceCreateFailed;
        std.debug.assert(count <= MAX_PHYSICAL_DEVICES);
        var device_index: u32 = 0;
        while (device_index < count) : (device_index += 1) {
            const candidate = devices[device_index];
            if (self.graphics_present_family(candidate)) |family| {
                self.physical_device = candidate;
                self.queue_family = family;
                return;
            }
        }
        return error.DeviceCreateFailed;
    }

    fn graphics_present_family(self: *Renderer, device: *vk.PhysicalDevice) ?u32 {
        std.debug.assert(self.surface != vk.NULL_HANDLE);
        var count: u32 = MAX_QUEUE_FAMILIES;
        var families: [MAX_QUEUE_FAMILIES]vk.QueueFamilyProperties = undefined;
        self.ifns.vkGetPhysicalDeviceQueueFamilyProperties(device, &count, &families);
        std.debug.assert(count <= MAX_QUEUE_FAMILIES);
        var index: u32 = 0;
        while (index < count) : (index += 1) {
            if (families[index].queue_flags & vk.QUEUE_GRAPHICS_BIT == 0) continue;
            var supported: vk.Bool32 = 0;
            const rc = self.ifns.vkGetPhysicalDeviceSurfaceSupportKHR(
                device,
                index,
                self.surface,
                &supported,
            );
            if (rc == vk.SUCCESS and supported == 1) return index;
        }
        return null;
    }

    fn create_device(self: *Renderer) Error!void {
        std.debug.assert(self.physical_device != null);
        std.debug.assert(self.device == null);
        const priorities = [_]f32{1.0};
        const queue_info = vk.DeviceQueueCreateInfo{
            .queue_family_index = self.queue_family,
            .queue_priorities = &priorities,
        };
        const extensions = [_][*:0]const u8{"VK_KHR_swapchain"};
        // Per-instance clip rects ride on gl_ClipDistance, an opt-in feature.
        const features = vk.PhysicalDeviceFeatures{ .shader_clip_distance = 1 };
        const info = vk.DeviceCreateInfo{
            .queue_create_infos = @ptrCast(&queue_info),
            .enabled_extension_count = extensions.len,
            .enabled_extension_names = &extensions,
            .enabled_features = &features,
        };
        var device: *vk.Device = undefined;
        const rc = self.ifns.vkCreateDevice(self.physical_device.?, &info, null, &device);
        if (rc != vk.SUCCESS) return error.DeviceCreateFailed;
        self.device = device;
        vk.load_device_fns(device, self.ifns.vkGetDeviceProcAddr, &self.dfns) catch
            return error.LoaderMissing;
        var queue: *vk.Queue = undefined;
        self.dfns.vkGetDeviceQueue(device, self.queue_family, 0, &queue);
        self.queue = queue;
        self.ifns.vkGetPhysicalDeviceMemoryProperties(self.physical_device.?, &self.mem_props);
    }

    fn create_render_pass(self: *Renderer) Error!void {
        std.debug.assert(self.device != null);
        std.debug.assert(self.render_pass == vk.NULL_HANDLE);
        const attachment = vk.AttachmentDescription{
            .format = self.format,
            .load_op = vk.ATTACHMENT_LOAD_OP_CLEAR,
            .store_op = vk.ATTACHMENT_STORE_OP_STORE,
            .initial_layout = vk.IMAGE_LAYOUT_UNDEFINED,
            .final_layout = vk.IMAGE_LAYOUT_PRESENT_SRC_KHR,
        };
        const color_ref = vk.AttachmentReference{};
        const subpass = vk.SubpassDescription{ .color_attachments = @ptrCast(&color_ref) };
        const dependency = vk.SubpassDependency{};
        const info = vk.RenderPassCreateInfo{
            .attachments = @ptrCast(&attachment),
            .subpasses = @ptrCast(&subpass),
            .dependencies = @ptrCast(&dependency),
        };
        const rc = self.dfns.vkCreateRenderPass(self.device.?, &info, null, &self.render_pass);
        if (rc != vk.SUCCESS) return error.SwapchainCreateFailed;
    }

    fn surface_extent(self: *Renderer, caps: vk.SurfaceCapabilitiesKHR) vk.Extent2D {
        // 0xFFFFFFFF means the surface size is whatever the client picks; the
        // shell's configured size is the truth (buffer scale 1).
        if (caps.current_extent.width != 0xFFFFFFFF) return caps.current_extent;
        const w: u32 = @intCast(@max(self.win.width_pt, 1));
        const h: u32 = @intCast(@max(self.win.height_pt, 1));
        return .{
            .width = std.math.clamp(w, caps.min_image_extent.width, caps.max_image_extent.width),
            .height = std.math.clamp(h, caps.min_image_extent.height, caps.max_image_extent.height),
        };
    }

    fn create_swapchain(self: *Renderer) Error!void {
        std.debug.assert(self.device != null);
        std.debug.assert(self.surface != vk.NULL_HANDLE);
        var caps: vk.SurfaceCapabilitiesKHR = undefined;
        const caps_rc = self.ifns.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(
            self.physical_device.?,
            self.surface,
            &caps,
        );
        if (caps_rc != vk.SUCCESS) return error.SwapchainCreateFailed;
        self.extent = self.surface_extent(caps);

        var image_count: u32 = caps.min_image_count + 1;
        if (caps.max_image_count > 0 and image_count > caps.max_image_count)
            image_count = caps.max_image_count;
        const old = self.swapchain;
        const info = vk.SwapchainCreateInfoKHR{
            .surface = self.surface,
            .min_image_count = image_count,
            .image_format = self.format,
            .image_color_space = self.color_space,
            .image_extent = self.extent,
            .pre_transform = caps.current_transform,
            .old_swapchain = old,
        };
        var swapchain: vk.SwapchainKHR = vk.NULL_HANDLE;
        if (self.dfns.vkCreateSwapchainKHR(self.device.?, &info, null, &swapchain) != vk.SUCCESS)
            return error.SwapchainCreateFailed;
        if (old != vk.NULL_HANDLE) self.dfns.vkDestroySwapchainKHR(self.device.?, old, null);
        self.swapchain = swapchain;
        try self.create_swapchain_objects();
    }

    fn create_swapchain_objects(self: *Renderer) Error!void {
        std.debug.assert(self.swapchain != vk.NULL_HANDLE);
        std.debug.assert(self.image_count == 0);
        var count: u32 = MAX_SWAPCHAIN_IMAGES;
        const rc = self.dfns.vkGetSwapchainImagesKHR(
            self.device.?,
            self.swapchain,
            &count,
            &self.images,
        );
        if (rc != vk.SUCCESS or count == 0) return error.SwapchainCreateFailed;
        std.debug.assert(count <= MAX_SWAPCHAIN_IMAGES);
        var index: u32 = 0;
        while (index < count) : (index += 1) {
            const view_info = vk.ImageViewCreateInfo{
                .image = self.images[index],
                .format = self.format,
            };
            var ok = self.dfns.vkCreateImageView(
                self.device.?,
                &view_info,
                null,
                &self.views[index],
            );
            if (ok != vk.SUCCESS) return error.SwapchainCreateFailed;
            const fb_info = vk.FramebufferCreateInfo{
                .render_pass = self.render_pass,
                .attachments = @ptrCast(&self.views[index]),
                .width = self.extent.width,
                .height = self.extent.height,
            };
            ok = self.dfns.vkCreateFramebuffer(
                self.device.?,
                &fb_info,
                null,
                &self.framebuffers[index],
            );
            if (ok != vk.SUCCESS) return error.SwapchainCreateFailed;
            const sem_info = vk.SemaphoreCreateInfo{};
            ok = self.dfns.vkCreateSemaphore(
                self.device.?,
                &sem_info,
                null,
                &self.render_finished[index],
            );
            if (ok != vk.SUCCESS) return error.SwapchainCreateFailed;
            self.image_count = index + 1;
        }
    }

    fn recreate_swapchain(self: *Renderer) Error!void {
        std.debug.assert(self.device != null);
        _ = self.dfns.vkDeviceWaitIdle(self.device.?);
        self.destroy_swapchain_objects();
        try self.create_swapchain();
    }

    fn create_commands_and_sync(self: *Renderer) Error!void {
        std.debug.assert(self.device != null);
        const pool_info = vk.CommandPoolCreateInfo{ .queue_family_index = self.queue_family };
        if (self.dfns.vkCreateCommandPool(self.device.?, &pool_info, null, &self.cmd_pool) !=
            vk.SUCCESS) return error.SyncCreateFailed;
        const alloc_info = vk.CommandBufferAllocateInfo{
            .command_pool = self.cmd_pool,
            .command_buffer_count = 2,
        };
        var cmd_bufs: [2]*vk.CommandBuffer = undefined;
        if (self.dfns.vkAllocateCommandBuffers(self.device.?, &alloc_info, &cmd_bufs) !=
            vk.SUCCESS) return error.SyncCreateFailed;
        self.cmd_buf = cmd_bufs[0];
        self.upload_cmd = cmd_bufs[1];
        const sem_info = vk.SemaphoreCreateInfo{};
        if (self.dfns.vkCreateSemaphore(self.device.?, &sem_info, null, &self.image_available) !=
            vk.SUCCESS) return error.SyncCreateFailed;
        const fence_info = vk.FenceCreateInfo{};
        if (self.dfns.vkCreateFence(self.device.?, &fence_info, null, &self.in_flight) !=
            vk.SUCCESS) return error.SyncCreateFailed;
    }

    fn find_memory_type(self: *Renderer, type_bits: u32, wanted: u32) ?u32 {
        std.debug.assert(self.mem_props.memory_type_count <= 32);
        var index: u32 = 0;
        while (index < self.mem_props.memory_type_count) : (index += 1) {
            const bit = @as(u32, 1) << @intCast(index);
            if (type_bits & bit == 0) continue;
            if (self.mem_props.memory_types[index].property_flags & wanted == wanted)
                return index;
        }
        return null;
    }

    // One persistently mapped host-visible buffer; 1024 quads x 112B = 112KiB,
    // allocated once at init, written in place each frame.
    fn build_quad_buffer(self: *Renderer) Error!void {
        std.debug.assert(self.device != null);
        std.debug.assert(self.quad_buffer == vk.NULL_HANDLE);
        const size: vk.DeviceSize = @sizeOf(Quad) * MAX_QUADS;
        const info = vk.BufferCreateInfo{
            .size = size,
            .usage = vk.BUFFER_USAGE_STORAGE_BUFFER_BIT,
        };
        if (self.dfns.vkCreateBuffer(self.device.?, &info, null, &self.quad_buffer) != vk.SUCCESS)
            return error.BufferCreateFailed;
        var requirements: vk.MemoryRequirements = undefined;
        self.dfns.vkGetBufferMemoryRequirements(self.device.?, self.quad_buffer, &requirements);
        const wanted = vk.MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.MEMORY_PROPERTY_HOST_COHERENT_BIT;
        const type_index = self.find_memory_type(requirements.memory_type_bits, wanted) orelse
            return error.BufferCreateFailed;
        const alloc = vk.MemoryAllocateInfo{
            .allocation_size = requirements.size,
            .memory_type_index = type_index,
        };
        if (self.dfns.vkAllocateMemory(self.device.?, &alloc, null, &self.quad_memory) !=
            vk.SUCCESS) return error.BufferCreateFailed;
        if (self.dfns.vkBindBufferMemory(self.device.?, self.quad_buffer, self.quad_memory, 0) !=
            vk.SUCCESS) return error.BufferCreateFailed;
        var mapped: *anyopaque = undefined;
        if (self.dfns.vkMapMemory(self.device.?, self.quad_memory, 0, size, 0, &mapped) !=
            vk.SUCCESS) return error.BufferCreateFailed;
        self.quad_mapped = @ptrCast(@alignCast(mapped));
    }

    fn make_shader_module(self: *Renderer, code: []const u8) Error!vk.ShaderModule {
        std.debug.assert(code.len % 4 == 0);
        std.debug.assert(code.len > 0);
        const info = vk.ShaderModuleCreateInfo{
            .code_size = code.len,
            .code = @ptrCast(@alignCast(code.ptr)),
        };
        var module: vk.ShaderModule = vk.NULL_HANDLE;
        if (self.dfns.vkCreateShaderModule(self.device.?, &info, null, &module) != vk.SUCCESS)
            return error.PipelineCreateFailed;
        return module;
    }

    fn build_quad_descriptors(self: *Renderer) Error!void {
        std.debug.assert(self.quad_buffer != vk.NULL_HANDLE);
        const binding = vk.DescriptorSetLayoutBinding{
            .binding = 0,
            .descriptor_type = vk.DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .stage_flags = vk.SHADER_STAGE_VERTEX_BIT,
        };
        const dsl_info = vk.DescriptorSetLayoutCreateInfo{
            .binding_count = 1,
            .bindings = @ptrCast(&binding),
        };
        if (self.dfns.vkCreateDescriptorSetLayout(self.device.?, &dsl_info, null, &self.quad_dsl) !=
            vk.SUCCESS) return error.PipelineCreateFailed;
        // Storage buffers: quad + text + the four PrimPipe classes. Samplers:
        // the mono and color atlases plus two (luma + chroma) per frame set.
        const pool_sizes = [_]vk.DescriptorPoolSize{
            .{ .descriptor_type = vk.DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptor_count = 6 },
            .{
                .descriptor_type = vk.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                .descriptor_count = 2 + 2 * MAX_FRAMES,
            },
        };
        const pool_info = vk.DescriptorPoolCreateInfo{
            .max_sets = 6 + MAX_FRAMES,
            .pool_size_count = pool_sizes.len,
            .pool_sizes = &pool_sizes,
        };
        const pool_rc = self.dfns.vkCreateDescriptorPool(
            self.device.?,
            &pool_info,
            null,
            &self.descriptor_pool,
        );
        if (pool_rc != vk.SUCCESS) return error.PipelineCreateFailed;
        const set_info = vk.DescriptorSetAllocateInfo{
            .descriptor_pool = self.descriptor_pool,
            .set_layouts = @ptrCast(&self.quad_dsl),
        };
        const set_rc = self.dfns.vkAllocateDescriptorSets(
            self.device.?,
            &set_info,
            @ptrCast(&self.quad_dset),
        );
        if (set_rc != vk.SUCCESS) return error.PipelineCreateFailed;
        const buffer_info = vk.DescriptorBufferInfo{
            .buffer = self.quad_buffer,
            .range = @sizeOf(Quad) * MAX_QUADS,
        };
        const write = vk.WriteDescriptorSet{
            .dst_set = self.quad_dset,
            .dst_binding = 0,
            .descriptor_type = vk.DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .buffer_info = @ptrCast(&buffer_info),
        };
        self.dfns.vkUpdateDescriptorSets(self.device.?, 1, @ptrCast(&write), 0, null);
    }

    fn build_quad_pipeline(self: *Renderer) Error!void {
        std.debug.assert(self.render_pass != vk.NULL_HANDLE);
        std.debug.assert(self.quad_pipeline == vk.NULL_HANDLE);
        try self.build_quad_descriptors();

        const vert = try self.make_shader_module(&quad_vert_spv);
        defer self.dfns.vkDestroyShaderModule(self.device.?, vert, null);
        const frag = try self.make_shader_module(&quad_frag_spv);
        defer self.dfns.vkDestroyShaderModule(self.device.?, frag, null);

        const push_range = vk.PushConstantRange{
            .stage_flags = vk.SHADER_STAGE_VERTEX_BIT,
            .size = 8, // vec2 viewport_size in points
        };
        const layout_info = vk.PipelineLayoutCreateInfo{
            .set_layout_count = 1,
            .set_layouts = @ptrCast(&self.quad_dsl),
            .push_constant_range_count = 1,
            .push_constant_ranges = @ptrCast(&push_range),
        };
        const layout_rc = self.dfns.vkCreatePipelineLayout(
            self.device.?,
            &layout_info,
            null,
            &self.quad_pipeline_layout,
        );
        if (layout_rc != vk.SUCCESS) return error.PipelineCreateFailed;
        self.quad_pipeline = try self.make_pipeline(vert, frag, self.quad_pipeline_layout);
    }

    fn build_sprite_buffer(self: *Renderer) Error!void {
        std.debug.assert(self.device != null);
        std.debug.assert(self.sprite_buffer == vk.NULL_HANDLE);
        const size: vk.DeviceSize = @sizeOf(MonochromeSprite) * MAX_SPRITES;
        const info = vk.BufferCreateInfo{
            .size = size,
            .usage = vk.BUFFER_USAGE_STORAGE_BUFFER_BIT,
        };
        if (self.dfns.vkCreateBuffer(self.device.?, &info, null, &self.sprite_buffer) !=
            vk.SUCCESS) return error.BufferCreateFailed;
        var requirements: vk.MemoryRequirements = undefined;
        self.dfns.vkGetBufferMemoryRequirements(self.device.?, self.sprite_buffer, &requirements);
        const wanted = vk.MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.MEMORY_PROPERTY_HOST_COHERENT_BIT;
        const type_index = self.find_memory_type(requirements.memory_type_bits, wanted) orelse
            return error.BufferCreateFailed;
        const alloc = vk.MemoryAllocateInfo{
            .allocation_size = requirements.size,
            .memory_type_index = type_index,
        };
        if (self.dfns.vkAllocateMemory(self.device.?, &alloc, null, &self.sprite_memory) !=
            vk.SUCCESS) return error.BufferCreateFailed;
        if (self.dfns.vkBindBufferMemory(
            self.device.?,
            self.sprite_buffer,
            self.sprite_memory,
            0,
        ) != vk.SUCCESS) return error.BufferCreateFailed;
        var mapped: *anyopaque = undefined;
        if (self.dfns.vkMapMemory(self.device.?, self.sprite_memory, 0, size, 0, &mapped) !=
            vk.SUCCESS) return error.BufferCreateFailed;
        self.sprite_mapped = @ptrCast(@alignCast(mapped));
    }

    fn build_text_descriptors(self: *Renderer) Error!void {
        std.debug.assert(self.sprite_buffer != vk.NULL_HANDLE);
        std.debug.assert(self.descriptor_pool != vk.NULL_HANDLE);
        const bindings = [_]vk.DescriptorSetLayoutBinding{
            .{
                .binding = 0,
                .descriptor_type = vk.DESCRIPTOR_TYPE_STORAGE_BUFFER,
                .stage_flags = vk.SHADER_STAGE_VERTEX_BIT,
            },
            .{
                .binding = 1,
                .descriptor_type = vk.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                .stage_flags = vk.SHADER_STAGE_FRAGMENT_BIT,
            },
        };
        const dsl_info = vk.DescriptorSetLayoutCreateInfo{
            .binding_count = bindings.len,
            .bindings = &bindings,
        };
        if (self.dfns.vkCreateDescriptorSetLayout(self.device.?, &dsl_info, null, &self.text_dsl) !=
            vk.SUCCESS) return error.PipelineCreateFailed;
        const set_info = vk.DescriptorSetAllocateInfo{
            .descriptor_pool = self.descriptor_pool,
            .set_layouts = @ptrCast(&self.text_dsl),
        };
        const set_rc = self.dfns.vkAllocateDescriptorSets(
            self.device.?,
            &set_info,
            @ptrCast(&self.text_dset),
        );
        if (set_rc != vk.SUCCESS) return error.PipelineCreateFailed;
        const buffer_info = vk.DescriptorBufferInfo{
            .buffer = self.sprite_buffer,
            .range = @sizeOf(MonochromeSprite) * MAX_SPRITES,
        };
        const write = vk.WriteDescriptorSet{
            .dst_set = self.text_dset,
            .dst_binding = 0,
            .descriptor_type = vk.DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .buffer_info = @ptrCast(&buffer_info),
        };
        self.dfns.vkUpdateDescriptorSets(self.device.?, 1, @ptrCast(&write), 0, null);
    }

    fn build_text_pipeline(self: *Renderer) Error!void {
        std.debug.assert(self.render_pass != vk.NULL_HANDLE);
        std.debug.assert(self.text_pipeline == vk.NULL_HANDLE);
        try self.build_sprite_buffer();
        try self.build_text_descriptors();

        const sampler_info = vk.SamplerCreateInfo{};
        if (self.dfns.vkCreateSampler(self.device.?, &sampler_info, null, &self.sampler) !=
            vk.SUCCESS) return error.PipelineCreateFailed;

        const vert = try self.make_shader_module(&text_vert_spv);
        defer self.dfns.vkDestroyShaderModule(self.device.?, vert, null);
        const frag = try self.make_shader_module(&text_frag_spv);
        defer self.dfns.vkDestroyShaderModule(self.device.?, frag, null);

        const push_range = vk.PushConstantRange{
            .stage_flags = vk.SHADER_STAGE_VERTEX_BIT,
            .size = 8,
        };
        const layout_info = vk.PipelineLayoutCreateInfo{
            .set_layout_count = 1,
            .set_layouts = @ptrCast(&self.text_dsl),
            .push_constant_range_count = 1,
            .push_constant_ranges = @ptrCast(&push_range),
        };
        const layout_rc = self.dfns.vkCreatePipelineLayout(
            self.device.?,
            &layout_info,
            null,
            &self.text_pipeline_layout,
        );
        if (layout_rc != vk.SUCCESS) return error.PipelineCreateFailed;
        self.text_pipeline = try self.make_pipeline(vert, frag, self.text_pipeline_layout);
    }

    fn build_frame_descriptors(self: *Renderer) Error!void {
        std.debug.assert(self.descriptor_pool != vk.NULL_HANDLE);
        std.debug.assert(self.frame_dsl == vk.NULL_HANDLE);
        const bindings = [_]vk.DescriptorSetLayoutBinding{
            .{
                .binding = 0,
                .descriptor_type = vk.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                .stage_flags = vk.SHADER_STAGE_FRAGMENT_BIT,
            },
            .{
                .binding = 1,
                .descriptor_type = vk.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                .stage_flags = vk.SHADER_STAGE_FRAGMENT_BIT,
            },
        };
        const dsl_info = vk.DescriptorSetLayoutCreateInfo{
            .binding_count = bindings.len,
            .bindings = &bindings,
        };
        const dsl_rc = self.dfns.vkCreateDescriptorSetLayout(
            self.device.?,
            &dsl_info,
            null,
            &self.frame_dsl,
        );
        if (dsl_rc != vk.SUCCESS) return error.PipelineCreateFailed;
        const layouts = [_]vk.DescriptorSetLayout{self.frame_dsl} ** MAX_FRAMES;
        const set_info = vk.DescriptorSetAllocateInfo{
            .descriptor_pool = self.descriptor_pool,
            .descriptor_set_count = MAX_FRAMES,
            .set_layouts = &layouts,
        };
        const set_rc = self.dfns.vkAllocateDescriptorSets(
            self.device.?,
            &set_info,
            &self.frame_dsets,
        );
        if (set_rc != vk.SUCCESS) return error.PipelineCreateFailed;
    }

    fn build_frame_pipelines(self: *Renderer) Error!void {
        std.debug.assert(self.render_pass != vk.NULL_HANDLE);
        std.debug.assert(self.frame_pipeline == vk.NULL_HANDLE);
        try self.build_frame_descriptors();

        const vert = try self.make_shader_module(&frame_vert_spv);
        defer self.dfns.vkDestroyShaderModule(self.device.?, vert, null);
        const frag_rgba = try self.make_shader_module(&frame_rgba_frag_spv);
        defer self.dfns.vkDestroyShaderModule(self.device.?, frag_rgba, null);
        const frag_nv12 = try self.make_shader_module(&frame_nv12_frag_spv);
        defer self.dfns.vkDestroyShaderModule(self.device.?, frag_nv12, null);

        // One range over the whole 112-byte block: the vertex stage reads the
        // geometry half, the fragment stage the opacity + CSC half.
        const push_range = vk.PushConstantRange{
            .stage_flags = vk.SHADER_STAGE_VERTEX_BIT | vk.SHADER_STAGE_FRAGMENT_BIT,
            .size = @sizeOf(FramePush),
        };
        const layout_info = vk.PipelineLayoutCreateInfo{
            .set_layout_count = 1,
            .set_layouts = @ptrCast(&self.frame_dsl),
            .push_constant_range_count = 1,
            .push_constant_ranges = @ptrCast(&push_range),
        };
        const layout_rc = self.dfns.vkCreatePipelineLayout(
            self.device.?,
            &layout_info,
            null,
            &self.frame_pipeline_layout,
        );
        if (layout_rc != vk.SUCCESS) return error.PipelineCreateFailed;
        self.frame_pipeline = try self.make_pipeline(vert, frag_rgba, self.frame_pipeline_layout);
        self.frame_nv12_pipeline = try self.make_pipeline(
            vert,
            frag_nv12,
            self.frame_pipeline_layout,
        );
    }

    fn destroy_prim_pipe(self: *Renderer, pipe: *PrimPipe) void {
        const device = self.device orelse return;
        if (pipe.pipeline != vk.NULL_HANDLE)
            self.dfns.vkDestroyPipeline(device, pipe.pipeline, null);
        if (pipe.layout != vk.NULL_HANDLE)
            self.dfns.vkDestroyPipelineLayout(device, pipe.layout, null);
        if (pipe.dsl != vk.NULL_HANDLE)
            self.dfns.vkDestroyDescriptorSetLayout(device, pipe.dsl, null);
        if (pipe.buffer != vk.NULL_HANDLE)
            self.dfns.vkDestroyBuffer(device, pipe.buffer, null);
        if (pipe.memory != vk.NULL_HANDLE)
            self.dfns.vkFreeMemory(device, pipe.memory, null);
        pipe.* = .{};
    }

    fn build_prim_buffer(self: *Renderer, pipe: *PrimPipe, size: vk.DeviceSize) Error!void {
        std.debug.assert(self.device != null);
        std.debug.assert(pipe.buffer == vk.NULL_HANDLE);
        const info = vk.BufferCreateInfo{
            .size = size,
            .usage = vk.BUFFER_USAGE_STORAGE_BUFFER_BIT,
        };
        if (self.dfns.vkCreateBuffer(self.device.?, &info, null, &pipe.buffer) != vk.SUCCESS)
            return error.BufferCreateFailed;
        var requirements: vk.MemoryRequirements = undefined;
        self.dfns.vkGetBufferMemoryRequirements(self.device.?, pipe.buffer, &requirements);
        const wanted = vk.MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.MEMORY_PROPERTY_HOST_COHERENT_BIT;
        const type_index = self.find_memory_type(requirements.memory_type_bits, wanted) orelse
            return error.BufferCreateFailed;
        const alloc = vk.MemoryAllocateInfo{
            .allocation_size = requirements.size,
            .memory_type_index = type_index,
        };
        if (self.dfns.vkAllocateMemory(self.device.?, &alloc, null, &pipe.memory) != vk.SUCCESS)
            return error.BufferCreateFailed;
        if (self.dfns.vkBindBufferMemory(self.device.?, pipe.buffer, pipe.memory, 0) != vk.SUCCESS)
            return error.BufferCreateFailed;
        var mapped: *anyopaque = undefined;
        if (self.dfns.vkMapMemory(self.device.?, pipe.memory, 0, size, 0, &mapped) != vk.SUCCESS)
            return error.BufferCreateFailed;
        pipe.mapped = @ptrCast(@alignCast(mapped));
    }

    fn build_prim_descriptors(
        self: *Renderer,
        pipe: *PrimPipe,
        size: vk.DeviceSize,
        with_sampler: bool,
    ) Error!void {
        std.debug.assert(pipe.buffer != vk.NULL_HANDLE);
        std.debug.assert(self.descriptor_pool != vk.NULL_HANDLE);
        const bindings = [_]vk.DescriptorSetLayoutBinding{
            .{
                .binding = 0,
                .descriptor_type = vk.DESCRIPTOR_TYPE_STORAGE_BUFFER,
                .stage_flags = vk.SHADER_STAGE_VERTEX_BIT,
            },
            .{
                .binding = 1,
                .descriptor_type = vk.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                .stage_flags = vk.SHADER_STAGE_FRAGMENT_BIT,
            },
        };
        const dsl_info = vk.DescriptorSetLayoutCreateInfo{
            .binding_count = if (with_sampler) bindings.len else 1,
            .bindings = &bindings,
        };
        if (self.dfns.vkCreateDescriptorSetLayout(self.device.?, &dsl_info, null, &pipe.dsl) !=
            vk.SUCCESS) return error.PipelineCreateFailed;
        const set_info = vk.DescriptorSetAllocateInfo{
            .descriptor_pool = self.descriptor_pool,
            .set_layouts = @ptrCast(&pipe.dsl),
        };
        if (self.dfns.vkAllocateDescriptorSets(self.device.?, &set_info, @ptrCast(&pipe.dset)) !=
            vk.SUCCESS) return error.PipelineCreateFailed;
        const buffer_info = vk.DescriptorBufferInfo{ .buffer = pipe.buffer, .range = size };
        const write = vk.WriteDescriptorSet{
            .dst_set = pipe.dset,
            .dst_binding = 0,
            .descriptor_type = vk.DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .buffer_info = @ptrCast(&buffer_info),
        };
        self.dfns.vkUpdateDescriptorSets(self.device.?, 1, @ptrCast(&write), 0, null);
    }

    fn build_prim_pipe(
        self: *Renderer,
        pipe: *PrimPipe,
        comptime T: type,
        max: u32,
        vert_code: []const u8,
        frag_code: []const u8,
        with_sampler: bool,
    ) Error!void {
        std.debug.assert(pipe.pipeline == vk.NULL_HANDLE);
        std.debug.assert(max > 0);
        const size: vk.DeviceSize = @sizeOf(T) * max;
        try self.build_prim_buffer(pipe, size);
        try self.build_prim_descriptors(pipe, size, with_sampler);

        const vert = try self.make_shader_module(vert_code);
        defer self.dfns.vkDestroyShaderModule(self.device.?, vert, null);
        const frag = try self.make_shader_module(frag_code);
        defer self.dfns.vkDestroyShaderModule(self.device.?, frag, null);

        const push_range = vk.PushConstantRange{
            .stage_flags = vk.SHADER_STAGE_VERTEX_BIT,
            .size = 8, // vec2 viewport_size in points
        };
        const layout_info = vk.PipelineLayoutCreateInfo{
            .set_layout_count = 1,
            .set_layouts = @ptrCast(&pipe.dsl),
            .push_constant_range_count = 1,
            .push_constant_ranges = @ptrCast(&push_range),
        };
        if (self.dfns.vkCreatePipelineLayout(self.device.?, &layout_info, null, &pipe.layout) !=
            vk.SUCCESS) return error.PipelineCreateFailed;
        pipe.pipeline = try self.make_pipeline(vert, frag, pipe.layout);
    }

    // The shared fixed-function recipe: every stage pair differs only by layout.
    fn make_pipeline(
        self: *Renderer,
        vert: vk.ShaderModule,
        frag: vk.ShaderModule,
        layout: vk.PipelineLayout,
    ) Error!vk.Pipeline {
        std.debug.assert(layout != vk.NULL_HANDLE);
        const stages = [_]vk.PipelineShaderStageCreateInfo{
            .{ .stage = vk.SHADER_STAGE_VERTEX_BIT, .module = vert },
            .{ .stage = vk.SHADER_STAGE_FRAGMENT_BIT, .module = frag },
        };
        const vertex_input = vk.PipelineVertexInputStateCreateInfo{};
        const input_assembly = vk.PipelineInputAssemblyStateCreateInfo{};
        const viewport_state = vk.PipelineViewportStateCreateInfo{};
        const raster = vk.PipelineRasterizationStateCreateInfo{};
        const multisample = vk.PipelineMultisampleStateCreateInfo{};
        const blend_attachment = vk.PipelineColorBlendAttachmentState{};
        const blend = vk.PipelineColorBlendStateCreateInfo{
            .attachments = @ptrCast(&blend_attachment),
        };
        const dynamic_states = [_]u32{ vk.DYNAMIC_STATE_VIEWPORT, vk.DYNAMIC_STATE_SCISSOR };
        const dynamic = vk.PipelineDynamicStateCreateInfo{
            .dynamic_state_count = dynamic_states.len,
            .dynamic_states = &dynamic_states,
        };
        const info = vk.GraphicsPipelineCreateInfo{
            .stages = &stages,
            .vertex_input_state = &vertex_input,
            .input_assembly_state = &input_assembly,
            .viewport_state = &viewport_state,
            .rasterization_state = &raster,
            .multisample_state = &multisample,
            .color_blend_state = &blend,
            .dynamic_state = &dynamic,
            .layout = layout,
            .render_pass = self.render_pass,
        };
        var pipeline: vk.Pipeline = vk.NULL_HANDLE;
        const rc = self.dfns.vkCreateGraphicsPipelines(
            self.device.?,
            vk.NULL_HANDLE,
            1,
            @ptrCast(&info),
            null,
            @ptrCast(&pipeline),
        );
        if (rc != vk.SUCCESS) return error.PipelineCreateFailed;
        return pipeline;
    }

    // On this backend the "device" is a DeviceContext (see its doc), built here
    // because dfns must point at the renderer's final storage, not init's copy.
    pub fn get_device(self: *Renderer) *anyopaque {
        std.debug.assert(self.device != null);
        std.debug.assert(self.upload_cmd != null);
        self.device_ctx = .{
            .device = self.device.?,
            .dfns = &self.dfns,
            .queue = self.queue.?,
            .upload_cmd = self.upload_cmd.?,
            .mem_props = self.mem_props,
        };
        return @ptrCast(&self.device_ctx);
    }

    pub fn request_redraw(self: *Renderer) void {
        self.dirty = true;
    }

    pub fn draw_frame(
        self: *Renderer,
        clear: ClearColor,
        prims: []const Primitive,
        sprites: []const MonochromeSprite,
        mono_atlas: ?*anyopaque,
        color_sprites: []const PolychromeSprite,
        color_atlas: ?*anyopaque,
    ) void {
        self.draw_frame_impl(clear, prims, sprites, mono_atlas, color_sprites, color_atlas);
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
        // No blur pass on this backend: the split points are meaningless and
        // the whole scene draws crisp.
        _ = split_prims;
        _ = split_sprites;
        _ = split_color;
        _ = crisp_top;
        self.draw_frame_impl(clear, prims, sprites, mono_atlas, color_sprites, color_atlas);
    }

    fn draw_frame_impl(
        self: *Renderer,
        clear: ClearColor,
        prims: []const Primitive,
        sprites: []const MonochromeSprite,
        mono_atlas: ?*anyopaque,
        color_sprites: []const PolychromeSprite,
        color_atlas: ?*anyopaque,
    ) void {
        const device = self.device orelse return;
        const win_w: u32 = @intCast(@max(self.win.width_pt, 1));
        const win_h: u32 = @intCast(@max(self.win.height_pt, 1));
        if (win_w != self.extent.width or win_h != self.extent.height) {
            self.recreate_swapchain() catch return;
            self.dirty = true;
        }
        if (!self.dirty) return;

        _ = self.dfns.vkWaitForFences(device, 1, @ptrCast(&self.in_flight), 1, ~@as(u64, 0));
        const image_index = self.acquire_image() orelse return;
        std.debug.assert(image_index < self.image_count);
        _ = self.dfns.vkResetFences(device, 1, @ptrCast(&self.in_flight));

        self.bind_atlas(mono_atlas);
        self.bind_color_atlas(color_atlas);
        self.record_scene(image_index, clear, prims, sprites, color_sprites);
        self.submit_and_present(image_index);
        self.dirty = false;
    }

    fn acquire_image(self: *Renderer) ?u32 {
        var attempts: u32 = 0;
        while (attempts < ACQUIRE_ATTEMPTS_MAX) : (attempts += 1) {
            var image_index: u32 = 0;
            const rc = self.dfns.vkAcquireNextImageKHR(
                self.device.?,
                self.swapchain,
                ~@as(u64, 0),
                self.image_available,
                vk.NULL_HANDLE,
                &image_index,
            );
            if (rc == vk.SUCCESS or rc == vk.SUBOPTIMAL_KHR) return image_index;
            if (rc != vk.ERROR_OUT_OF_DATE_KHR) return null;
            self.recreate_swapchain() catch return null;
        }
        std.debug.assert(attempts == ACQUIRE_ATTEMPTS_MAX);
        return null;
    }

    // Points the text descriptor at the atlas view; deferred to right after the
    // fence wait so the update never races a command buffer in flight.
    fn bind_atlas(self: *Renderer, mono_atlas: ?*anyopaque) void {
        const raw = mono_atlas orelse return;
        const view_ptr: *const vk.ImageView = @ptrCast(@alignCast(raw));
        const view = view_ptr.*;
        std.debug.assert(view != vk.NULL_HANDLE);
        if (view == self.bound_atlas_view) return;
        const image_info = vk.DescriptorImageInfo{ .sampler = self.sampler, .image_view = view };
        const write = vk.WriteDescriptorSet{
            .dst_set = self.text_dset,
            .dst_binding = 1,
            .descriptor_type = vk.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .image_info = @ptrCast(&image_info),
        };
        self.dfns.vkUpdateDescriptorSets(self.device.?, 1, @ptrCast(&write), 0, null);
        self.bound_atlas_view = view;
    }

    // The color-atlas twin of bind_atlas, feeding the color-sprite pipeline.
    fn bind_color_atlas(self: *Renderer, color_atlas: ?*anyopaque) void {
        const raw = color_atlas orelse return;
        const view_ptr: *const vk.ImageView = @ptrCast(@alignCast(raw));
        const view = view_ptr.*;
        std.debug.assert(view != vk.NULL_HANDLE);
        if (view == self.bound_color_view) return;
        const image_info = vk.DescriptorImageInfo{ .sampler = self.sampler, .image_view = view };
        const write = vk.WriteDescriptorSet{
            .dst_set = self.color_pipe.dset,
            .dst_binding = 1,
            .descriptor_type = vk.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .image_info = @ptrCast(&image_info),
        };
        self.dfns.vkUpdateDescriptorSets(self.device.?, 1, @ptrCast(&write), 0, null);
        self.bound_color_view = view;
    }

    fn record_scene(
        self: *Renderer,
        image_index: u32,
        clear: ClearColor,
        prims: []const Primitive,
        sprites: []const MonochromeSprite,
        color_sprites: []const PolychromeSprite,
    ) void {
        const cmd = self.cmd_buf.?;
        const begin = vk.CommandBufferBeginInfo{};
        _ = self.dfns.vkBeginCommandBuffer(cmd, &begin);

        const clear_value = vk.ClearValue{ .color = .{ .float32 = clear.rgba } };
        const pass_begin = vk.RenderPassBeginInfo{
            .render_pass = self.render_pass,
            .framebuffer = self.framebuffers[image_index],
            .render_area = .{ .extent = self.extent },
            .clear_values = @ptrCast(&clear_value),
        };
        self.dfns.vkCmdBeginRenderPass(cmd, &pass_begin, vk.SUBPASS_CONTENTS_INLINE);

        const viewport = vk.Viewport{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(self.extent.width),
            .height = @floatFromInt(self.extent.height),
            .min_depth = 0,
            .max_depth = 1,
        };
        self.dfns.vkCmdSetViewport(cmd, 0, 1, @ptrCast(&viewport));
        const scissor = vk.Rect2D{ .extent = self.extent };
        self.dfns.vkCmdSetScissor(cmd, 0, 1, @ptrCast(&scissor));

        self.encode_scene(cmd, prims);
        if (sprites.len > 0 and self.bound_atlas_view != vk.NULL_HANDLE)
            self.encode_sprites(cmd, sprites);
        if (color_sprites.len > 0 and self.bound_color_view != vk.NULL_HANDLE)
            self.encode_color_sprites(cmd, color_sprites);

        self.dfns.vkCmdEndRenderPass(cmd);
        _ = self.dfns.vkEndCommandBuffer(cmd);
    }

    fn encode_scene(self: *Renderer, cmd: *vk.CommandBuffer, prims: []const Primitive) void {
        std.debug.assert(prims.len <= MAX_QUADS * 8); // sane per-frame ceiling
        var quad_offset: u32 = 0;
        var frame_offset: u32 = 0;
        var polyline_offset: u32 = 0;
        var line_offset: u32 = 0;
        var ring_offset: u32 = 0;
        var i: usize = 0;
        while (i < prims.len) {
            const start = i;
            const tag = std.meta.activeTag(prims[i]);
            while (i < prims.len and std.meta.activeTag(prims[i]) == tag) i += 1;
            std.debug.assert(i > start);
            const batch = prims[start..i];
            switch (tag) {
                .quad => self.encode_quad_batch(cmd, batch, &quad_offset),
                .frame => self.encode_frame_batch(cmd, batch, &frame_offset),
                .polyline => self.encode_prim_batch(
                    Polyline,
                    "polyline",
                    cmd,
                    &self.polyline_pipe,
                    MAX_POLYLINES,
                    batch,
                    &polyline_offset,
                ),
                .line_segment => self.encode_prim_batch(
                    LineSegment,
                    "line_segment",
                    cmd,
                    &self.line_pipe,
                    MAX_LINES,
                    batch,
                    &line_offset,
                ),
                .ring_chart => self.encode_prim_batch(
                    RingChart,
                    "ring_chart",
                    cmd,
                    &self.ring_pipe,
                    MAX_RINGS,
                    batch,
                    &ring_offset,
                ),
            }
        }
    }

    // The d3d11 encode_prim_batch shape: copy the run's payloads into the
    // class buffer at the running offset, one instanced draw for the run.
    fn encode_prim_batch(
        self: *Renderer,
        comptime T: type,
        comptime field: []const u8,
        cmd: *vk.CommandBuffer,
        pipe: *const PrimPipe,
        max: u32,
        batch: []const Primitive,
        offset: *u32,
    ) void {
        std.debug.assert(batch.len > 0);
        const raw = pipe.mapped orelse return;
        const mapped: [*]T = @ptrCast(@alignCast(raw));
        // The cap is a soft budget: a batch that does not fit is skipped whole
        // for this frame, the same trade-off as the other encoders.
        if (offset.* + batch.len > max) return;
        const first = offset.*;
        for (batch, 0..) |prim, index| mapped[first + index] = @field(prim, field);
        offset.* = first + @as(u32, @intCast(batch.len));
        std.debug.assert(offset.* <= max);

        self.dfns.vkCmdBindPipeline(cmd, vk.PIPELINE_BIND_POINT_GRAPHICS, pipe.pipeline);
        self.dfns.vkCmdBindDescriptorSets(
            cmd,
            vk.PIPELINE_BIND_POINT_GRAPHICS,
            pipe.layout,
            0,
            1,
            @ptrCast(&pipe.dset),
            0,
            null,
        );
        const viewport_pt = [2]f32{
            @floatFromInt(self.extent.width),
            @floatFromInt(self.extent.height),
        };
        self.dfns.vkCmdPushConstants(
            cmd,
            pipe.layout,
            vk.SHADER_STAGE_VERTEX_BIT,
            0,
            8,
            @ptrCast(&viewport_pt),
        );
        self.dfns.vkCmdDraw(cmd, 6, @intCast(batch.len), 0, first);
    }

    fn encode_color_sprites(
        self: *Renderer,
        cmd: *vk.CommandBuffer,
        color_sprites: []const PolychromeSprite,
    ) void {
        std.debug.assert(color_sprites.len > 0);
        const raw = self.color_pipe.mapped orelse return;
        const mapped: [*]PolychromeSprite = @ptrCast(@alignCast(raw));
        // Same soft budget as the other encoders: an over-cap batch is skipped
        // whole for the frame.
        if (color_sprites.len > MAX_COLOR_SPRITES) return;
        @memcpy(mapped[0..color_sprites.len], color_sprites);

        self.dfns.vkCmdBindPipeline(cmd, vk.PIPELINE_BIND_POINT_GRAPHICS, self.color_pipe.pipeline);
        self.dfns.vkCmdBindDescriptorSets(
            cmd,
            vk.PIPELINE_BIND_POINT_GRAPHICS,
            self.color_pipe.layout,
            0,
            1,
            @ptrCast(&self.color_pipe.dset),
            0,
            null,
        );
        const viewport_pt = [2]f32{
            @floatFromInt(self.extent.width),
            @floatFromInt(self.extent.height),
        };
        self.dfns.vkCmdPushConstants(
            cmd,
            self.color_pipe.layout,
            vk.SHADER_STAGE_VERTEX_BIT,
            0,
            8,
            @ptrCast(&viewport_pt),
        );
        self.dfns.vkCmdDraw(cmd, 6, @intCast(color_sprites.len), 0, 0);
    }

    fn encode_frame_batch(
        self: *Renderer,
        cmd: *vk.CommandBuffer,
        batch: []const Primitive,
        frame_offset: *u32,
    ) void {
        std.debug.assert(batch.len > 0);
        // Same soft budget as the other encoders: an over-cap batch is skipped
        // whole for the frame.
        if (frame_offset.* + batch.len > MAX_FRAMES) return;
        const viewport_pt = [2]f32{
            @floatFromInt(self.extent.width),
            @floatFromInt(self.extent.height),
        };
        for (batch) |prim| {
            const f = prim.frame;
            const raw = f.tex orelse continue;
            const luma_view = @as(*const vk.ImageView, @ptrCast(@alignCast(raw))).*;
            if (luma_view == vk.NULL_HANDLE) continue;
            const nv12 = f.tex_cbcr != null;
            const pipeline = if (nv12) self.frame_nv12_pipeline else self.frame_pipeline;
            if (pipeline == vk.NULL_HANDLE) continue;
            // RGBA never samples binding 1; aliasing it to luma keeps the set
            // fully written so both pipelines share one layout.
            const chroma_view = if (f.tex_cbcr) |c|
                @as(*const vk.ImageView, @ptrCast(@alignCast(c))).*
            else
                luma_view;
            std.debug.assert(frame_offset.* < MAX_FRAMES);
            const dset = self.frame_dsets[frame_offset.*];
            frame_offset.* += 1;
            self.write_frame_dset(dset, luma_view, chroma_view);

            self.dfns.vkCmdBindPipeline(cmd, vk.PIPELINE_BIND_POINT_GRAPHICS, pipeline);
            self.dfns.vkCmdBindDescriptorSets(
                cmd,
                vk.PIPELINE_BIND_POINT_GRAPHICS,
                self.frame_pipeline_layout,
                0,
                1,
                @ptrCast(&dset),
                0,
                null,
            );
            const push = FramePush{
                .viewport = viewport_pt,
                .bounds = f.bounds,
                .clip_bounds = f.clip_bounds,
                .opacity_pad = .{ f.opacity, 0, 0, 0 },
                .csc = f.csc,
            };
            self.dfns.vkCmdPushConstants(
                cmd,
                self.frame_pipeline_layout,
                vk.SHADER_STAGE_VERTEX_BIT | vk.SHADER_STAGE_FRAGMENT_BIT,
                0,
                @sizeOf(FramePush),
                @ptrCast(&push),
            );
            self.dfns.vkCmdDraw(cmd, 6, 1, 0, 0);
        }
    }

    // Writing right before the set's only bind in this freshly begun recording
    // is legal: the in_flight fence wait in draw_frame_impl guarantees the
    // previous use of the set has retired before record_scene starts.
    fn write_frame_dset(
        self: *Renderer,
        dset: vk.DescriptorSet,
        luma_view: vk.ImageView,
        chroma_view: vk.ImageView,
    ) void {
        std.debug.assert(luma_view != vk.NULL_HANDLE);
        std.debug.assert(chroma_view != vk.NULL_HANDLE);
        const image_infos = [_]vk.DescriptorImageInfo{
            .{ .sampler = self.sampler, .image_view = luma_view },
            .{ .sampler = self.sampler, .image_view = chroma_view },
        };
        const writes = [_]vk.WriteDescriptorSet{
            .{
                .dst_set = dset,
                .dst_binding = 0,
                .descriptor_type = vk.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                .image_info = image_infos[0..1].ptr,
            },
            .{
                .dst_set = dset,
                .dst_binding = 1,
                .descriptor_type = vk.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                .image_info = image_infos[1..2].ptr,
            },
        };
        self.dfns.vkUpdateDescriptorSets(self.device.?, writes.len, &writes, 0, null);
    }

    fn encode_quad_batch(
        self: *Renderer,
        cmd: *vk.CommandBuffer,
        batch: []const Primitive,
        quad_offset: *u32,
    ) void {
        std.debug.assert(batch.len > 0);
        const mapped = self.quad_mapped orelse return;
        // The cap is a soft budget: a batch that does not fit is skipped whole
        // for this frame, the same trade-off as the macOS/Windows encoders.
        if (quad_offset.* + batch.len > MAX_QUADS) return;
        const first = quad_offset.*;
        for (batch, 0..) |prim, index| mapped[first + index] = prim.quad;
        quad_offset.* = first + @as(u32, @intCast(batch.len));

        self.dfns.vkCmdBindPipeline(cmd, vk.PIPELINE_BIND_POINT_GRAPHICS, self.quad_pipeline);
        self.dfns.vkCmdBindDescriptorSets(
            cmd,
            vk.PIPELINE_BIND_POINT_GRAPHICS,
            self.quad_pipeline_layout,
            0,
            1,
            @ptrCast(&self.quad_dset),
            0,
            null,
        );
        // Buffer scale is 1, so the point-unit viewport equals the pixel extent.
        const viewport_pt = [2]f32{
            @floatFromInt(self.extent.width),
            @floatFromInt(self.extent.height),
        };
        self.dfns.vkCmdPushConstants(
            cmd,
            self.quad_pipeline_layout,
            vk.SHADER_STAGE_VERTEX_BIT,
            0,
            8,
            @ptrCast(&viewport_pt),
        );
        self.dfns.vkCmdDraw(cmd, 6, @intCast(batch.len), 0, first);
    }

    fn encode_sprites(
        self: *Renderer,
        cmd: *vk.CommandBuffer,
        sprites: []const MonochromeSprite,
    ) void {
        std.debug.assert(sprites.len > 0);
        const mapped = self.sprite_mapped orelse return;
        // Same soft budget as the other encoders: an over-cap batch is skipped
        // whole for the frame.
        if (sprites.len > MAX_SPRITES) return;
        @memcpy(mapped[0..sprites.len], sprites);

        self.dfns.vkCmdBindPipeline(cmd, vk.PIPELINE_BIND_POINT_GRAPHICS, self.text_pipeline);
        self.dfns.vkCmdBindDescriptorSets(
            cmd,
            vk.PIPELINE_BIND_POINT_GRAPHICS,
            self.text_pipeline_layout,
            0,
            1,
            @ptrCast(&self.text_dset),
            0,
            null,
        );
        const viewport_pt = [2]f32{
            @floatFromInt(self.extent.width),
            @floatFromInt(self.extent.height),
        };
        self.dfns.vkCmdPushConstants(
            cmd,
            self.text_pipeline_layout,
            vk.SHADER_STAGE_VERTEX_BIT,
            0,
            8,
            @ptrCast(&viewport_pt),
        );
        self.dfns.vkCmdDraw(cmd, 6, @intCast(sprites.len), 0, 0);
    }

    fn submit_and_present(self: *Renderer, image_index: u32) void {
        std.debug.assert(image_index < self.image_count);
        const wait_stage = [_]u32{vk.PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT};
        const submit = vk.SubmitInfo{
            .wait_semaphore_count = 1,
            .wait_semaphores = @ptrCast(&self.image_available),
            .wait_dst_stage_mask = &wait_stage,
            .command_buffers = @ptrCast(&self.cmd_buf.?),
            .signal_semaphore_count = 1,
            .signal_semaphores = @ptrCast(&self.render_finished[image_index]),
        };
        const queue = self.queue.?;
        const submit_rc = self.dfns.vkQueueSubmit(queue, 1, @ptrCast(&submit), self.in_flight);
        std.debug.assert(submit_rc == vk.SUCCESS or submit_rc < 0);
        if (submit_rc != vk.SUCCESS) return;

        var indices = [_]u32{image_index};
        const present = vk.PresentInfoKHR{
            .wait_semaphores = @ptrCast(&self.render_finished[image_index]),
            .swapchains = @ptrCast(&self.swapchain),
            .image_indices = &indices,
        };
        const rc = self.dfns.vkQueuePresentKHR(self.queue.?, &present);
        if (rc == vk.ERROR_OUT_OF_DATE_KHR or rc == vk.SUBOPTIMAL_KHR) {
            self.recreate_swapchain() catch return;
            self.dirty = true;
        }
    }

    pub fn create_shared_nv12_surface(self: *Renderer, width: u32, height: u32) ?FrameSurface {
        std.debug.assert(width > 0);
        std.debug.assert(height > 0);
        std.debug.assert(width <= MAX_FRAME_DIM);
        std.debug.assert(height <= MAX_FRAME_DIM);
        std.debug.assert(width % 2 == 0);
        std.debug.assert(height % 2 == 0);

        var out = FrameSurface{
            .format = .shared_nv12,
            .width = width,
            .height = height,
            .stride = width,
            .pixels = @ptrCast(&shared_frame_pixel),
            .chroma_stride = width,
        };
        out.state.renderer = self;
        if (!self.ensure_frame_planes(&out)) {
            out.deinit();
            return null;
        }
        return out;
    }

    // Copies the caller's NV12 planes through the surface's staging buffer into
    // its images. Call only while the surface is available(): with no ref held
    // by the mailbox or the GPU ring, nothing in flight samples the planes.
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
        const mapped = surface.state.staging_mapped orelse return false;
        const luma_bytes = @as(usize, surface.width) * surface.height;
        copy_frame_rows(mapped, y, y_stride, surface.width, surface.height);
        copy_frame_rows(mapped + luma_bytes, uv, uv_stride, surface.width, surface.height / 2);
        return self.submit_frame_upload(surface);
    }

    pub const Nv12Textures = struct {
        luma: *anyopaque,
        chroma: ?*anyopaque,
        cv_luma: *anyopaque,
        cv_chroma: ?*anyopaque,
        width: u32,
        height: u32,
    };

    // The shared facade keeps the macOS import name; this backend accepts the
    // FrameSurface formats and returns stable pointers to their plane views
    // (the atlas get_texture convention). cv_luma carries the surface for the
    // ring's release accounting.
    pub fn import_nv12(self: *Renderer, pixel_buffer: *anyopaque) ?Nv12Textures {
        const surface: *FrameSurface = @ptrCast(@alignCast(pixel_buffer));
        std.debug.assert(surface.width > 0);
        std.debug.assert(surface.height > 0);
        return switch (surface.format) {
            .bgra => self.import_bgra(surface),
            .nv12 => self.import_nv12_surface(surface),
            .shared_nv12 => import_shared_nv12_surface(surface),
        };
    }

    pub fn flush_texture_cache(self: *Renderer) void {
        _ = self;
    }

    pub fn release_cv_texture(ref: *anyopaque) void {
        const surface: *FrameSurface = @ptrCast(@alignCast(ref));
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

    fn import_bgra(self: *Renderer, surface: *FrameSurface) ?Nv12Textures {
        std.debug.assert(surface.stride >= surface.width * 4);
        if (!self.ensure_frame_planes(surface)) return null;
        const mapped = surface.state.staging_mapped orelse return null;
        copy_frame_rows(
            mapped,
            surface.pixels,
            surface.stride,
            surface.width * 4,
            surface.height,
        );
        if (!self.submit_frame_upload(surface)) return null;
        const old = surface.state.refs.fetchAdd(1, .acq_rel);
        std.debug.assert(old >= 1);
        return .{
            .luma = @ptrCast(&surface.state.luma.view),
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
        const uv = surface.chroma_pixels orelse return null;
        if (!self.ensure_frame_planes(surface)) return null;
        const mapped = surface.state.staging_mapped orelse return null;
        const luma_bytes = @as(usize, surface.width) * surface.height;
        copy_frame_rows(mapped, surface.pixels, surface.stride, surface.width, surface.height);
        copy_frame_rows(
            mapped + luma_bytes,
            uv,
            surface.chroma_stride,
            surface.width,
            surface.height / 2,
        );
        if (!self.submit_frame_upload(surface)) return null;
        const old = surface.state.refs.fetchAdd(1, .acq_rel);
        std.debug.assert(old >= 1);
        return .{
            .luma = @ptrCast(&surface.state.luma.view),
            .chroma = @ptrCast(&surface.state.chroma.view),
            .cv_luma = @ptrCast(surface),
            .cv_chroma = null,
            .width = surface.width,
            .height = surface.height,
        };
    }

    fn import_shared_nv12_surface(surface: *FrameSurface) ?Nv12Textures {
        std.debug.assert(surface.format == .shared_nv12);
        std.debug.assert(surface.width % 2 == 0);
        // Never updated means the planes still sit in UNDEFINED layout; a draw
        // sampling them would be invalid, so the import reports no frame.
        if (!surface.state.uploaded) return null;
        const old = surface.state.refs.fetchAdd(1, .acq_rel);
        std.debug.assert(old >= 1);
        return .{
            .luma = @ptrCast(&surface.state.luma.view),
            .chroma = @ptrCast(&surface.state.chroma.view),
            .cv_luma = @ptrCast(surface),
            .cv_chroma = null,
            .width = surface.width,
            .height = surface.height,
        };
    }

    // Lazily creates the surface's plane images and staging buffer (the d3d11
    // ensure_* convention): bgra gets one full-size plane, nv12 an R8 luma plus
    // a half-size RG8 chroma. Commits nothing on failure so a retry can run.
    fn ensure_frame_planes(self: *Renderer, surface: *FrameSurface) bool {
        if (surface.state.staging_mapped != null) return true;
        surface.state.renderer = self;
        const w = surface.width;
        const h = surface.height;
        const ok = switch (surface.format) {
            .bgra => self.create_frame_plane(
                &surface.state.luma,
                w,
                h,
                vk.FORMAT_B8G8R8A8_UNORM,
            ),
            .nv12, .shared_nv12 => self.create_frame_plane(
                &surface.state.luma,
                w,
                h,
                vk.FORMAT_R8_UNORM,
            ) and self.create_frame_plane(
                &surface.state.chroma,
                w / 2,
                h / 2,
                vk.FORMAT_R8G8_UNORM,
            ),
        };
        const staging_bytes: usize = switch (surface.format) {
            .bgra => @as(usize, w) * h * 4,
            .nv12, .shared_nv12 => @as(usize, w) * h * 3 / 2,
        };
        if (!ok or !self.create_frame_staging(&surface.state, staging_bytes)) {
            destroy_frame_plane(self, &surface.state.luma);
            destroy_frame_plane(self, &surface.state.chroma);
            return false;
        }
        return true;
    }

    fn create_frame_plane(self: *Renderer, plane: *FramePlane, w: u32, h: u32, format: u32) bool {
        std.debug.assert(plane.image == vk.NULL_HANDLE);
        std.debug.assert(w > 0);
        std.debug.assert(h > 0);
        const device = self.device orelse return false;
        const info = vk.ImageCreateInfo{
            .format = format,
            .extent = .{ .width = w, .height = h, .depth = 1 },
        };
        if (self.dfns.vkCreateImage(device, &info, null, &plane.image) != vk.SUCCESS)
            return false;
        var requirements: vk.MemoryRequirements = undefined;
        self.dfns.vkGetImageMemoryRequirements(device, plane.image, &requirements);
        const type_index = self.find_memory_type(
            requirements.memory_type_bits,
            vk.MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
        ) orelse return false;
        const alloc = vk.MemoryAllocateInfo{
            .allocation_size = requirements.size,
            .memory_type_index = type_index,
        };
        if (self.dfns.vkAllocateMemory(device, &alloc, null, &plane.memory) != vk.SUCCESS)
            return false;
        if (self.dfns.vkBindImageMemory(device, plane.image, plane.memory, 0) != vk.SUCCESS)
            return false;
        const view_info = vk.ImageViewCreateInfo{ .image = plane.image, .format = format };
        return self.dfns.vkCreateImageView(device, &view_info, null, &plane.view) == vk.SUCCESS;
    }

    fn create_frame_staging(self: *Renderer, state: *FrameSurfaceState, size: usize) bool {
        std.debug.assert(state.staging == vk.NULL_HANDLE);
        std.debug.assert(size > 0);
        const device = self.device orelse return false;
        const info = vk.BufferCreateInfo{
            .size = size,
            .usage = vk.BUFFER_USAGE_TRANSFER_SRC_BIT,
        };
        if (self.dfns.vkCreateBuffer(device, &info, null, &state.staging) != vk.SUCCESS)
            return false;
        var requirements: vk.MemoryRequirements = undefined;
        self.dfns.vkGetBufferMemoryRequirements(device, state.staging, &requirements);
        const wanted = vk.MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.MEMORY_PROPERTY_HOST_COHERENT_BIT;
        const type_index = self.find_memory_type(requirements.memory_type_bits, wanted) orelse
            return false;
        const alloc = vk.MemoryAllocateInfo{
            .allocation_size = requirements.size,
            .memory_type_index = type_index,
        };
        if (self.dfns.vkAllocateMemory(device, &alloc, null, &state.staging_memory) != vk.SUCCESS)
            return false;
        if (self.dfns.vkBindBufferMemory(device, state.staging, state.staging_memory, 0) !=
            vk.SUCCESS) return false;
        var mapped: *anyopaque = undefined;
        if (self.dfns.vkMapMemory(device, state.staging_memory, 0, size, 0, &mapped) !=
            vk.SUCCESS) return false;
        state.staging_mapped = @ptrCast(@alignCast(mapped));
        return true;
    }

    // Records the staged planes into the surface's images and waits the queue.
    // Synchronous is correct here: callers run at producer pace (one video
    // frame, not one paint), and the wait is what lets the next write reuse
    // the staging buffer without a fence per surface.
    fn submit_frame_upload(self: *Renderer, surface: *FrameSurface) bool {
        const cmd = self.upload_cmd orelse return false;
        std.debug.assert(surface.state.staging != vk.NULL_HANDLE);
        std.debug.assert(surface.state.luma.image != vk.NULL_HANDLE);
        _ = self.dfns.vkResetCommandBuffer(cmd, 0);
        const begin = vk.CommandBufferBeginInfo{};
        _ = self.dfns.vkBeginCommandBuffer(cmd, &begin);

        const uploaded = surface.state.uploaded;
        self.frame_plane_barrier(cmd, &surface.state.luma, uploaded, true);
        const luma_copy = vk.BufferImageCopy{
            .image_offset = .{},
            .image_extent = .{ .width = surface.width, .height = surface.height, .depth = 1 },
        };
        self.dfns.vkCmdCopyBufferToImage(
            cmd,
            surface.state.staging,
            surface.state.luma.image,
            vk.IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            1,
            @ptrCast(&luma_copy),
        );
        self.frame_plane_barrier(cmd, &surface.state.luma, uploaded, false);

        if (surface.format != .bgra) {
            std.debug.assert(surface.state.chroma.image != vk.NULL_HANDLE);
            self.frame_plane_barrier(cmd, &surface.state.chroma, uploaded, true);
            const chroma_copy = vk.BufferImageCopy{
                .buffer_offset = @as(u64, surface.width) * surface.height,
                .image_offset = .{},
                .image_extent = .{
                    .width = surface.width / 2,
                    .height = surface.height / 2,
                    .depth = 1,
                },
            };
            self.dfns.vkCmdCopyBufferToImage(
                cmd,
                surface.state.staging,
                surface.state.chroma.image,
                vk.IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                1,
                @ptrCast(&chroma_copy),
            );
            self.frame_plane_barrier(cmd, &surface.state.chroma, uploaded, false);
        }
        _ = self.dfns.vkEndCommandBuffer(cmd);

        const submit = vk.SubmitInfo{ .command_buffers = @ptrCast(&cmd) };
        if (self.dfns.vkQueueSubmit(self.queue.?, 1, @ptrCast(&submit), vk.NULL_HANDLE) !=
            vk.SUCCESS) return false;
        _ = self.dfns.vkQueueWaitIdle(self.queue.?);
        surface.state.uploaded = true;
        return true;
    }

    fn frame_plane_barrier(
        self: *Renderer,
        cmd: *vk.CommandBuffer,
        plane: *const FramePlane,
        uploaded: bool,
        to_transfer: bool,
    ) void {
        std.debug.assert(plane.image != vk.NULL_HANDLE);
        const old_layout: u32 = if (!to_transfer)
            vk.IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL
        else if (uploaded)
            vk.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
        else
            vk.IMAGE_LAYOUT_UNDEFINED;
        const b = vk.ImageMemoryBarrier{
            .src_access_mask = if (to_transfer) 0 else vk.ACCESS_TRANSFER_WRITE_BIT,
            .dst_access_mask = if (to_transfer)
                vk.ACCESS_TRANSFER_WRITE_BIT
            else
                vk.ACCESS_SHADER_READ_BIT,
            .old_layout = old_layout,
            .new_layout = if (to_transfer)
                vk.IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL
            else
                vk.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            .image = plane.image,
        };
        const src_stage = if (to_transfer)
            vk.PIPELINE_STAGE_TOP_OF_PIPE_BIT | vk.PIPELINE_STAGE_FRAGMENT_SHADER_BIT
        else
            vk.PIPELINE_STAGE_TRANSFER_BIT;
        const dst_stage = if (to_transfer)
            vk.PIPELINE_STAGE_TRANSFER_BIT
        else
            vk.PIPELINE_STAGE_FRAGMENT_SHADER_BIT;
        const one: [*]const vk.ImageMemoryBarrier = @ptrCast(&b);
        self.dfns.vkCmdPipelineBarrier(cmd, src_stage, dst_stage, 0, 0, null, 0, null, 1, one);
    }
};

// Packs `rows` rows of `row_bytes` from a strided source into a tight
// destination (the staging layout vkCmdCopyBufferToImage expects with
// buffer_row_length 0).
fn copy_frame_rows(
    dst: [*]u8,
    src: [*]const u8,
    src_stride: u32,
    row_bytes: u32,
    rows: u32,
) void {
    std.debug.assert(src_stride >= row_bytes);
    std.debug.assert(rows <= MAX_FRAME_DIM);
    var row: u32 = 0;
    while (row < rows) : (row += 1) {
        const dst_at = @as(usize, row) * row_bytes;
        const src_at = @as(usize, row) * src_stride;
        @memcpy(dst[dst_at .. dst_at + row_bytes], src[src_at .. src_at + row_bytes]);
    }
}
