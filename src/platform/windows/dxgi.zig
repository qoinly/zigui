// DXGI bindings. The IDXGISwapChain vtable is only declared up to the last slot
// we call; earlier unused slots are pointer-sized placeholders so the call-site
// slot indices still line up with the COM ABI.

const win32 = @import("win32.zig");
const com = @import("com.zig");

const HRESULT = win32.HRESULT;
const GUID = win32.GUID;
const HWND = win32.HWND;
const BOOL = win32.BOOL;
const HANDLE = win32.HANDLE;

pub const DXGI_FORMAT_UNKNOWN: u32 = 0;
pub const DXGI_FORMAT_R8G8B8A8_UNORM: u32 = 28;
pub const DXGI_FORMAT_R8G8_UNORM: u32 = 49;
pub const DXGI_FORMAT_R8_UNORM: u32 = 61;
pub const DXGI_FORMAT_B8G8R8A8_UNORM: u32 = 87;

pub const DXGI_USAGE_RENDER_TARGET_OUTPUT: u32 = 0x00000020;

pub const DXGI_SWAP_EFFECT_DISCARD: u32 = 0;
pub const DXGI_SWAP_EFFECT_FLIP_DISCARD: u32 = 4;

pub const DXGI_RATIONAL = extern struct {
    Numerator: u32 = 0,
    Denominator: u32 = 0,
};

pub const DXGI_MODE_DESC = extern struct {
    Width: u32 = 0,
    Height: u32 = 0,
    RefreshRate: DXGI_RATIONAL = .{},
    Format: u32 = 0,
    ScanlineOrdering: u32 = 0,
    Scaling: u32 = 0,
};

pub const DXGI_SAMPLE_DESC = extern struct {
    Count: u32 = 1,
    Quality: u32 = 0,
};

pub const DXGI_SWAP_CHAIN_DESC = extern struct {
    BufferDesc: DXGI_MODE_DESC = .{},
    SampleDesc: DXGI_SAMPLE_DESC = .{},
    BufferUsage: u32 = 0,
    BufferCount: u32 = 0,
    OutputWindow: ?HWND = null,
    Windowed: BOOL = win32.TRUE,
    SwapEffect: u32 = 0,
    Flags: u32 = 0,
};

// __uuidof(ID3D11Texture2D), for IDXGISwapChain::GetBuffer.
pub const IID_ID3D11Texture2D = com.guid(
    0x6f15aaf2,
    0xd208,
    0x4e89,
    0x9a,
    0xb4,
    0x48,
    0x95,
    0x35,
    0xd3,
    0x4f,
    0x9c,
);

pub const IID_IDXGIResource = com.guid(
    0x035f3ab4,
    0x482e,
    0x4e50,
    0xb4,
    0x1f,
    0x8a,
    0x7f,
    0x8b,
    0xd8,
    0x96,
    0x0b,
);

pub const IID_IDXGIKeyedMutex = com.guid(
    0x9d8e1289,
    0xd7b3,
    0x465f,
    0x81,
    0x26,
    0x25,
    0x0e,
    0x34,
    0x9a,
    0xf8,
    0x5d,
);

pub const IDXGIResource = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (
            *IDXGIResource,
            *const GUID,
            *?*anyopaque,
        ) callconv(.winapi) HRESULT,
        AddRef: *const anyopaque,
        Release: *const fn (*IDXGIResource) callconv(.winapi) u32,
        SetPrivateData: *const anyopaque,
        SetPrivateDataInterface: *const anyopaque,
        GetPrivateData: *const anyopaque,
        GetParent: *const anyopaque,
        GetDevice: *const anyopaque,
        GetSharedHandle: *const fn (*IDXGIResource, *?HANDLE) callconv(.winapi) HRESULT,
        GetUsage: *const anyopaque,
        SetEvictionPriority: *const anyopaque,
        GetEvictionPriority: *const anyopaque,
    };

    pub fn get_shared_handle(self: *IDXGIResource, out: *?HANDLE) HRESULT {
        return self.vtable.GetSharedHandle(self, out);
    }
};

pub const IDXGIKeyedMutex = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*IDXGIKeyedMutex) callconv(.winapi) u32,
        SetPrivateData: *const anyopaque,
        SetPrivateDataInterface: *const anyopaque,
        GetPrivateData: *const anyopaque,
        GetParent: *const anyopaque,
        GetDevice: *const anyopaque,
        AcquireSync: *const fn (*IDXGIKeyedMutex, u64, u32) callconv(.winapi) HRESULT,
        ReleaseSync: *const fn (*IDXGIKeyedMutex, u64) callconv(.winapi) HRESULT,
    };

    pub fn acquire_sync(self: *IDXGIKeyedMutex, key: u64, timeout_ms: u32) HRESULT {
        return self.vtable.AcquireSync(self, key, timeout_ms);
    }

    pub fn release_sync(self: *IDXGIKeyedMutex, key: u64) HRESULT {
        return self.vtable.ReleaseSync(self, key);
    }
};

pub const IDXGISwapChain = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        // IUnknown + IDXGIObject + IDXGIDeviceSubObject (slots 0..7).
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*IDXGISwapChain) callconv(.winapi) u32,
        SetPrivateData: *const anyopaque,
        SetPrivateDataInterface: *const anyopaque,
        GetPrivateData: *const anyopaque,
        GetParent: *const anyopaque,
        GetDevice: *const anyopaque,
        // IDXGISwapChain.
        Present: *const fn (
            *IDXGISwapChain,
            sync_interval: u32,
            flags: u32,
        ) callconv(.winapi) HRESULT,
        GetBuffer: *const fn (
            *IDXGISwapChain,
            buffer: u32,
            riid: *const GUID,
            surface: *?*anyopaque,
        ) callconv(.winapi) HRESULT,
        SetFullscreenState: *const anyopaque,
        GetFullscreenState: *const anyopaque,
        GetDesc: *const anyopaque,
        ResizeBuffers: *const fn (
            *IDXGISwapChain,
            count: u32,
            w: u32,
            h: u32,
            format: u32,
            flags: u32,
        ) callconv(.winapi) HRESULT,
    };

    pub fn present(self: *IDXGISwapChain, sync_interval: u32, flags: u32) HRESULT {
        return self.vtable.Present(self, sync_interval, flags);
    }

    pub fn get_buffer(
        self: *IDXGISwapChain,
        index: u32,
        riid: *const GUID,
        out: *?*anyopaque,
    ) HRESULT {
        return self.vtable.GetBuffer(self, index, riid, out);
    }

    pub fn resize_buffers(
        self: *IDXGISwapChain,
        count: u32,
        w: u32,
        h: u32,
        format: u32,
        flags: u32,
    ) HRESULT {
        return self.vtable.ResizeBuffers(self, count, w, h, format, flags);
    }

    pub fn release(self: *IDXGISwapChain) void {
        _ = self.vtable.Release(self);
    }
};
