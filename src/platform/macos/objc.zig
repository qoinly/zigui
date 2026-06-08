const std = @import("std");

pub const Class = *opaque {};
pub const Sel = *opaque {};
pub const Id = *opaque {};
pub const BOOL = i8;

pub const YES: BOOL = 1;
pub const NO: BOOL = 0;

pub const NSUInteger = usize;
pub const NSInteger = isize;
pub const CGFloat = f64;

pub const NSRect = extern struct {
    origin: NSPoint,
    size: NSSize,
};

pub const NSPoint = extern struct {
    x: CGFloat,
    y: CGFloat,
};

pub const NSSize = extern struct {
    width: CGFloat,
    height: CGFloat,
};

pub extern "c" fn objc_getClass(name: [*:0]const u8) ?Class;
pub extern "c" fn sel_registerName(name: [*:0]const u8) Sel;
pub extern "c" fn objc_allocateClassPair(
    superclass: Class,
    name: [*:0]const u8,
    extra_bytes: usize,
) ?Class;
pub extern "c" fn objc_registerClassPair(cls: Class) void;
pub extern "c" fn object_setClass(obj: Id, cls: Class) ?Class;
pub extern "c" fn class_addMethod(
    cls: Class,
    name: Sel,
    imp: *const anyopaque,
    types: [*:0]const u8,
) bool;
pub extern "c" fn class_addIvar(
    cls: Class,
    name: [*:0]const u8,
    size: usize,
    alignment: u8,
    types: [*:0]const u8,
) bool;
pub extern "c" fn object_getInstanceVariable(
    obj: Id,
    name: [*:0]const u8,
    out_value: *?*anyopaque,
) *opaque {};
pub extern "c" fn object_setInstanceVariable(
    obj: Id,
    name: [*:0]const u8,
    value: ?*anyopaque,
) *opaque {};

pub extern "c" fn objc_msgSend() void;

fn MsgSendFn(comptime ReturnType: type, comptime ArgTypes: []const type) type {
    return switch (ArgTypes.len) {
        0 => *const fn (*anyopaque, Sel) callconv(.c) ReturnType,
        1 => *const fn (*anyopaque, Sel, ArgTypes[0]) callconv(.c) ReturnType,
        2 => *const fn (*anyopaque, Sel, ArgTypes[0], ArgTypes[1]) callconv(.c) ReturnType,
        3 => *const fn (
            *anyopaque,
            Sel,
            ArgTypes[0],
            ArgTypes[1],
            ArgTypes[2],
        ) callconv(.c) ReturnType,
        4 => *const fn (
            *anyopaque,
            Sel,
            ArgTypes[0],
            ArgTypes[1],
            ArgTypes[2],
            ArgTypes[3],
        ) callconv(.c) ReturnType,
        5 => *const fn (
            *anyopaque,
            Sel,
            ArgTypes[0],
            ArgTypes[1],
            ArgTypes[2],
            ArgTypes[3],
            ArgTypes[4],
        ) callconv(.c) ReturnType,
        6 => *const fn (
            *anyopaque,
            Sel,
            ArgTypes[0],
            ArgTypes[1],
            ArgTypes[2],
            ArgTypes[3],
            ArgTypes[4],
            ArgTypes[5],
        ) callconv(.c) ReturnType,
        else => @compileError("Too many arguments for msgSend"),
    };
}

pub fn msg_send(
    comptime ReturnType: type,
    target: anytype,
    sel_name: [:0]const u8,
    args: anytype,
) ReturnType {
    const selector = sel_registerName(sel_name.ptr);
    return msg_send_sel(ReturnType, target, selector, args);
}

pub fn msg_send_sel(
    comptime ReturnType: type,
    target: anytype,
    selector: Sel,
    args: anytype,
) ReturnType {
    const ArgsType = @TypeOf(args);
    const fields = @typeInfo(ArgsType).@"struct".fields;

    comptime var arg_types: [fields.len]type = undefined;
    inline for (fields, 0..) |field, i| {
        arg_types[i] = field.type;
    }

    const FnPtr = MsgSendFn(ReturnType, &arg_types);
    const func: FnPtr = @ptrCast(&objc_msgSend);
    const target_ptr: *anyopaque = @ptrCast(@constCast(target));

    return switch (fields.len) {
        0 => func(target_ptr, selector),
        1 => func(target_ptr, selector, args[0]),
        2 => func(target_ptr, selector, args[0], args[1]),
        3 => func(target_ptr, selector, args[0], args[1], args[2]),
        4 => func(target_ptr, selector, args[0], args[1], args[2], args[3]),
        5 => func(target_ptr, selector, args[0], args[1], args[2], args[3], args[4]),
        6 => func(target_ptr, selector, args[0], args[1], args[2], args[3], args[4], args[5]),
        else => @compileError("Too many arguments for msgSend"),
    };
}

pub fn get_class(name: [:0]const u8) ?Class {
    return objc_getClass(name.ptr);
}

pub fn sel(name: [:0]const u8) Sel {
    return sel_registerName(name.ptr);
}

pub fn alloc(class: Class) Id {
    return msg_send_sel(Id, class, sel("alloc"), .{});
}

pub fn get_ivar(comptime T: type, obj: Id, name: [:0]const u8) ?*T {
    var value: ?*anyopaque = null;
    _ = object_getInstanceVariable(obj, name.ptr, &value);
    return @ptrCast(@alignCast(value));
}

pub fn set_ivar(obj: Id, name: [:0]const u8, value: anytype) void {
    const ptr: ?*anyopaque = if (@TypeOf(value) == ?*anyopaque)
        value
    else
        @ptrCast(@constCast(value));
    _ = object_setInstanceVariable(obj, name.ptr, ptr);
}

pub fn autorelease_pool_push() ?*anyopaque {
    const pool_class = get_class("NSAutoreleasePool") orelse return null;
    const pool = alloc(pool_class);
    return @ptrCast(msg_send(Id, pool, "init", .{}));
}

pub fn autorelease_pool_pop(pool: ?*anyopaque) void {
    if (pool) |p| {
        msg_send(void, @as(Id, @ptrCast(@alignCast(p))), "drain", .{});
    }
}

pub const objc_super = extern struct {
    receiver: Id,
    super_class: Class,
};

extern "c" fn objc_msgSendSuper() void;

pub fn msg_send_super(
    comptime ReturnType: type,
    super: *objc_super,
    sel_name: [:0]const u8,
    args: anytype,
) ReturnType {
    const selector = sel_registerName(sel_name.ptr);
    return msg_send_super_sel(ReturnType, super, selector, args);
}

pub fn msg_send_super_sel(
    comptime ReturnType: type,
    super: *objc_super,
    selector: Sel,
    args: anytype,
) ReturnType {
    const ArgsType = @TypeOf(args);
    const fields = @typeInfo(ArgsType).@"struct".fields;

    comptime var arg_types: [fields.len]type = undefined;
    inline for (fields, 0..) |field, i| {
        arg_types[i] = field.type;
    }

    const FnPtr = MsgSendSuperFn(ReturnType, &arg_types);
    const func: FnPtr = @ptrCast(&objc_msgSendSuper);

    return switch (fields.len) {
        0 => func(super, selector),
        1 => func(super, selector, args[0]),
        2 => func(super, selector, args[0], args[1]),
        else => @compileError("Too many arguments for msgSendSuper"),
    };
}

fn MsgSendSuperFn(comptime ReturnType: type, comptime ArgTypes: []const type) type {
    return switch (ArgTypes.len) {
        0 => *const fn (*objc_super, Sel) callconv(.c) ReturnType,
        1 => *const fn (*objc_super, Sel, ArgTypes[0]) callconv(.c) ReturnType,
        2 => *const fn (*objc_super, Sel, ArgTypes[0], ArgTypes[1]) callconv(.c) ReturnType,
        else => @compileError("Too many arguments for msgSendSuper"),
    };
}

pub extern "c" fn class_getSuperclass(cls: Class) ?Class;

pub const NSTrackingAreaOptions = struct {
    pub const MouseEnteredAndExited: NSUInteger = 0x01;
    pub const MouseMoved: NSUInteger = 0x02;
    pub const ActiveAlways: NSUInteger = 0x80;
    pub const InVisibleRect: NSUInteger = 0x200;
};
