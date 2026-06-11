// Vulkan binding (the d3d11.zig/dxgi.zig analogue). libvulkan.so.1 is loaded
// with dlopen at runtime like the wayland binding, and entry points resolve in
// the canonical three tiers - global, instance, device - so hot calls go through
// driver-direct pointers, never the loader trampoline. Only the surface the
// renderer speaks is declared; new API lands beside the feature that needs it.

const std = @import("std");

pub const Instance = opaque {};
pub const PhysicalDevice = opaque {};
pub const Device = opaque {};
pub const Queue = opaque {};
pub const CommandBuffer = opaque {};

pub const SurfaceKHR = u64;
pub const SwapchainKHR = u64;
pub const Image = u64;
pub const ImageView = u64;
pub const RenderPass = u64;
pub const Framebuffer = u64;
pub const CommandPool = u64;
pub const Semaphore = u64;
pub const Fence = u64;
pub const Buffer = u64;
pub const DeviceMemory = u64;
pub const ShaderModule = u64;
pub const PipelineLayout = u64;
pub const Pipeline = u64;
pub const DescriptorSetLayout = u64;
pub const DescriptorPool = u64;
pub const DescriptorSet = u64;
pub const NULL_HANDLE: u64 = 0;

pub const Result = i32;
pub const SUCCESS: Result = 0;
pub const TIMEOUT: Result = 2;
pub const SUBOPTIMAL_KHR: Result = 1000001003;
pub const ERROR_OUT_OF_DATE_KHR: Result = -1000001004;

pub const Bool32 = u32;
pub const DeviceSize = u64;

pub const FORMAT_B8G8R8A8_UNORM: u32 = 44;
pub const COLOR_SPACE_SRGB_NONLINEAR_KHR: u32 = 0;
pub const PRESENT_MODE_FIFO_KHR: u32 = 2;

pub const IMAGE_USAGE_COLOR_ATTACHMENT_BIT: u32 = 0x10;
pub const COMPOSITE_ALPHA_OPAQUE_BIT_KHR: u32 = 1;
pub const SURFACE_TRANSFORM_IDENTITY_BIT_KHR: u32 = 1;
pub const SHARING_MODE_EXCLUSIVE: u32 = 0;

pub const IMAGE_VIEW_TYPE_2D: u32 = 1;
pub const IMAGE_ASPECT_COLOR_BIT: u32 = 1;

pub const ATTACHMENT_LOAD_OP_CLEAR: u32 = 1;
pub const ATTACHMENT_STORE_OP_STORE: u32 = 0;
pub const ATTACHMENT_LOAD_OP_DONT_CARE: u32 = 2;
pub const ATTACHMENT_STORE_OP_DONT_CARE: u32 = 1;
pub const IMAGE_LAYOUT_UNDEFINED: u32 = 0;
pub const IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL: u32 = 2;
pub const IMAGE_LAYOUT_PRESENT_SRC_KHR: u32 = 1000001002;
pub const PIPELINE_BIND_POINT_GRAPHICS: u32 = 0;
pub const SAMPLE_COUNT_1_BIT: u32 = 1;
pub const SUBPASS_EXTERNAL: u32 = 0xFFFFFFFF;
pub const PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT: u32 = 0x400;
pub const ACCESS_COLOR_ATTACHMENT_WRITE_BIT: u32 = 0x100;

pub const COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT: u32 = 2;
pub const COMMAND_BUFFER_LEVEL_PRIMARY: u32 = 0;
pub const COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT: u32 = 1;
pub const FENCE_CREATE_SIGNALED_BIT: u32 = 1;
pub const SUBPASS_CONTENTS_INLINE: u32 = 0;

pub const QUEUE_GRAPHICS_BIT: u32 = 1;

pub const BUFFER_USAGE_STORAGE_BUFFER_BIT: u32 = 0x20;
pub const MEMORY_PROPERTY_HOST_VISIBLE_BIT: u32 = 2;
pub const MEMORY_PROPERTY_HOST_COHERENT_BIT: u32 = 4;

pub const SHADER_STAGE_VERTEX_BIT: u32 = 1;
pub const SHADER_STAGE_FRAGMENT_BIT: u32 = 0x10;
pub const DESCRIPTOR_TYPE_STORAGE_BUFFER: u32 = 7;
pub const DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER: u32 = 1;

pub const FORMAT_R8_UNORM: u32 = 9;
pub const FORMAT_R8G8_UNORM: u32 = 16;
pub const FORMAT_R8G8B8A8_UNORM: u32 = 37;
pub const IMAGE_TYPE_2D: u32 = 1;
pub const IMAGE_TILING_OPTIMAL: u32 = 0;
pub const IMAGE_USAGE_TRANSFER_DST_BIT: u32 = 2;
pub const IMAGE_USAGE_SAMPLED_BIT: u32 = 4;
pub const BUFFER_USAGE_TRANSFER_SRC_BIT: u32 = 1;
pub const MEMORY_PROPERTY_DEVICE_LOCAL_BIT: u32 = 1;
pub const IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL: u32 = 5;
pub const IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL: u32 = 7;
pub const PIPELINE_STAGE_TOP_OF_PIPE_BIT: u32 = 1;
pub const PIPELINE_STAGE_TRANSFER_BIT: u32 = 0x1000;
pub const PIPELINE_STAGE_FRAGMENT_SHADER_BIT: u32 = 0x80;
pub const ACCESS_TRANSFER_WRITE_BIT: u32 = 0x1000;
pub const ACCESS_SHADER_READ_BIT: u32 = 0x20;
pub const QUEUE_FAMILY_IGNORED: u32 = 0xFFFFFFFF;
pub const FILTER_LINEAR: u32 = 1;
pub const SAMPLER_MIPMAP_MODE_NEAREST: u32 = 0;
pub const SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE: u32 = 2;

pub const PRIMITIVE_TOPOLOGY_TRIANGLE_LIST: u32 = 3;
pub const POLYGON_MODE_FILL: u32 = 0;
pub const CULL_MODE_NONE: u32 = 0;
pub const FRONT_FACE_CLOCKWISE: u32 = 1;
pub const BLEND_FACTOR_ONE: u32 = 1;
pub const BLEND_FACTOR_SRC_ALPHA: u32 = 6;
pub const BLEND_FACTOR_ONE_MINUS_SRC_ALPHA: u32 = 7;
pub const BLEND_OP_ADD: u32 = 0;
pub const COLOR_COMPONENT_RGBA: u32 = 0xF;
pub const DYNAMIC_STATE_VIEWPORT: u32 = 0;
pub const DYNAMIC_STATE_SCISSOR: u32 = 1;

const ST_APPLICATION_INFO: u32 = 0;
const ST_INSTANCE_CREATE_INFO: u32 = 1;
const ST_DEVICE_QUEUE_CREATE_INFO: u32 = 2;
const ST_DEVICE_CREATE_INFO: u32 = 3;
const ST_SUBMIT_INFO: u32 = 4;
const ST_MEMORY_ALLOCATE_INFO: u32 = 5;
const ST_FENCE_CREATE_INFO: u32 = 8;
const ST_SEMAPHORE_CREATE_INFO: u32 = 9;
const ST_BUFFER_CREATE_INFO: u32 = 12;
const ST_IMAGE_VIEW_CREATE_INFO: u32 = 15;
const ST_SHADER_MODULE_CREATE_INFO: u32 = 16;
const ST_PIPELINE_SHADER_STAGE_CREATE_INFO: u32 = 18;
const ST_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO: u32 = 19;
const ST_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO: u32 = 20;
const ST_PIPELINE_VIEWPORT_STATE_CREATE_INFO: u32 = 22;
const ST_PIPELINE_RASTERIZATION_STATE_CREATE_INFO: u32 = 23;
const ST_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO: u32 = 24;
const ST_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO: u32 = 26;
const ST_PIPELINE_DYNAMIC_STATE_CREATE_INFO: u32 = 27;
const ST_GRAPHICS_PIPELINE_CREATE_INFO: u32 = 28;
const ST_PIPELINE_LAYOUT_CREATE_INFO: u32 = 30;
const ST_DESCRIPTOR_SET_LAYOUT_CREATE_INFO: u32 = 32;
const ST_DESCRIPTOR_POOL_CREATE_INFO: u32 = 33;
const ST_DESCRIPTOR_SET_ALLOCATE_INFO: u32 = 34;
const ST_WRITE_DESCRIPTOR_SET: u32 = 35;
const ST_COMMAND_POOL_CREATE_INFO: u32 = 39;
const ST_COMMAND_BUFFER_ALLOCATE_INFO: u32 = 40;
const ST_COMMAND_BUFFER_BEGIN_INFO: u32 = 42;
const ST_RENDER_PASS_BEGIN_INFO: u32 = 43;
const ST_RENDER_PASS_CREATE_INFO: u32 = 38;
const ST_FRAMEBUFFER_CREATE_INFO: u32 = 37;
const ST_SWAPCHAIN_CREATE_INFO_KHR: u32 = 1000001000;
const ST_PRESENT_INFO_KHR: u32 = 1000001001;
const ST_WAYLAND_SURFACE_CREATE_INFO_KHR: u32 = 1000006000;
const ST_IMAGE_CREATE_INFO: u32 = 14;
const ST_SAMPLER_CREATE_INFO: u32 = 31;
const ST_IMAGE_MEMORY_BARRIER: u32 = 45;

pub const API_VERSION_1_0: u32 = 1 << 22;

pub const ApplicationInfo = extern struct {
    s_type: u32 = ST_APPLICATION_INFO,
    p_next: ?*const anyopaque = null,
    application_name: ?[*:0]const u8 = null,
    application_version: u32 = 0,
    engine_name: ?[*:0]const u8 = null,
    engine_version: u32 = 0,
    api_version: u32 = API_VERSION_1_0,
};

pub const InstanceCreateInfo = extern struct {
    s_type: u32 = ST_INSTANCE_CREATE_INFO,
    p_next: ?*const anyopaque = null,
    flags: u32 = 0,
    application_info: ?*const ApplicationInfo = null,
    enabled_layer_count: u32 = 0,
    enabled_layer_names: ?[*]const [*:0]const u8 = null,
    enabled_extension_count: u32 = 0,
    enabled_extension_names: ?[*]const [*:0]const u8 = null,
};

pub const QueueFamilyProperties = extern struct {
    queue_flags: u32,
    queue_count: u32,
    timestamp_valid_bits: u32,
    min_image_transfer_granularity: Extent3D,
};

pub const Extent2D = extern struct { width: u32, height: u32 };
pub const Extent3D = extern struct { width: u32, height: u32, depth: u32 };
pub const Offset2D = extern struct { x: i32 = 0, y: i32 = 0 };
pub const Rect2D = extern struct { offset: Offset2D = .{}, extent: Extent2D };
pub const Viewport = extern struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    min_depth: f32,
    max_depth: f32,
};

pub const DeviceQueueCreateInfo = extern struct {
    s_type: u32 = ST_DEVICE_QUEUE_CREATE_INFO,
    p_next: ?*const anyopaque = null,
    flags: u32 = 0,
    queue_family_index: u32,
    queue_count: u32 = 1,
    queue_priorities: [*]const f32,
};

// The full VkPhysicalDeviceFeatures bool block; only shader_clip_distance is
// flipped on, but the ABI needs every slot present and ordered.
pub const PhysicalDeviceFeatures = extern struct {
    robust_buffer_access: Bool32 = 0,
    full_draw_index_uint32: Bool32 = 0,
    image_cube_array: Bool32 = 0,
    independent_blend: Bool32 = 0,
    geometry_shader: Bool32 = 0,
    tessellation_shader: Bool32 = 0,
    sample_rate_shading: Bool32 = 0,
    dual_src_blend: Bool32 = 0,
    logic_op: Bool32 = 0,
    multi_draw_indirect: Bool32 = 0,
    draw_indirect_first_instance: Bool32 = 0,
    depth_clamp: Bool32 = 0,
    depth_bias_clamp: Bool32 = 0,
    fill_mode_non_solid: Bool32 = 0,
    depth_bounds: Bool32 = 0,
    wide_lines: Bool32 = 0,
    large_points: Bool32 = 0,
    alpha_to_one: Bool32 = 0,
    multi_viewport: Bool32 = 0,
    sampler_anisotropy: Bool32 = 0,
    texture_compression_etc2: Bool32 = 0,
    texture_compression_astc_ldr: Bool32 = 0,
    texture_compression_bc: Bool32 = 0,
    occlusion_query_precise: Bool32 = 0,
    pipeline_statistics_query: Bool32 = 0,
    vertex_pipeline_stores_and_atomics: Bool32 = 0,
    fragment_stores_and_atomics: Bool32 = 0,
    shader_tessellation_and_geometry_point_size: Bool32 = 0,
    shader_image_gather_extended: Bool32 = 0,
    shader_storage_image_extended_formats: Bool32 = 0,
    shader_storage_image_multisample: Bool32 = 0,
    shader_storage_image_read_without_format: Bool32 = 0,
    shader_storage_image_write_without_format: Bool32 = 0,
    shader_uniform_buffer_array_dynamic_indexing: Bool32 = 0,
    shader_sampled_image_array_dynamic_indexing: Bool32 = 0,
    shader_storage_buffer_array_dynamic_indexing: Bool32 = 0,
    shader_storage_image_array_dynamic_indexing: Bool32 = 0,
    shader_clip_distance: Bool32 = 0,
    shader_cull_distance: Bool32 = 0,
    shader_float64: Bool32 = 0,
    shader_int64: Bool32 = 0,
    shader_int16: Bool32 = 0,
    shader_resource_residency: Bool32 = 0,
    shader_resource_min_lod: Bool32 = 0,
    sparse_binding: Bool32 = 0,
    sparse_residency_buffer: Bool32 = 0,
    sparse_residency_image_2d: Bool32 = 0,
    sparse_residency_image_3d: Bool32 = 0,
    sparse_residency_2_samples: Bool32 = 0,
    sparse_residency_4_samples: Bool32 = 0,
    sparse_residency_8_samples: Bool32 = 0,
    sparse_residency_16_samples: Bool32 = 0,
    sparse_residency_aliased: Bool32 = 0,
    variable_multisample_rate: Bool32 = 0,
    inherited_queries: Bool32 = 0,
};

pub const DeviceCreateInfo = extern struct {
    s_type: u32 = ST_DEVICE_CREATE_INFO,
    p_next: ?*const anyopaque = null,
    flags: u32 = 0,
    queue_create_info_count: u32 = 1,
    queue_create_infos: [*]const DeviceQueueCreateInfo,
    enabled_layer_count: u32 = 0,
    enabled_layer_names: ?[*]const [*:0]const u8 = null,
    enabled_extension_count: u32 = 0,
    enabled_extension_names: ?[*]const [*:0]const u8 = null,
    enabled_features: ?*const PhysicalDeviceFeatures = null,
};

pub const WaylandSurfaceCreateInfoKHR = extern struct {
    s_type: u32 = ST_WAYLAND_SURFACE_CREATE_INFO_KHR,
    p_next: ?*const anyopaque = null,
    flags: u32 = 0,
    display: *anyopaque,
    surface: *anyopaque,
};

pub const SurfaceCapabilitiesKHR = extern struct {
    min_image_count: u32,
    max_image_count: u32,
    current_extent: Extent2D,
    min_image_extent: Extent2D,
    max_image_extent: Extent2D,
    max_image_array_layers: u32,
    supported_transforms: u32,
    current_transform: u32,
    supported_composite_alpha: u32,
    supported_usage_flags: u32,
};

pub const SurfaceFormatKHR = extern struct {
    format: u32,
    color_space: u32,
};

pub const SwapchainCreateInfoKHR = extern struct {
    s_type: u32 = ST_SWAPCHAIN_CREATE_INFO_KHR,
    p_next: ?*const anyopaque = null,
    flags: u32 = 0,
    surface: SurfaceKHR,
    min_image_count: u32,
    image_format: u32,
    image_color_space: u32,
    image_extent: Extent2D,
    image_array_layers: u32 = 1,
    image_usage: u32 = IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
    image_sharing_mode: u32 = SHARING_MODE_EXCLUSIVE,
    queue_family_index_count: u32 = 0,
    queue_family_indices: ?[*]const u32 = null,
    pre_transform: u32,
    composite_alpha: u32 = COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
    present_mode: u32 = PRESENT_MODE_FIFO_KHR,
    clipped: Bool32 = 1,
    old_swapchain: SwapchainKHR = NULL_HANDLE,
};

pub const ComponentMapping = extern struct {
    r: u32 = 0,
    g: u32 = 0,
    b: u32 = 0,
    a: u32 = 0,
};

pub const ImageSubresourceRange = extern struct {
    aspect_mask: u32 = IMAGE_ASPECT_COLOR_BIT,
    base_mip_level: u32 = 0,
    level_count: u32 = 1,
    base_array_layer: u32 = 0,
    layer_count: u32 = 1,
};

pub const ImageViewCreateInfo = extern struct {
    s_type: u32 = ST_IMAGE_VIEW_CREATE_INFO,
    p_next: ?*const anyopaque = null,
    flags: u32 = 0,
    image: Image,
    view_type: u32 = IMAGE_VIEW_TYPE_2D,
    format: u32,
    components: ComponentMapping = .{},
    subresource_range: ImageSubresourceRange = .{},
};

pub const AttachmentDescription = extern struct {
    flags: u32 = 0,
    format: u32,
    samples: u32 = SAMPLE_COUNT_1_BIT,
    load_op: u32,
    store_op: u32,
    stencil_load_op: u32 = ATTACHMENT_LOAD_OP_DONT_CARE,
    stencil_store_op: u32 = ATTACHMENT_STORE_OP_DONT_CARE,
    initial_layout: u32,
    final_layout: u32,
};

pub const AttachmentReference = extern struct {
    attachment: u32 = 0,
    layout: u32 = IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
};

pub const SubpassDescription = extern struct {
    flags: u32 = 0,
    pipeline_bind_point: u32 = PIPELINE_BIND_POINT_GRAPHICS,
    input_attachment_count: u32 = 0,
    input_attachments: ?[*]const AttachmentReference = null,
    color_attachment_count: u32 = 1,
    color_attachments: [*]const AttachmentReference,
    resolve_attachments: ?[*]const AttachmentReference = null,
    depth_stencil_attachment: ?*const AttachmentReference = null,
    preserve_attachment_count: u32 = 0,
    preserve_attachments: ?[*]const u32 = null,
};

pub const SubpassDependency = extern struct {
    src_subpass: u32 = SUBPASS_EXTERNAL,
    dst_subpass: u32 = 0,
    src_stage_mask: u32 = PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
    dst_stage_mask: u32 = PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
    src_access_mask: u32 = 0,
    dst_access_mask: u32 = ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
    dependency_flags: u32 = 0,
};

pub const RenderPassCreateInfo = extern struct {
    s_type: u32 = ST_RENDER_PASS_CREATE_INFO,
    p_next: ?*const anyopaque = null,
    flags: u32 = 0,
    attachment_count: u32 = 1,
    attachments: [*]const AttachmentDescription,
    subpass_count: u32 = 1,
    subpasses: [*]const SubpassDescription,
    dependency_count: u32 = 1,
    dependencies: [*]const SubpassDependency,
};

pub const FramebufferCreateInfo = extern struct {
    s_type: u32 = ST_FRAMEBUFFER_CREATE_INFO,
    p_next: ?*const anyopaque = null,
    flags: u32 = 0,
    render_pass: RenderPass,
    attachment_count: u32 = 1,
    attachments: [*]const ImageView,
    width: u32,
    height: u32,
    layers: u32 = 1,
};

pub const CommandPoolCreateInfo = extern struct {
    s_type: u32 = ST_COMMAND_POOL_CREATE_INFO,
    p_next: ?*const anyopaque = null,
    flags: u32 = COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
    queue_family_index: u32,
};

pub const CommandBufferAllocateInfo = extern struct {
    s_type: u32 = ST_COMMAND_BUFFER_ALLOCATE_INFO,
    p_next: ?*const anyopaque = null,
    command_pool: CommandPool,
    level: u32 = COMMAND_BUFFER_LEVEL_PRIMARY,
    command_buffer_count: u32 = 1,
};

pub const CommandBufferBeginInfo = extern struct {
    s_type: u32 = ST_COMMAND_BUFFER_BEGIN_INFO,
    p_next: ?*const anyopaque = null,
    flags: u32 = COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
    inheritance_info: ?*const anyopaque = null,
};

pub const ClearColorValue = extern union {
    float32: [4]f32,
    int32: [4]i32,
    uint32: [4]u32,
};

pub const ClearValue = extern union {
    color: ClearColorValue,
    depth_stencil: extern struct { depth: f32, stencil: u32 },
};

pub const RenderPassBeginInfo = extern struct {
    s_type: u32 = ST_RENDER_PASS_BEGIN_INFO,
    p_next: ?*const anyopaque = null,
    render_pass: RenderPass,
    framebuffer: Framebuffer,
    render_area: Rect2D,
    clear_value_count: u32 = 1,
    clear_values: [*]const ClearValue,
};

pub const SemaphoreCreateInfo = extern struct {
    s_type: u32 = ST_SEMAPHORE_CREATE_INFO,
    p_next: ?*const anyopaque = null,
    flags: u32 = 0,
};

pub const FenceCreateInfo = extern struct {
    s_type: u32 = ST_FENCE_CREATE_INFO,
    p_next: ?*const anyopaque = null,
    flags: u32 = FENCE_CREATE_SIGNALED_BIT,
};

pub const SubmitInfo = extern struct {
    s_type: u32 = ST_SUBMIT_INFO,
    p_next: ?*const anyopaque = null,
    wait_semaphore_count: u32 = 0,
    wait_semaphores: ?[*]const Semaphore = null,
    wait_dst_stage_mask: ?[*]const u32 = null,
    command_buffer_count: u32 = 1,
    command_buffers: [*]const *CommandBuffer,
    signal_semaphore_count: u32 = 0,
    signal_semaphores: ?[*]const Semaphore = null,
};

pub const PresentInfoKHR = extern struct {
    s_type: u32 = ST_PRESENT_INFO_KHR,
    p_next: ?*const anyopaque = null,
    wait_semaphore_count: u32 = 1,
    wait_semaphores: [*]const Semaphore,
    swapchain_count: u32 = 1,
    swapchains: [*]const SwapchainKHR,
    image_indices: [*]const u32,
    results: ?[*]Result = null,
};

pub const BufferCreateInfo = extern struct {
    s_type: u32 = ST_BUFFER_CREATE_INFO,
    p_next: ?*const anyopaque = null,
    flags: u32 = 0,
    size: DeviceSize,
    usage: u32,
    sharing_mode: u32 = SHARING_MODE_EXCLUSIVE,
    queue_family_index_count: u32 = 0,
    queue_family_indices: ?[*]const u32 = null,
};

pub const MemoryRequirements = extern struct {
    size: DeviceSize,
    alignment: DeviceSize,
    memory_type_bits: u32,
};

pub const MemoryType = extern struct {
    property_flags: u32,
    heap_index: u32,
};

pub const MemoryHeap = extern struct {
    size: DeviceSize,
    flags: u32,
};

pub const PhysicalDeviceMemoryProperties = extern struct {
    memory_type_count: u32,
    memory_types: [32]MemoryType,
    memory_heap_count: u32,
    memory_heaps: [16]MemoryHeap,
};

pub const MemoryAllocateInfo = extern struct {
    s_type: u32 = ST_MEMORY_ALLOCATE_INFO,
    p_next: ?*const anyopaque = null,
    allocation_size: DeviceSize,
    memory_type_index: u32,
};

pub const ImageCreateInfo = extern struct {
    s_type: u32 = ST_IMAGE_CREATE_INFO,
    p_next: ?*const anyopaque = null,
    flags: u32 = 0,
    image_type: u32 = IMAGE_TYPE_2D,
    format: u32,
    extent: Extent3D,
    mip_levels: u32 = 1,
    array_layers: u32 = 1,
    samples: u32 = SAMPLE_COUNT_1_BIT,
    tiling: u32 = IMAGE_TILING_OPTIMAL,
    usage: u32 = IMAGE_USAGE_TRANSFER_DST_BIT | IMAGE_USAGE_SAMPLED_BIT,
    sharing_mode: u32 = SHARING_MODE_EXCLUSIVE,
    queue_family_index_count: u32 = 0,
    queue_family_indices: ?[*]const u32 = null,
    initial_layout: u32 = IMAGE_LAYOUT_UNDEFINED,
};

pub const ImageMemoryBarrier = extern struct {
    s_type: u32 = ST_IMAGE_MEMORY_BARRIER,
    p_next: ?*const anyopaque = null,
    src_access_mask: u32,
    dst_access_mask: u32,
    old_layout: u32,
    new_layout: u32,
    src_queue_family_index: u32 = QUEUE_FAMILY_IGNORED,
    dst_queue_family_index: u32 = QUEUE_FAMILY_IGNORED,
    image: Image,
    subresource_range: ImageSubresourceRange = .{},
};

pub const Offset3D = extern struct { x: i32 = 0, y: i32 = 0, z: i32 = 0 };

pub const ImageSubresourceLayers = extern struct {
    aspect_mask: u32 = IMAGE_ASPECT_COLOR_BIT,
    mip_level: u32 = 0,
    base_array_layer: u32 = 0,
    layer_count: u32 = 1,
};

pub const BufferImageCopy = extern struct {
    buffer_offset: DeviceSize = 0,
    buffer_row_length: u32 = 0,
    buffer_image_height: u32 = 0,
    image_subresource: ImageSubresourceLayers = .{},
    image_offset: Offset3D,
    image_extent: Extent3D,
};

pub const SamplerCreateInfo = extern struct {
    s_type: u32 = ST_SAMPLER_CREATE_INFO,
    p_next: ?*const anyopaque = null,
    flags: u32 = 0,
    mag_filter: u32 = FILTER_LINEAR,
    min_filter: u32 = FILTER_LINEAR,
    mipmap_mode: u32 = SAMPLER_MIPMAP_MODE_NEAREST,
    address_mode_u: u32 = SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
    address_mode_v: u32 = SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
    address_mode_w: u32 = SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
    mip_lod_bias: f32 = 0,
    anisotropy_enable: Bool32 = 0,
    max_anisotropy: f32 = 1,
    compare_enable: Bool32 = 0,
    compare_op: u32 = 0,
    min_lod: f32 = 0,
    max_lod: f32 = 0,
    border_color: u32 = 0,
    unnormalized_coordinates: Bool32 = 0,
};

pub const Sampler = u64;

pub const DescriptorImageInfo = extern struct {
    sampler: Sampler,
    image_view: ImageView,
    image_layout: u32 = IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
};

pub const ShaderModuleCreateInfo = extern struct {
    s_type: u32 = ST_SHADER_MODULE_CREATE_INFO,
    p_next: ?*const anyopaque = null,
    flags: u32 = 0,
    code_size: usize,
    code: [*]const u32,
};

pub const PipelineShaderStageCreateInfo = extern struct {
    s_type: u32 = ST_PIPELINE_SHADER_STAGE_CREATE_INFO,
    p_next: ?*const anyopaque = null,
    flags: u32 = 0,
    stage: u32,
    module: ShaderModule,
    name: [*:0]const u8 = "main",
    specialization_info: ?*const anyopaque = null,
};

pub const PipelineVertexInputStateCreateInfo = extern struct {
    s_type: u32 = ST_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
    p_next: ?*const anyopaque = null,
    flags: u32 = 0,
    vertex_binding_description_count: u32 = 0,
    vertex_binding_descriptions: ?*const anyopaque = null,
    vertex_attribute_description_count: u32 = 0,
    vertex_attribute_descriptions: ?*const anyopaque = null,
};

pub const PipelineInputAssemblyStateCreateInfo = extern struct {
    s_type: u32 = ST_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
    p_next: ?*const anyopaque = null,
    flags: u32 = 0,
    topology: u32 = PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
    primitive_restart_enable: Bool32 = 0,
};

pub const PipelineViewportStateCreateInfo = extern struct {
    s_type: u32 = ST_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
    p_next: ?*const anyopaque = null,
    flags: u32 = 0,
    viewport_count: u32 = 1,
    viewports: ?[*]const Viewport = null,
    scissor_count: u32 = 1,
    scissors: ?[*]const Rect2D = null,
};

pub const PipelineRasterizationStateCreateInfo = extern struct {
    s_type: u32 = ST_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
    p_next: ?*const anyopaque = null,
    flags: u32 = 0,
    depth_clamp_enable: Bool32 = 0,
    rasterizer_discard_enable: Bool32 = 0,
    polygon_mode: u32 = POLYGON_MODE_FILL,
    cull_mode: u32 = CULL_MODE_NONE,
    front_face: u32 = FRONT_FACE_CLOCKWISE,
    depth_bias_enable: Bool32 = 0,
    depth_bias_constant_factor: f32 = 0,
    depth_bias_clamp: f32 = 0,
    depth_bias_slope_factor: f32 = 0,
    line_width: f32 = 1,
};

pub const PipelineMultisampleStateCreateInfo = extern struct {
    s_type: u32 = ST_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
    p_next: ?*const anyopaque = null,
    flags: u32 = 0,
    rasterization_samples: u32 = SAMPLE_COUNT_1_BIT,
    sample_shading_enable: Bool32 = 0,
    min_sample_shading: f32 = 0,
    sample_mask: ?[*]const u32 = null,
    alpha_to_coverage_enable: Bool32 = 0,
    alpha_to_one_enable: Bool32 = 0,
};

pub const PipelineColorBlendAttachmentState = extern struct {
    blend_enable: Bool32 = 1,
    src_color_blend_factor: u32 = BLEND_FACTOR_SRC_ALPHA,
    dst_color_blend_factor: u32 = BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
    color_blend_op: u32 = BLEND_OP_ADD,
    src_alpha_blend_factor: u32 = BLEND_FACTOR_ONE,
    dst_alpha_blend_factor: u32 = BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
    alpha_blend_op: u32 = BLEND_OP_ADD,
    color_write_mask: u32 = COLOR_COMPONENT_RGBA,
};

pub const PipelineColorBlendStateCreateInfo = extern struct {
    s_type: u32 = ST_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
    p_next: ?*const anyopaque = null,
    flags: u32 = 0,
    logic_op_enable: Bool32 = 0,
    logic_op: u32 = 0,
    attachment_count: u32 = 1,
    attachments: [*]const PipelineColorBlendAttachmentState,
    blend_constants: [4]f32 = .{ 0, 0, 0, 0 },
};

pub const PipelineDynamicStateCreateInfo = extern struct {
    s_type: u32 = ST_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
    p_next: ?*const anyopaque = null,
    flags: u32 = 0,
    dynamic_state_count: u32,
    dynamic_states: [*]const u32,
};

pub const PushConstantRange = extern struct {
    stage_flags: u32,
    offset: u32 = 0,
    size: u32,
};

pub const PipelineLayoutCreateInfo = extern struct {
    s_type: u32 = ST_PIPELINE_LAYOUT_CREATE_INFO,
    p_next: ?*const anyopaque = null,
    flags: u32 = 0,
    set_layout_count: u32 = 0,
    set_layouts: ?[*]const DescriptorSetLayout = null,
    push_constant_range_count: u32 = 0,
    push_constant_ranges: ?[*]const PushConstantRange = null,
};

pub const GraphicsPipelineCreateInfo = extern struct {
    s_type: u32 = ST_GRAPHICS_PIPELINE_CREATE_INFO,
    p_next: ?*const anyopaque = null,
    flags: u32 = 0,
    stage_count: u32 = 2,
    stages: [*]const PipelineShaderStageCreateInfo,
    vertex_input_state: *const PipelineVertexInputStateCreateInfo,
    input_assembly_state: *const PipelineInputAssemblyStateCreateInfo,
    tessellation_state: ?*const anyopaque = null,
    viewport_state: *const PipelineViewportStateCreateInfo,
    rasterization_state: *const PipelineRasterizationStateCreateInfo,
    multisample_state: *const PipelineMultisampleStateCreateInfo,
    depth_stencil_state: ?*const anyopaque = null,
    color_blend_state: *const PipelineColorBlendStateCreateInfo,
    dynamic_state: *const PipelineDynamicStateCreateInfo,
    layout: PipelineLayout,
    render_pass: RenderPass,
    subpass: u32 = 0,
    base_pipeline_handle: Pipeline = NULL_HANDLE,
    base_pipeline_index: i32 = -1,
};

pub const DescriptorSetLayoutBinding = extern struct {
    binding: u32,
    descriptor_type: u32,
    descriptor_count: u32 = 1,
    stage_flags: u32,
    immutable_samplers: ?*const anyopaque = null,
};

pub const DescriptorSetLayoutCreateInfo = extern struct {
    s_type: u32 = ST_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
    p_next: ?*const anyopaque = null,
    flags: u32 = 0,
    binding_count: u32,
    bindings: [*]const DescriptorSetLayoutBinding,
};

pub const DescriptorPoolSize = extern struct {
    descriptor_type: u32,
    descriptor_count: u32,
};

pub const DescriptorPoolCreateInfo = extern struct {
    s_type: u32 = ST_DESCRIPTOR_POOL_CREATE_INFO,
    p_next: ?*const anyopaque = null,
    flags: u32 = 0,
    max_sets: u32,
    pool_size_count: u32,
    pool_sizes: [*]const DescriptorPoolSize,
};

pub const DescriptorSetAllocateInfo = extern struct {
    s_type: u32 = ST_DESCRIPTOR_SET_ALLOCATE_INFO,
    p_next: ?*const anyopaque = null,
    descriptor_pool: DescriptorPool,
    descriptor_set_count: u32 = 1,
    set_layouts: [*]const DescriptorSetLayout,
};

pub const DescriptorBufferInfo = extern struct {
    buffer: Buffer,
    offset: DeviceSize = 0,
    range: DeviceSize,
};

pub const WriteDescriptorSet = extern struct {
    s_type: u32 = ST_WRITE_DESCRIPTOR_SET,
    p_next: ?*const anyopaque = null,
    dst_set: DescriptorSet,
    dst_binding: u32,
    dst_array_element: u32 = 0,
    descriptor_count: u32 = 1,
    descriptor_type: u32,
    image_info: ?[*]const DescriptorImageInfo = null,
    buffer_info: ?[*]const DescriptorBufferInfo = null,
    texel_buffer_view: ?*const anyopaque = null,
};

pub const Error = error{ LibraryLoadFailed, ProcLoadFailed };

extern "c" fn dlopen(file: [*:0]const u8, mode: c_int) ?*anyopaque;
extern "c" fn dlsym(handle: ?*anyopaque, name: [*:0]const u8) ?*anyopaque;
const RTLD_NOW: c_int = 2;

pub const VoidFn = *const fn () callconv(.c) void;
pub const GetInstanceProcAddr = *const fn (?*Instance, [*:0]const u8) callconv(.c) ?VoidFn;
pub const GetDeviceProcAddr = *const fn (*Device, [*:0]const u8) callconv(.c) ?VoidFn;

pub var get_instance_proc_addr: GetInstanceProcAddr = undefined;
var g_loaded: bool = false;

pub const GlobalFns = struct {
    vkCreateInstance: *const fn (
        *const InstanceCreateInfo,
        ?*const anyopaque,
        **Instance,
    ) callconv(.c) Result,
};

pub const InstanceFns = struct {
    vkDestroyInstance: *const fn (*Instance, ?*const anyopaque) callconv(.c) void,
    vkEnumeratePhysicalDevices: *const fn (
        *Instance,
        *u32,
        ?[*]*PhysicalDevice,
    ) callconv(.c) Result,
    vkGetPhysicalDeviceQueueFamilyProperties: *const fn (
        *PhysicalDevice,
        *u32,
        ?[*]QueueFamilyProperties,
    ) callconv(.c) void,
    vkGetPhysicalDeviceMemoryProperties: *const fn (
        *PhysicalDevice,
        *PhysicalDeviceMemoryProperties,
    ) callconv(.c) void,
    vkCreateDevice: *const fn (
        *PhysicalDevice,
        *const DeviceCreateInfo,
        ?*const anyopaque,
        **Device,
    ) callconv(.c) Result,
    vkGetDeviceProcAddr: GetDeviceProcAddr,
    vkCreateWaylandSurfaceKHR: *const fn (
        *Instance,
        *const WaylandSurfaceCreateInfoKHR,
        ?*const anyopaque,
        *SurfaceKHR,
    ) callconv(.c) Result,
    vkDestroySurfaceKHR: *const fn (*Instance, SurfaceKHR, ?*const anyopaque) callconv(.c) void,
    vkGetPhysicalDeviceSurfaceSupportKHR: *const fn (
        *PhysicalDevice,
        u32,
        SurfaceKHR,
        *Bool32,
    ) callconv(.c) Result,
    vkGetPhysicalDeviceSurfaceCapabilitiesKHR: *const fn (
        *PhysicalDevice,
        SurfaceKHR,
        *SurfaceCapabilitiesKHR,
    ) callconv(.c) Result,
    vkGetPhysicalDeviceSurfaceFormatsKHR: *const fn (
        *PhysicalDevice,
        SurfaceKHR,
        *u32,
        ?[*]SurfaceFormatKHR,
    ) callconv(.c) Result,
};

pub const DeviceFns = struct {
    vkDestroyDevice: *const fn (*Device, ?*const anyopaque) callconv(.c) void,
    vkGetDeviceQueue: *const fn (*Device, u32, u32, **Queue) callconv(.c) void,
    vkDeviceWaitIdle: *const fn (*Device) callconv(.c) Result,
    vkCreateSwapchainKHR: *const fn (
        *Device,
        *const SwapchainCreateInfoKHR,
        ?*const anyopaque,
        *SwapchainKHR,
    ) callconv(.c) Result,
    vkDestroySwapchainKHR: *const fn (*Device, SwapchainKHR, ?*const anyopaque) callconv(.c) void,
    vkGetSwapchainImagesKHR: *const fn (
        *Device,
        SwapchainKHR,
        *u32,
        ?[*]Image,
    ) callconv(.c) Result,
    vkAcquireNextImageKHR: *const fn (
        *Device,
        SwapchainKHR,
        u64,
        Semaphore,
        Fence,
        *u32,
    ) callconv(.c) Result,
    vkQueuePresentKHR: *const fn (*Queue, *const PresentInfoKHR) callconv(.c) Result,
    vkQueueSubmit: *const fn (*Queue, u32, [*]const SubmitInfo, Fence) callconv(.c) Result,
    vkCreateImageView: *const fn (
        *Device,
        *const ImageViewCreateInfo,
        ?*const anyopaque,
        *ImageView,
    ) callconv(.c) Result,
    vkDestroyImageView: *const fn (*Device, ImageView, ?*const anyopaque) callconv(.c) void,
    vkCreateRenderPass: *const fn (
        *Device,
        *const RenderPassCreateInfo,
        ?*const anyopaque,
        *RenderPass,
    ) callconv(.c) Result,
    vkDestroyRenderPass: *const fn (*Device, RenderPass, ?*const anyopaque) callconv(.c) void,
    vkCreateFramebuffer: *const fn (
        *Device,
        *const FramebufferCreateInfo,
        ?*const anyopaque,
        *Framebuffer,
    ) callconv(.c) Result,
    vkDestroyFramebuffer: *const fn (*Device, Framebuffer, ?*const anyopaque) callconv(.c) void,
    vkCreateCommandPool: *const fn (
        *Device,
        *const CommandPoolCreateInfo,
        ?*const anyopaque,
        *CommandPool,
    ) callconv(.c) Result,
    vkDestroyCommandPool: *const fn (*Device, CommandPool, ?*const anyopaque) callconv(.c) void,
    vkAllocateCommandBuffers: *const fn (
        *Device,
        *const CommandBufferAllocateInfo,
        [*]*CommandBuffer,
    ) callconv(.c) Result,
    vkBeginCommandBuffer: *const fn (
        *CommandBuffer,
        *const CommandBufferBeginInfo,
    ) callconv(.c) Result,
    vkEndCommandBuffer: *const fn (*CommandBuffer) callconv(.c) Result,
    vkCmdBeginRenderPass: *const fn (
        *CommandBuffer,
        *const RenderPassBeginInfo,
        u32,
    ) callconv(.c) void,
    vkCmdEndRenderPass: *const fn (*CommandBuffer) callconv(.c) void,
    vkCmdBindPipeline: *const fn (*CommandBuffer, u32, Pipeline) callconv(.c) void,
    vkCmdSetViewport: *const fn (*CommandBuffer, u32, u32, [*]const Viewport) callconv(.c) void,
    vkCmdSetScissor: *const fn (*CommandBuffer, u32, u32, [*]const Rect2D) callconv(.c) void,
    vkCmdPushConstants: *const fn (
        *CommandBuffer,
        PipelineLayout,
        u32,
        u32,
        u32,
        *const anyopaque,
    ) callconv(.c) void,
    vkCmdBindDescriptorSets: *const fn (
        *CommandBuffer,
        u32,
        PipelineLayout,
        u32,
        u32,
        [*]const DescriptorSet,
        u32,
        ?[*]const u32,
    ) callconv(.c) void,
    vkCmdDraw: *const fn (*CommandBuffer, u32, u32, u32, u32) callconv(.c) void,
    vkCreateSemaphore: *const fn (
        *Device,
        *const SemaphoreCreateInfo,
        ?*const anyopaque,
        *Semaphore,
    ) callconv(.c) Result,
    vkDestroySemaphore: *const fn (*Device, Semaphore, ?*const anyopaque) callconv(.c) void,
    vkCreateFence: *const fn (
        *Device,
        *const FenceCreateInfo,
        ?*const anyopaque,
        *Fence,
    ) callconv(.c) Result,
    vkDestroyFence: *const fn (*Device, Fence, ?*const anyopaque) callconv(.c) void,
    vkWaitForFences: *const fn (*Device, u32, [*]const Fence, Bool32, u64) callconv(.c) Result,
    vkResetFences: *const fn (*Device, u32, [*]const Fence) callconv(.c) Result,
    vkCreateBuffer: *const fn (
        *Device,
        *const BufferCreateInfo,
        ?*const anyopaque,
        *Buffer,
    ) callconv(.c) Result,
    vkDestroyBuffer: *const fn (*Device, Buffer, ?*const anyopaque) callconv(.c) void,
    vkGetBufferMemoryRequirements: *const fn (
        *Device,
        Buffer,
        *MemoryRequirements,
    ) callconv(.c) void,
    vkAllocateMemory: *const fn (
        *Device,
        *const MemoryAllocateInfo,
        ?*const anyopaque,
        *DeviceMemory,
    ) callconv(.c) Result,
    vkFreeMemory: *const fn (*Device, DeviceMemory, ?*const anyopaque) callconv(.c) void,
    vkBindBufferMemory: *const fn (*Device, Buffer, DeviceMemory, DeviceSize) callconv(.c) Result,
    vkMapMemory: *const fn (
        *Device,
        DeviceMemory,
        DeviceSize,
        DeviceSize,
        u32,
        **anyopaque,
    ) callconv(.c) Result,
    vkCreateShaderModule: *const fn (
        *Device,
        *const ShaderModuleCreateInfo,
        ?*const anyopaque,
        *ShaderModule,
    ) callconv(.c) Result,
    vkDestroyShaderModule: *const fn (*Device, ShaderModule, ?*const anyopaque) callconv(.c) void,
    vkCreatePipelineLayout: *const fn (
        *Device,
        *const PipelineLayoutCreateInfo,
        ?*const anyopaque,
        *PipelineLayout,
    ) callconv(.c) Result,
    vkDestroyPipelineLayout: *const fn (
        *Device,
        PipelineLayout,
        ?*const anyopaque,
    ) callconv(.c) void,
    vkCreateGraphicsPipelines: *const fn (
        *Device,
        u64,
        u32,
        [*]const GraphicsPipelineCreateInfo,
        ?*const anyopaque,
        [*]Pipeline,
    ) callconv(.c) Result,
    vkDestroyPipeline: *const fn (*Device, Pipeline, ?*const anyopaque) callconv(.c) void,
    vkCreateDescriptorSetLayout: *const fn (
        *Device,
        *const DescriptorSetLayoutCreateInfo,
        ?*const anyopaque,
        *DescriptorSetLayout,
    ) callconv(.c) Result,
    vkDestroyDescriptorSetLayout: *const fn (
        *Device,
        DescriptorSetLayout,
        ?*const anyopaque,
    ) callconv(.c) void,
    vkCreateDescriptorPool: *const fn (
        *Device,
        *const DescriptorPoolCreateInfo,
        ?*const anyopaque,
        *DescriptorPool,
    ) callconv(.c) Result,
    vkDestroyDescriptorPool: *const fn (
        *Device,
        DescriptorPool,
        ?*const anyopaque,
    ) callconv(.c) void,
    vkAllocateDescriptorSets: *const fn (
        *Device,
        *const DescriptorSetAllocateInfo,
        [*]DescriptorSet,
    ) callconv(.c) Result,
    vkUpdateDescriptorSets: *const fn (
        *Device,
        u32,
        [*]const WriteDescriptorSet,
        u32,
        ?*const anyopaque,
    ) callconv(.c) void,
    vkCreateImage: *const fn (
        *Device,
        *const ImageCreateInfo,
        ?*const anyopaque,
        *Image,
    ) callconv(.c) Result,
    vkDestroyImage: *const fn (*Device, Image, ?*const anyopaque) callconv(.c) void,
    vkGetImageMemoryRequirements: *const fn (*Device, Image, *MemoryRequirements) callconv(.c) void,
    vkBindImageMemory: *const fn (*Device, Image, DeviceMemory, DeviceSize) callconv(.c) Result,
    vkCmdPipelineBarrier: *const fn (
        *CommandBuffer,
        u32,
        u32,
        u32,
        u32,
        ?*const anyopaque,
        u32,
        ?*const anyopaque,
        u32,
        ?[*]const ImageMemoryBarrier,
    ) callconv(.c) void,
    vkCmdCopyBufferToImage: *const fn (
        *CommandBuffer,
        Buffer,
        Image,
        u32,
        u32,
        [*]const BufferImageCopy,
    ) callconv(.c) void,
    vkCreateSampler: *const fn (
        *Device,
        *const SamplerCreateInfo,
        ?*const anyopaque,
        *Sampler,
    ) callconv(.c) Result,
    vkDestroySampler: *const fn (*Device, Sampler, ?*const anyopaque) callconv(.c) void,
    vkQueueWaitIdle: *const fn (*Queue) callconv(.c) Result,
    vkResetCommandBuffer: *const fn (*CommandBuffer, u32) callconv(.c) Result,
};

pub var global: GlobalFns = undefined;

pub fn load() Error!void {
    if (g_loaded) return;
    const handle = dlopen("libvulkan.so.1", RTLD_NOW) orelse return error.LibraryLoadFailed;
    const gipa = dlsym(handle, "vkGetInstanceProcAddr") orelse return error.LibraryLoadFailed;
    get_instance_proc_addr = @ptrCast(@alignCast(gipa));
    inline for (@typeInfo(GlobalFns).@"struct".fields) |field| {
        const proc = get_instance_proc_addr(null, field.name) orelse
            return error.ProcLoadFailed;
        @field(global, field.name) = @ptrCast(proc);
    }
    g_loaded = true;
    std.debug.assert(g_loaded);
}

pub fn load_instance_fns(instance: *Instance, fns: *InstanceFns) Error!void {
    std.debug.assert(g_loaded);
    std.debug.assert(@typeInfo(InstanceFns).@"struct".fields.len >= 2);
    inline for (@typeInfo(InstanceFns).@"struct".fields) |field| {
        const proc = get_instance_proc_addr(instance, field.name) orelse
            return error.ProcLoadFailed;
        @field(fns, field.name) = @ptrCast(proc);
    }
}

pub fn load_device_fns(
    device: *Device,
    get_device_proc_addr: GetDeviceProcAddr,
    fns: *DeviceFns,
) Error!void {
    std.debug.assert(g_loaded);
    std.debug.assert(@typeInfo(DeviceFns).@"struct".fields.len >= 2);
    inline for (@typeInfo(DeviceFns).@"struct".fields) |field| {
        const proc = get_device_proc_addr(device, field.name) orelse
            return error.ProcLoadFailed;
        @field(fns, field.name) = @ptrCast(proc);
    }
}
