// DirectComposition bindings, loaded dynamically (dcomp.dll ships with Win8+;
// LoadLibrary keeps it out of the import table, so its absence degrades to the
// HWND-swapchain fallback instead of failing process load). The renderer
// presents into a composition swapchain whose visual DWM composes atomically
// with the window frame: during a live resize the border and the content move
// in the same compositor transaction, where an HWND swapchain shows the
// previous frame stretched to the new window size between paints.

const std = @import("std");
const win32 = @import("win32.zig");
const com = @import("com.zig");

pub const IID_IDCompositionDevice = com.guid(
    0xC37EA93A,
    0xE7AA,
    0x450D,
    0xB1,
    0x6F,
    0x97,
    0x46,
    0xCB,
    0x04,
    0x07,
    0xF3,
);

pub const CreateDeviceFn = *const fn (
    dxgi_device: *anyopaque,
    iid: *const com.GUID,
    out: *?*anyopaque,
) callconv(.winapi) com.HRESULT;

var g_create: ?CreateDeviceFn = null;
var g_probed: bool = false;

// The DCompositionCreateDevice entry point, or null when dcomp.dll is absent.
// Probed once on the GUI thread (window creation and renderer init both run
// there); the module handle is deliberately held for process life.
pub fn create_device_proc() ?CreateDeviceFn {
    if (!g_probed) {
        g_probed = true;
        if (win32.LoadLibraryA("dcomp.dll")) |mod| {
            if (win32.GetProcAddress(mod, "DCompositionCreateDevice")) |proc| {
                g_create = @ptrCast(proc);
            }
        }
    }
    return g_create;
}

// Whether the composition path will be used. The shell window keys
// WS_EX_NOREDIRECTIONBITMAP (and the layered EDIT child) off this, so the
// window style and the renderer always agree.
pub fn available() bool {
    return create_device_proc() != null;
}

pub const IDCompositionDevice = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*IDCompositionDevice) callconv(.winapi) u32,
        Commit: *const fn (*IDCompositionDevice) callconv(.winapi) com.HRESULT,
        WaitForCommitCompletion: *const anyopaque,
        GetFrameStatistics: *const anyopaque,
        CreateTargetForHwnd: *const fn (
            *IDCompositionDevice,
            win32.HWND,
            win32.BOOL,
            *?*IDCompositionTarget,
        ) callconv(.winapi) com.HRESULT,
        CreateVisual: *const fn (
            *IDCompositionDevice,
            *?*IDCompositionVisual,
        ) callconv(.winapi) com.HRESULT,
    };

    comptime {
        std.debug.assert(@offsetOf(VTable, "CreateVisual") == 7 * @sizeOf(*const anyopaque));
    }

    pub fn commit(self: *IDCompositionDevice) com.HRESULT {
        return self.vtable.Commit(self);
    }

    pub fn create_target_for_hwnd(
        self: *IDCompositionDevice,
        hwnd: win32.HWND,
        topmost: win32.BOOL,
        out: *?*IDCompositionTarget,
    ) com.HRESULT {
        return self.vtable.CreateTargetForHwnd(self, hwnd, topmost, out);
    }

    pub fn create_visual(self: *IDCompositionDevice, out: *?*IDCompositionVisual) com.HRESULT {
        return self.vtable.CreateVisual(self, out);
    }
};

pub const IDCompositionTarget = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const anyopaque,
        SetRoot: *const fn (*IDCompositionTarget, ?*IDCompositionVisual) callconv(.winapi) com.HRESULT,
    };

    pub fn set_root(self: *IDCompositionTarget, visual: ?*IDCompositionVisual) com.HRESULT {
        return self.vtable.SetRoot(self, visual);
    }
};

// dcomp.h declares float/animation overload pairs for the property setters and
// MSVC lays each pair out in reverse declaration order - but a pair occupies
// the same two slots either way, so SetContent's index is stable at 15.
pub const IDCompositionVisual = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const anyopaque,
        SetOffsetXAnim: *const anyopaque,
        SetOffsetX: *const anyopaque,
        SetOffsetYAnim: *const anyopaque,
        SetOffsetY: *const anyopaque,
        SetTransformAnim: *const anyopaque,
        SetTransform: *const anyopaque,
        SetTransformParent: *const anyopaque,
        SetEffect: *const anyopaque,
        SetBitmapInterpolationMode: *const anyopaque,
        SetBorderMode: *const anyopaque,
        SetClipRect: *const anyopaque,
        SetClip: *const anyopaque,
        SetContent: *const fn (*IDCompositionVisual, ?*anyopaque) callconv(.winapi) com.HRESULT,
    };

    comptime {
        std.debug.assert(@offsetOf(VTable, "SetContent") == 15 * @sizeOf(*const anyopaque));
    }

    pub fn set_content(self: *IDCompositionVisual, content: ?*anyopaque) com.HRESULT {
        return self.vtable.SetContent(self, content);
    }
};
