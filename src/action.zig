const std = @import("std");
const events = @import("events.zig");

pub const ActionHandler = struct {
    type_name: []const u8,
    handler_ptr: *const anyopaque,
    context_ptr: ?*anyopaque,
    invoke_fn: *const fn (
        handler: *const anyopaque,
        ctx: ?*anyopaque,
        action: *const anyopaque,
        app: *anyopaque,
    ) void,
};

pub const ActionRegistry = struct {
    allocator: std.mem.Allocator,
    handlers: std.StringHashMapUnmanaged(ActionHandler) = .empty,

    pub fn init(allocator: std.mem.Allocator) ActionRegistry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ActionRegistry) void {
        self.handlers.deinit(self.allocator);
    }

    pub fn register(
        self: *ActionRegistry,
        comptime Action: type,
        handler: *const fn (*const Action, *anyopaque) void,
    ) std.mem.Allocator.Error!void {
        const type_name = @typeName(Action);

        const invoke = struct {
            fn invoke(
                handler_ptr: *const anyopaque,
                ctx: ?*anyopaque,
                action_ptr: *const anyopaque,
                app: *anyopaque,
            ) void {
                _ = ctx;
                const typed_handler: *const fn (*const Action, *anyopaque) void =
                    @ptrCast(@alignCast(handler_ptr));
                const typed_action: *const Action = @ptrCast(@alignCast(action_ptr));
                typed_handler(typed_action, app);
            }
        }.invoke;

        try self.handlers.put(self.allocator, type_name, .{
            .type_name = type_name,
            .handler_ptr = @ptrCast(handler),
            .context_ptr = null,
            .invoke_fn = invoke,
        });
    }

    pub fn register_with_context(
        self: *ActionRegistry,
        comptime Action: type,
        comptime T: type,
        context: T,
        handler: *const fn (T, *const Action, *anyopaque) void,
    ) std.mem.Allocator.Error!void {
        comptime std.debug.assert(@typeInfo(T) == .pointer); // context erases through *anyopaque
        const type_name = @typeName(Action);

        const invoke = struct {
            fn invoke(
                handler_ptr: *const anyopaque,
                ctx: ?*anyopaque,
                action_ptr: *const anyopaque,
                app: *anyopaque,
            ) void {
                const typed_handler: *const fn (T, *const Action, *anyopaque) void =
                    @ptrCast(@alignCast(handler_ptr));
                const typed_action: *const Action = @ptrCast(@alignCast(action_ptr));
                std.debug.assert(ctx != null); // register_with_context always stores a real ptr
                const typed_ctx: T = @ptrCast(@alignCast(ctx));
                typed_handler(typed_ctx, typed_action, app);
            }
        }.invoke;

        try self.handlers.put(self.allocator, type_name, .{
            .type_name = type_name,
            .handler_ptr = @ptrCast(handler),
            .context_ptr = @ptrCast(@alignCast(context)),
            .invoke_fn = invoke,
        });
    }

    pub fn dispatch(
        self: *ActionRegistry,
        comptime Action: type,
        action: *const Action,
        app: *anyopaque,
    ) bool {
        const type_name = @typeName(Action);
        const entry = self.handlers.get(type_name) orelse return false;
        entry.invoke_fn(entry.handler_ptr, entry.context_ptr, action, app);
        return true;
    }
};

pub const KeyBinding = struct {
    action_type_name: []const u8,
    action_ptr: *const anyopaque,
    dispatch_fn: *const fn (
        registry: *ActionRegistry,
        action_ptr: *const anyopaque,
        app: *anyopaque,
    ) bool,
    destroy_fn: *const fn (allocator: std.mem.Allocator, action_ptr: *const anyopaque) void,
};

pub const KeyModifiers = struct {
    cmd: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    shift: bool = false,

    pub fn eql(self: KeyModifiers, other: KeyModifiers) bool {
        return self.cmd == other.cmd and
            self.ctrl == other.ctrl and
            self.alt == other.alt and
            self.shift == other.shift;
    }

    pub fn from_event_modifiers(mods: events.Modifiers) KeyModifiers {
        return .{
            .cmd = mods.command,
            .ctrl = mods.control,
            .alt = mods.alt,
            .shift = mods.shift,
        };
    }
};

pub const KeyBindingRegistry = struct {
    allocator: std.mem.Allocator,
    // Packed u64 so one AutoHashMap key covers char + modifiers without hashing a struct.
    bindings: std.AutoHashMapUnmanaged(u64, KeyBinding) = .empty,

    pub fn init(allocator: std.mem.Allocator) KeyBindingRegistry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *KeyBindingRegistry) void {
        var it = self.bindings.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.destroy_fn(self.allocator, entry.value_ptr.action_ptr);
        }
        self.bindings.deinit(self.allocator);
    }

    fn pack_key(modifiers: KeyModifiers, key_char: u21) u64 {
        var result: u64 = key_char;
        if (modifiers.cmd) result |= @as(u64, 1) << 32;
        if (modifiers.ctrl) result |= @as(u64, 1) << 33;
        if (modifiers.alt) result |= @as(u64, 1) << 34;
        if (modifiers.shift) result |= @as(u64, 1) << 35;
        return result;
    }

    pub fn bind(
        self: *KeyBindingRegistry,
        modifiers: KeyModifiers,
        key_char: u21,
        comptime Action: type,
        action: Action,
    ) std.mem.Allocator.Error!void {
        const key = pack_key(modifiers, key_char);

        const action_heap = try self.allocator.create(Action);
        errdefer self.allocator.destroy(action_heap);
        action_heap.* = action;

        const dispatch_fn = struct {
            fn dispatch(
                registry: *ActionRegistry,
                action_ptr: *const anyopaque,
                app: *anyopaque,
            ) bool {
                const typed_action: *const Action = @ptrCast(@alignCast(action_ptr));
                return registry.dispatch(Action, typed_action, app);
            }
        }.dispatch;

        const destroy_fn = struct {
            fn destroy(allocator: std.mem.Allocator, action_ptr: *const anyopaque) void {
                const typed: *Action = @ptrCast(@alignCast(@constCast(action_ptr)));
                allocator.destroy(typed);
            }
        }.destroy;

        try self.bindings.put(self.allocator, key, .{
            .action_type_name = @typeName(Action),
            .action_ptr = action_heap,
            .dispatch_fn = dispatch_fn,
            .destroy_fn = destroy_fn,
        });
    }

    pub fn try_dispatch(
        self: *KeyBindingRegistry,
        modifiers: KeyModifiers,
        key_char: u21,
        action_registry: *ActionRegistry,
        app: *anyopaque,
    ) bool {
        const key = pack_key(modifiers, key_char);
        const binding = self.bindings.get(key) orelse return false;
        return binding.dispatch_fn(action_registry, binding.action_ptr, app);
    }
};

test "ActionRegistry register + dispatch" {
    var gpa: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    var reg = ActionRegistry.init(gpa.allocator());
    defer reg.deinit();

    const Action = struct { value: u32 };
    const Sink = struct {
        var got: u32 = 0;
        fn run(a: *const Action, _: *anyopaque) void {
            got = a.value;
        }
    };

    try reg.register(Action, Sink.run);

    var app_marker: u8 = 0;
    const ok = reg.dispatch(Action, &Action{ .value = 42 }, &app_marker);
    try std.testing.expect(ok);
    try std.testing.expect(Sink.got == 42);
}

test "KeyBindingRegistry bind + tryDispatch" {
    var gpa: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var actions = ActionRegistry.init(alloc);
    defer actions.deinit();
    var bindings = KeyBindingRegistry.init(alloc);
    defer bindings.deinit();

    const Action = struct { value: u32 };
    const Sink = struct {
        var got: u32 = 0;
        fn run(a: *const Action, _: *anyopaque) void {
            got = a.value;
        }
    };
    try actions.register(Action, Sink.run);
    try bindings.bind(.{ .cmd = true }, 'q', Action, .{ .value = 7 });

    var app_marker: u8 = 0;
    const ok = bindings.try_dispatch(.{ .cmd = true }, 'q', &actions, &app_marker);
    try std.testing.expect(ok);
    try std.testing.expect(Sink.got == 7);
}
