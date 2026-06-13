// Minimal COM glue. Direct3D / DXGI / DirectWrite interfaces are hand-bound as
// extern structs whose first field is a vtable pointer; methods are called
// `obj.vtable.Method(obj, ...)`. x64 has a single calling convention, so every
// vtable entry is callconv(.winapi).

const std = @import("std");
const win32 = @import("win32.zig");

pub const HRESULT = win32.HRESULT;
pub const GUID = win32.GUID;

pub const S_OK: HRESULT = 0;
pub const E_NOINTERFACE: HRESULT = @bitCast(@as(u32, 0x80004002));

pub inline fn succeeded(hr: HRESULT) bool {
    return hr >= 0;
}

pub inline fn failed(hr: HRESULT) bool {
    return hr < 0;
}

// IUnknown layout shared by every interface. Concrete interfaces embed an
// equivalent vtable whose first three slots match this.
pub const IUnknown = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (*IUnknown, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*IUnknown) callconv(.winapi) u32,
        Release: *const fn (*IUnknown) callconv(.winapi) u32,
    };
};

// Release any COM pointer through its IUnknown-compatible vtable head. Safe to
// call with null; nulls the caller's slot so double-release is impossible.
pub fn release(ptr: anytype) void {
    const T = @TypeOf(ptr);
    const info = @typeInfo(T);
    comptime std.debug.assert(info == .pointer);
    const opt = ptr.*;
    if (opt) |obj| {
        const unk: *IUnknown = @ptrCast(@alignCast(obj));
        _ = unk.vtable.Release(unk);
        ptr.* = null;
    }
}

// AddRef a COM pointer through its IUnknown-compatible vtable head. The caller
// then owns one reference and must release it exactly once. Used when a borrowed
// resource must outlive the call that handed it over.
pub fn add_ref(obj: *anyopaque) void {
    const unk: *IUnknown = @ptrCast(@alignCast(obj));
    _ = unk.vtable.AddRef(unk);
}

pub fn query_interface(obj: *anyopaque, iid: *const GUID, out: *?*anyopaque) HRESULT {
    const unk: *IUnknown = @ptrCast(@alignCast(obj));
    return unk.vtable.QueryInterface(unk, iid, out);
}

pub fn guid(
    d1: u32,
    d2: u16,
    d3: u16,
    a: u8,
    b: u8,
    c: u8,
    d: u8,
    e: u8,
    f: u8,
    g: u8,
    h: u8,
) GUID {
    return .{ .Data1 = d1, .Data2 = d2, .Data3 = d3, .Data4 = .{ a, b, c, d, e, f, g, h } };
}
