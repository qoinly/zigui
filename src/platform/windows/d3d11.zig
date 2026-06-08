// Direct3D 11 bindings: device + immediate-context vtable prefixes (typed only
// up to the methods the renderer calls; earlier slots are pointer-sized
// placeholders so the ABI slot order is exact), the resource descriptors, the
// all-in-one device+swapchain create, and runtime HLSL compilation via a
// dynamically loaded d3dcompiler_47.dll.

const win32 = @import("win32.zig");
const dxgi = @import("dxgi.zig");

const HRESULT = win32.HRESULT;
const GUID = win32.GUID;
const HWND = win32.HWND;
const HMODULE = win32.HMODULE;

pub const D3D_DRIVER_TYPE_HARDWARE: u32 = 1;
pub const D3D_FEATURE_LEVEL_11_0: u32 = 0xb000;
pub const D3D11_SDK_VERSION: u32 = 7;
pub const D3D11_CREATE_DEVICE_BGRA_SUPPORT: u32 = 0x20;

pub const D3D11_USAGE_DEFAULT: u32 = 0;
pub const D3D11_USAGE_IMMUTABLE: u32 = 1;
pub const D3D11_USAGE_DYNAMIC: u32 = 2;

pub const D3D11_BIND_VERTEX_BUFFER: u32 = 0x1;
pub const D3D11_BIND_CONSTANT_BUFFER: u32 = 0x4;
pub const D3D11_BIND_SHADER_RESOURCE: u32 = 0x8;
pub const D3D11_BIND_RENDER_TARGET: u32 = 0x20;

pub const D3D11_CPU_ACCESS_WRITE: u32 = 0x10000;
pub const D3D11_RESOURCE_MISC_BUFFER_STRUCTURED: u32 = 0x40;

pub const D3D11_MAP_WRITE_DISCARD: u32 = 4;

pub const D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST: u32 = 4;
pub const D3D11_SRV_DIMENSION_BUFFER: u32 = 1;
pub const D3D11_SRV_DIMENSION_TEXTURE2D: u32 = 4;

pub const D3D11_BLEND_ZERO: u32 = 1;
pub const D3D11_BLEND_ONE: u32 = 2;
pub const D3D11_BLEND_SRC_ALPHA: u32 = 5;
pub const D3D11_BLEND_INV_SRC_ALPHA: u32 = 6;
pub const D3D11_BLEND_OP_ADD: u32 = 1;
pub const D3D11_COLOR_WRITE_ENABLE_ALL: u8 = 0x0F;

pub const D3D11_FILTER_MIN_MAG_MIP_LINEAR: u32 = 0x15;
pub const D3D11_TEXTURE_ADDRESS_CLAMP: u32 = 3;
pub const D3D11_COMPARISON_NEVER: u32 = 1;
pub const D3D11_FILL_SOLID: u32 = 3;
pub const D3D11_CULL_NONE: u32 = 1;

pub const D3D11_BUFFER_DESC = extern struct {
    ByteWidth: u32,
    Usage: u32,
    BindFlags: u32,
    CPUAccessFlags: u32,
    MiscFlags: u32,
    StructureByteStride: u32,
};

pub const D3D11_TEXTURE2D_DESC = extern struct {
    Width: u32,
    Height: u32,
    MipLevels: u32,
    ArraySize: u32,
    Format: u32,
    SampleDesc: dxgi.DXGI_SAMPLE_DESC,
    Usage: u32,
    BindFlags: u32,
    CPUAccessFlags: u32,
    MiscFlags: u32,
};

pub const D3D11_SUBRESOURCE_DATA = extern struct {
    pSysMem: *const anyopaque,
    SysMemPitch: u32,
    SysMemSlicePitch: u32,
};

pub const D3D11_MAPPED_SUBRESOURCE = extern struct {
    pData: ?*anyopaque,
    RowPitch: u32,
    DepthPitch: u32,
};

pub const D3D11_BOX = extern struct {
    left: u32,
    top: u32,
    front: u32,
    right: u32,
    bottom: u32,
    back: u32,
};

pub const D3D11_VIEWPORT = extern struct {
    TopLeftX: f32,
    TopLeftY: f32,
    Width: f32,
    Height: f32,
    MinDepth: f32,
    MaxDepth: f32,
};

// The union region (4 UINTs) covers every view dimension we use; for a
// structured-buffer SRV only the first two (FirstElement, NumElements) matter.
pub const D3D11_SHADER_RESOURCE_VIEW_DESC = extern struct {
    Format: u32,
    ViewDimension: u32,
    u0: u32 = 0,
    u1: u32 = 0,
    u2: u32 = 0,
    u3: u32 = 0,
};

pub const D3D11_RENDER_TARGET_BLEND_DESC = extern struct {
    BlendEnable: win32.BOOL,
    SrcBlend: u32,
    DestBlend: u32,
    BlendOp: u32,
    SrcBlendAlpha: u32,
    DestBlendAlpha: u32,
    BlendOpAlpha: u32,
    RenderTargetWriteMask: u8,
};

pub const D3D11_BLEND_DESC = extern struct {
    AlphaToCoverageEnable: win32.BOOL,
    IndependentBlendEnable: win32.BOOL,
    RenderTarget: [8]D3D11_RENDER_TARGET_BLEND_DESC,
};

pub const D3D11_SAMPLER_DESC = extern struct {
    Filter: u32,
    AddressU: u32,
    AddressV: u32,
    AddressW: u32,
    MipLODBias: f32,
    MaxAnisotropy: u32,
    ComparisonFunc: u32,
    BorderColor: [4]f32,
    MinLOD: f32,
    MaxLOD: f32,
};

pub const D3D11_RASTERIZER_DESC = extern struct {
    FillMode: u32,
    CullMode: u32,
    FrontCounterClockwise: win32.BOOL,
    DepthBias: i32,
    DepthBiasClamp: f32,
    SlopeScaledDepthBias: f32,
    DepthClipEnable: win32.BOOL,
    ScissorEnable: win32.BOOL,
    MultisampleEnable: win32.BOOL,
    AntialiasedLineEnable: win32.BOOL,
};

pub const ID3D11Device = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*ID3D11Device) callconv(.winapi) u32,
        CreateBuffer: *const fn (
            *ID3D11Device,
            *const D3D11_BUFFER_DESC,
            ?*const D3D11_SUBRESOURCE_DATA,
            *?*anyopaque,
        ) callconv(.winapi) HRESULT,
        CreateTexture1D: *const anyopaque,
        CreateTexture2D: *const fn (
            *ID3D11Device,
            *const D3D11_TEXTURE2D_DESC,
            ?*const D3D11_SUBRESOURCE_DATA,
            *?*anyopaque,
        ) callconv(.winapi) HRESULT,
        CreateTexture3D: *const anyopaque,
        CreateShaderResourceView: *const fn (
            *ID3D11Device,
            *anyopaque,
            ?*const D3D11_SHADER_RESOURCE_VIEW_DESC,
            *?*anyopaque,
        ) callconv(.winapi) HRESULT,
        CreateUnorderedAccessView: *const anyopaque,
        CreateRenderTargetView: *const fn (
            *ID3D11Device,
            *anyopaque,
            ?*const anyopaque,
            *?*anyopaque,
        ) callconv(.winapi) HRESULT,
        CreateDepthStencilView: *const anyopaque,
        CreateInputLayout: *const anyopaque,
        CreateVertexShader: *const fn (
            *ID3D11Device,
            *const anyopaque,
            usize,
            ?*anyopaque,
            *?*anyopaque,
        ) callconv(.winapi) HRESULT,
        CreateGeometryShader: *const anyopaque,
        CreateGeometryShaderWithStreamOutput: *const anyopaque,
        CreatePixelShader: *const fn (
            *ID3D11Device,
            *const anyopaque,
            usize,
            ?*anyopaque,
            *?*anyopaque,
        ) callconv(.winapi) HRESULT,
        CreateHullShader: *const anyopaque,
        CreateDomainShader: *const anyopaque,
        CreateComputeShader: *const anyopaque,
        CreateClassLinkage: *const anyopaque,
        CreateBlendState: *const fn (
            *ID3D11Device,
            *const D3D11_BLEND_DESC,
            *?*anyopaque,
        ) callconv(.winapi) HRESULT,
        CreateDepthStencilState: *const anyopaque,
        CreateRasterizerState: *const fn (
            *ID3D11Device,
            *const D3D11_RASTERIZER_DESC,
            *?*anyopaque,
        ) callconv(.winapi) HRESULT,
        CreateSamplerState: *const fn (
            *ID3D11Device,
            *const D3D11_SAMPLER_DESC,
            *?*anyopaque,
        ) callconv(.winapi) HRESULT,
        CreateQuery: *const anyopaque,
        CreatePredicate: *const anyopaque,
        CreateCounter: *const anyopaque,
        CreateDeferredContext: *const anyopaque,
        OpenSharedResource: *const anyopaque,
        CheckFormatSupport: *const anyopaque,
        CheckMultisampleQualityLevels: *const anyopaque,
        CheckCounterInfo: *const anyopaque,
        CheckCounter: *const anyopaque,
        CheckFeatureSupport: *const anyopaque,
        GetPrivateData: *const anyopaque,
        SetPrivateData: *const anyopaque,
        SetPrivateDataInterface: *const anyopaque,
        GetFeatureLevel: *const anyopaque,
        GetCreationFlags: *const anyopaque,
        GetDeviceRemovedReason: *const anyopaque,
        GetImmediateContext: *const fn (
            *ID3D11Device,
            *?*ID3D11DeviceContext,
        ) callconv(.winapi) void,
    };

    pub fn create_buffer(
        self: *ID3D11Device,
        desc: *const D3D11_BUFFER_DESC,
        init: ?*const D3D11_SUBRESOURCE_DATA,
        out: *?*anyopaque,
    ) HRESULT {
        return self.vtable.CreateBuffer(self, desc, init, out);
    }
    pub fn create_texture2d(
        self: *ID3D11Device,
        desc: *const D3D11_TEXTURE2D_DESC,
        init: ?*const D3D11_SUBRESOURCE_DATA,
        out: *?*anyopaque,
    ) HRESULT {
        return self.vtable.CreateTexture2D(self, desc, init, out);
    }
    pub fn create_srv(
        self: *ID3D11Device,
        res: *anyopaque,
        desc: ?*const D3D11_SHADER_RESOURCE_VIEW_DESC,
        out: *?*anyopaque,
    ) HRESULT {
        return self.vtable.CreateShaderResourceView(self, res, desc, out);
    }
    pub fn create_rtv(self: *ID3D11Device, res: *anyopaque, out: *?*anyopaque) HRESULT {
        return self.vtable.CreateRenderTargetView(self, res, null, out);
    }
    pub fn create_vertex_shader(
        self: *ID3D11Device,
        code: *const anyopaque,
        len: usize,
        out: *?*anyopaque,
    ) HRESULT {
        return self.vtable.CreateVertexShader(self, code, len, null, out);
    }
    pub fn create_pixel_shader(
        self: *ID3D11Device,
        code: *const anyopaque,
        len: usize,
        out: *?*anyopaque,
    ) HRESULT {
        return self.vtable.CreatePixelShader(self, code, len, null, out);
    }
    pub fn create_blend_state(
        self: *ID3D11Device,
        desc: *const D3D11_BLEND_DESC,
        out: *?*anyopaque,
    ) HRESULT {
        return self.vtable.CreateBlendState(self, desc, out);
    }
    pub fn create_rasterizer_state(
        self: *ID3D11Device,
        desc: *const D3D11_RASTERIZER_DESC,
        out: *?*anyopaque,
    ) HRESULT {
        return self.vtable.CreateRasterizerState(self, desc, out);
    }
    pub fn create_sampler_state(
        self: *ID3D11Device,
        desc: *const D3D11_SAMPLER_DESC,
        out: *?*anyopaque,
    ) HRESULT {
        return self.vtable.CreateSamplerState(self, desc, out);
    }
    pub fn get_immediate_context(self: *ID3D11Device) ?*ID3D11DeviceContext {
        var ctx: ?*ID3D11DeviceContext = null;
        self.vtable.GetImmediateContext(self, &ctx);
        return ctx;
    }
    pub fn release(self: *ID3D11Device) void {
        _ = self.vtable.Release(self);
    }
};

pub const ID3D11DeviceContext = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*ID3D11DeviceContext) callconv(.winapi) u32,
        GetDevice: *const anyopaque,
        GetPrivateData: *const anyopaque,
        SetPrivateData: *const anyopaque,
        SetPrivateDataInterface: *const anyopaque,
        VSSetConstantBuffers: *const fn (
            *ID3D11DeviceContext,
            u32,
            u32,
            [*]const ?*anyopaque,
        ) callconv(.winapi) void,
        PSSetShaderResources: *const fn (
            *ID3D11DeviceContext,
            u32,
            u32,
            [*]const ?*anyopaque,
        ) callconv(.winapi) void,
        PSSetShader: *const fn (
            *ID3D11DeviceContext,
            ?*anyopaque,
            ?*const anyopaque,
            u32,
        ) callconv(.winapi) void,
        PSSetSamplers: *const fn (
            *ID3D11DeviceContext,
            u32,
            u32,
            [*]const ?*anyopaque,
        ) callconv(.winapi) void,
        VSSetShader: *const fn (
            *ID3D11DeviceContext,
            ?*anyopaque,
            ?*const anyopaque,
            u32,
        ) callconv(.winapi) void,
        DrawIndexed: *const anyopaque,
        Draw: *const anyopaque,
        Map: *const fn (
            *ID3D11DeviceContext,
            *anyopaque,
            u32,
            u32,
            u32,
            *D3D11_MAPPED_SUBRESOURCE,
        ) callconv(.winapi) HRESULT,
        Unmap: *const fn (*ID3D11DeviceContext, *anyopaque, u32) callconv(.winapi) void,
        PSSetConstantBuffers: *const fn (
            *ID3D11DeviceContext,
            u32,
            u32,
            [*]const ?*anyopaque,
        ) callconv(.winapi) void,
        IASetInputLayout: *const anyopaque,
        IASetVertexBuffers: *const anyopaque,
        IASetIndexBuffer: *const anyopaque,
        DrawIndexedInstanced: *const anyopaque,
        DrawInstanced: *const fn (*ID3D11DeviceContext, u32, u32, u32, u32) callconv(.winapi) void,
        GSSetConstantBuffers: *const anyopaque,
        GSSetShader: *const anyopaque,
        IASetPrimitiveTopology: *const fn (*ID3D11DeviceContext, u32) callconv(.winapi) void,
        VSSetShaderResources: *const fn (
            *ID3D11DeviceContext,
            u32,
            u32,
            [*]const ?*anyopaque,
        ) callconv(.winapi) void,
        VSSetSamplers: *const anyopaque,
        Begin: *const anyopaque,
        End: *const anyopaque,
        GetData: *const anyopaque,
        SetPredication: *const anyopaque,
        GSSetShaderResources: *const anyopaque,
        GSSetSamplers: *const anyopaque,
        OMSetRenderTargets: *const fn (
            *ID3D11DeviceContext,
            u32,
            [*]const ?*anyopaque,
            ?*anyopaque,
        ) callconv(.winapi) void,
        OMSetRenderTargetsAndUnorderedAccessViews: *const anyopaque,
        OMSetBlendState: *const fn (
            *ID3D11DeviceContext,
            ?*anyopaque,
            ?*const [4]f32,
            u32,
        ) callconv(.winapi) void,
        OMSetDepthStencilState: *const anyopaque,
        SOSetTargets: *const anyopaque,
        DrawAuto: *const anyopaque,
        DrawIndexedInstancedIndirect: *const anyopaque,
        DrawInstancedIndirect: *const anyopaque,
        Dispatch: *const anyopaque,
        DispatchIndirect: *const anyopaque,
        RSSetState: *const fn (*ID3D11DeviceContext, ?*anyopaque) callconv(.winapi) void,
        RSSetViewports: *const fn (
            *ID3D11DeviceContext,
            u32,
            [*]const D3D11_VIEWPORT,
        ) callconv(.winapi) void,
        RSSetScissorRects: *const fn (
            *ID3D11DeviceContext,
            u32,
            [*]const win32.RECT,
        ) callconv(.winapi) void,
        CopySubresourceRegion: *const anyopaque,
        CopyResource: *const fn (
            *ID3D11DeviceContext,
            *anyopaque,
            *anyopaque,
        ) callconv(.winapi) void,
        UpdateSubresource: *const fn (
            *ID3D11DeviceContext,
            *anyopaque,
            u32,
            ?*const D3D11_BOX,
            *const anyopaque,
            u32,
            u32,
        ) callconv(.winapi) void,
        CopyStructureCount: *const anyopaque,
        ClearRenderTargetView: *const fn (
            *ID3D11DeviceContext,
            *anyopaque,
            *const [4]f32,
        ) callconv(.winapi) void,
    };

    pub fn vs_set_constant_buffers(
        self: *ID3D11DeviceContext,
        start: u32,
        n: u32,
        b: [*]const ?*anyopaque,
    ) void {
        self.vtable.VSSetConstantBuffers(self, start, n, b);
    }
    pub fn ps_set_constant_buffers(
        self: *ID3D11DeviceContext,
        start: u32,
        n: u32,
        b: [*]const ?*anyopaque,
    ) void {
        self.vtable.PSSetConstantBuffers(self, start, n, b);
    }
    pub fn ps_set_shader_resources(
        self: *ID3D11DeviceContext,
        start: u32,
        n: u32,
        v: [*]const ?*anyopaque,
    ) void {
        self.vtable.PSSetShaderResources(self, start, n, v);
    }
    pub fn ps_set_shader(self: *ID3D11DeviceContext, shader: ?*anyopaque) void {
        self.vtable.PSSetShader(self, shader, null, 0);
    }
    pub fn ps_set_samplers(
        self: *ID3D11DeviceContext,
        start: u32,
        n: u32,
        s: [*]const ?*anyopaque,
    ) void {
        self.vtable.PSSetSamplers(self, start, n, s);
    }
    pub fn vs_set_shader(self: *ID3D11DeviceContext, shader: ?*anyopaque) void {
        self.vtable.VSSetShader(self, shader, null, 0);
    }
    pub fn map(
        self: *ID3D11DeviceContext,
        res: *anyopaque,
        sub: u32,
        map_type: u32,
        mapped: *D3D11_MAPPED_SUBRESOURCE,
    ) HRESULT {
        return self.vtable.Map(self, res, sub, map_type, 0, mapped);
    }
    pub fn unmap(self: *ID3D11DeviceContext, res: *anyopaque, sub: u32) void {
        self.vtable.Unmap(self, res, sub);
    }
    pub fn draw_instanced(self: *ID3D11DeviceContext, vc: u32, ic: u32, sv: u32, si: u32) void {
        self.vtable.DrawInstanced(self, vc, ic, sv, si);
    }
    pub fn ia_set_primitive_topology(self: *ID3D11DeviceContext, topo: u32) void {
        self.vtable.IASetPrimitiveTopology(self, topo);
    }
    pub fn vs_set_shader_resources(
        self: *ID3D11DeviceContext,
        start: u32,
        n: u32,
        v: [*]const ?*anyopaque,
    ) void {
        self.vtable.VSSetShaderResources(self, start, n, v);
    }
    pub fn om_set_render_targets(
        self: *ID3D11DeviceContext,
        n: u32,
        rtvs: [*]const ?*anyopaque,
        dsv: ?*anyopaque,
    ) void {
        self.vtable.OMSetRenderTargets(self, n, rtvs, dsv);
    }
    pub fn om_set_blend_state(
        self: *ID3D11DeviceContext,
        blend: ?*anyopaque,
        factor: ?*const [4]f32,
        mask: u32,
    ) void {
        self.vtable.OMSetBlendState(self, blend, factor, mask);
    }
    pub fn rs_set_state(self: *ID3D11DeviceContext, raster: ?*anyopaque) void {
        self.vtable.RSSetState(self, raster);
    }
    pub fn rs_set_viewports(self: *ID3D11DeviceContext, n: u32, vps: [*]const D3D11_VIEWPORT) void {
        self.vtable.RSSetViewports(self, n, vps);
    }
    pub fn rs_set_scissor_rects(
        self: *ID3D11DeviceContext,
        n: u32,
        rects: [*]const win32.RECT,
    ) void {
        self.vtable.RSSetScissorRects(self, n, rects);
    }
    pub fn copy_resource(self: *ID3D11DeviceContext, dst: *anyopaque, src: *anyopaque) void {
        self.vtable.CopyResource(self, dst, src);
    }
    pub fn update_subresource(
        self: *ID3D11DeviceContext,
        res: *anyopaque,
        sub: u32,
        box: ?*const D3D11_BOX,
        data: *const anyopaque,
        row_pitch: u32,
        depth_pitch: u32,
    ) void {
        self.vtable.UpdateSubresource(self, res, sub, box, data, row_pitch, depth_pitch);
    }
    pub fn clear_render_target_view(
        self: *ID3D11DeviceContext,
        rtv: *anyopaque,
        color: *const [4]f32,
    ) void {
        self.vtable.ClearRenderTargetView(self, rtv, color);
    }
    pub fn release(self: *ID3D11DeviceContext) void {
        _ = self.vtable.Release(self);
    }
};

pub const ID3DBlob = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*ID3DBlob) callconv(.winapi) u32,
        GetBufferPointer: *const fn (*ID3DBlob) callconv(.winapi) *anyopaque,
        GetBufferSize: *const fn (*ID3DBlob) callconv(.winapi) usize,
    };

    pub fn buffer_pointer(self: *ID3DBlob) *anyopaque {
        return self.vtable.GetBufferPointer(self);
    }
    pub fn buffer_size(self: *ID3DBlob) usize {
        return self.vtable.GetBufferSize(self);
    }
    pub fn release(self: *ID3DBlob) void {
        _ = self.vtable.Release(self);
    }
};

pub const PFN_D3DCompile = *const fn (
    src_data: *const anyopaque,
    src_size: usize,
    source_name: ?[*:0]const u8,
    defines: ?*const anyopaque,
    include: ?*anyopaque,
    entrypoint: [*:0]const u8,
    target: [*:0]const u8,
    flags1: u32,
    flags2: u32,
    code: *?*ID3DBlob,
    errors: *?*ID3DBlob,
) callconv(.winapi) HRESULT;

pub extern "d3d11" fn D3D11CreateDeviceAndSwapChain(
    adapter: ?*anyopaque,
    driver_type: u32,
    software: ?HMODULE,
    flags: u32,
    feature_levels: ?[*]const u32,
    num_feature_levels: u32,
    sdk_version: u32,
    swap_chain_desc: *const dxgi.DXGI_SWAP_CHAIN_DESC,
    swap_chain: *?*dxgi.IDXGISwapChain,
    device: *?*ID3D11Device,
    feature_level: ?*u32,
    immediate_context: *?*ID3D11DeviceContext,
) callconv(.winapi) HRESULT;
