// Vulkan renderer over the Wayland custom shell (the d3d11_renderer.zig
// analogue). Same architecture: instance data streamed into per-class storage
// buffers, the unit square expanded by gl_VertexIndex, one instanced draw per
// batch. Quads and monochrome sprites (text + icons) have pipelines; the
// other primitive classes and color sprites draw nowhere on this backend.
// The modal blur pass does not exist here either - modal frames draw crisp.

const std = @import("std");
const vk = @import("vulkan.zig");
const wl = @import("wayland.zig");
const shell = @import("custom_shell.zig");
const primitives = @import("../../primitives.zig");

const Primitive = primitives.Primitive;
const Quad = primitives.Quad;
const MonochromeSprite = primitives.MonochromeSprite;
const PolychromeSprite = primitives.PolychromeSprite;

pub const max_frames_in_flight: u32 = 3;

const MAX_QUADS: u32 = 1024;
const MAX_SPRITES: u32 = 4096;
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
        const pool_sizes = [_]vk.DescriptorPoolSize{
            .{ .descriptor_type = vk.DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptor_count = 2 },
            .{
                .descriptor_type = vk.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                .descriptor_count = 1,
            },
        };
        const pool_info = vk.DescriptorPoolCreateInfo{
            .max_sets = 2,
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
        _ = color_sprites;
        _ = color_atlas;
        self.draw_frame_impl(clear, prims, sprites, mono_atlas);
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
        _ = color_sprites;
        _ = color_atlas;
        _ = split_prims;
        _ = split_sprites;
        _ = split_color;
        _ = crisp_top;
        self.draw_frame_impl(clear, prims, sprites, mono_atlas);
    }

    fn draw_frame_impl(
        self: *Renderer,
        clear: ClearColor,
        prims: []const Primitive,
        sprites: []const MonochromeSprite,
        mono_atlas: ?*anyopaque,
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
        self.record_scene(image_index, clear, prims, sprites);
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

    fn record_scene(
        self: *Renderer,
        image_index: u32,
        clear: ClearColor,
        prims: []const Primitive,
        sprites: []const MonochromeSprite,
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

        self.dfns.vkCmdEndRenderPass(cmd);
        _ = self.dfns.vkEndCommandBuffer(cmd);
    }

    fn encode_scene(self: *Renderer, cmd: *vk.CommandBuffer, prims: []const Primitive) void {
        std.debug.assert(prims.len <= MAX_QUADS * 8); // sane per-frame ceiling
        var quad_offset: u32 = 0;
        var i: usize = 0;
        while (i < prims.len) {
            const start = i;
            const tag = std.meta.activeTag(prims[i]);
            while (i < prims.len and std.meta.activeTag(prims[i]) == tag) i += 1;
            std.debug.assert(i > start);
            const batch = prims[start..i];
            switch (tag) {
                .quad => self.encode_quad_batch(cmd, batch, &quad_offset),
                // No pipeline exists for these classes on this backend; they
                // draw nowhere, the metal.zig empty-arm precedent.
                .polyline, .line_segment, .ring_chart, .frame => {},
            }
        }
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

    pub const Nv12Textures = struct {
        luma: *anyopaque,
        chroma: ?*anyopaque,
        cv_luma: *anyopaque,
        cv_chroma: ?*anyopaque,
        width: u32,
        height: u32,
    };

    // The frame-import surface FrameSource drives. dmabuf import is not wired
    // on this backend, so import returns null and the ref-counting entry points
    // are inert.
    pub fn import_nv12(self: *Renderer, pixel_buffer: *anyopaque) ?Nv12Textures {
        _ = self;
        std.debug.assert(@intFromPtr(pixel_buffer) != 0);
        return null;
    }

    pub fn flush_texture_cache(self: *Renderer) void {
        _ = self;
    }

    pub fn release_cv_texture(ref: *anyopaque) void {
        std.debug.assert(@intFromPtr(ref) != 0);
    }

    pub fn retain_surface(pixel_buffer: *anyopaque) void {
        std.debug.assert(@intFromPtr(pixel_buffer) != 0);
    }

    pub fn release_surface(pixel_buffer: *anyopaque) void {
        std.debug.assert(@intFromPtr(pixel_buffer) != 0);
    }
};
