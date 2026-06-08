const std = @import("std");
const Allocator = std.mem.Allocator;

pub const SubscriptionId = u32;

pub const Subscription = struct {
    id: SubscriptionId,
    emitter: *anyopaque,
    unsubscribe_fn: *const fn (*anyopaque, SubscriptionId) void,

    pub fn deinit(self: *Subscription) void {
        self.unsubscribe_fn(self.emitter, self.id);
        self.* = undefined;
    }

    // Drop handle but leave the registration; cleaned up by emitter deinit.
    pub fn detach(self: *Subscription) void {
        self.* = undefined;
    }
};

pub fn EventEmitter(comptime E: type) type {
    return struct {
        const Self = @This();

        allocator: Allocator,
        subscribers: std.ArrayListUnmanaged(Subscriber) = .empty,
        next_id: SubscriptionId = 1,
        emit_depth: u32 = 0,
        pending_removals: std.ArrayListUnmanaged(SubscriptionId) = .empty,

        const Subscriber = struct {
            id: SubscriptionId,
            callback: *const fn (E, *anyopaque) void,
            context: *anyopaque,
            active: bool = true,
        };

        // >1024 live subscribers on one emitter is a registration leak, not use.
        const SUBSCRIBERS_MAX: usize = 1024;

        pub fn init(allocator: Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            self.subscribers.deinit(self.allocator);
            self.pending_removals.deinit(self.allocator);
        }

        pub fn subscribe(
            self: *Self,
            comptime T: type,
            context: *T,
            comptime callback: fn (E, *T) void,
        ) Allocator.Error!Subscription {
            std.debug.assert(self.subscribers.items.len < SUBSCRIBERS_MAX);
            const id = self.next_id;
            std.debug.assert(id != 0); // 0 is reserved as the never-issued sentinel
            self.next_id +|= 1;

            const Wrapper = struct {
                fn invoke(event: E, ctx: *anyopaque) void {
                    const typed_ctx: *T = @ptrCast(@alignCast(ctx));
                    callback(event, typed_ctx);
                }
            };

            try self.subscribers.append(self.allocator, .{
                .id = id,
                .callback = Wrapper.invoke,
                .context = context,
                .active = true,
            });

            return .{
                .id = id,
                .emitter = self,
                .unsubscribe_fn = @ptrCast(&Self.unsubscribe_by_id),
            };
        }

        pub fn emit(self: *Self, event: E) void {
            self.emit_depth += 1;
            defer {
                std.debug.assert(self.emit_depth > 0); // balanced by the += 1 above
                self.emit_depth -= 1;
                if (self.emit_depth == 0) {
                    self.process_pending_removals();
                }
            }

            std.debug.assert(self.subscribers.items.len <= SUBSCRIBERS_MAX);
            for (self.subscribers.items) |*sub| {
                if (sub.active) sub.callback(event, sub.context);
            }
        }

        fn unsubscribe_by_id(self: *Self, id: SubscriptionId) void {
            if (self.emit_depth > 0) {
                // Inactivate now, remove after emit unwinds. Pending-append
                // OOM leaves an inactive entry; bounded leak, never UB.
                self.pending_removals.append(self.allocator, id) catch {};
                for (self.subscribers.items) |*sub| {
                    if (sub.id == id) {
                        sub.active = false;
                        return;
                    }
                }
                return;
            }
            self.remove_subscriber(id);
        }

        fn remove_subscriber(self: *Self, id: SubscriptionId) void {
            var i: usize = 0;
            while (i < self.subscribers.items.len) : (i += 1) {
                if (self.subscribers.items[i].id == id) {
                    _ = self.subscribers.swapRemove(i);
                    return;
                }
            }
        }

        fn process_pending_removals(self: *Self) void {
            for (self.pending_removals.items) |id| {
                self.remove_subscriber(id);
            }
            self.pending_removals.clearRetainingCapacity();
        }

        pub fn subscriber_count(self: *const Self) usize {
            var count: usize = 0;
            for (self.subscribers.items) |sub| {
                if (sub.active) count += 1;
            }
            return count;
        }

        pub fn has_subscribers(self: *const Self) bool {
            for (self.subscribers.items) |sub| {
                if (sub.active) return true;
            }
            return false;
        }

        pub fn clear_subscribers(self: *Self) void {
            self.subscribers.clearRetainingCapacity();
        }
    };
}

test "EventEmitter subscribe + emit + deinit removes" {
    const TestEvent = struct { value: i32 };
    const Handler = struct {
        received: ?i32 = null,
        count: u32 = 0,
        fn on_event(e: TestEvent, self: *@This()) void {
            self.received = e.value;
            self.count += 1;
        }
    };

    var emitter = EventEmitter(TestEvent).init(std.testing.allocator);
    defer emitter.deinit();

    var h: Handler = .{};
    var sub = try emitter.subscribe(Handler, &h, Handler.on_event);

    try std.testing.expect(emitter.subscriber_count() == 1);
    emitter.emit(.{ .value = 42 });
    try std.testing.expect(h.received.? == 42 and h.count == 1);

    sub.deinit();
    try std.testing.expect(emitter.subscriber_count() == 0);
}

test "EventEmitter multiple subscribers + middle unsubscribe" {
    const TestEvent = struct { value: i32 };
    const Handler = struct {
        total: i32 = 0,
        fn on_event(e: TestEvent, self: *@This()) void {
            self.total += e.value;
        }
    };

    var emitter = EventEmitter(TestEvent).init(std.testing.allocator);
    defer emitter.deinit();

    var h1: Handler = .{};
    var h2: Handler = .{};
    var h3: Handler = .{};
    var sub1 = try emitter.subscribe(Handler, &h1, Handler.on_event);
    var sub2 = try emitter.subscribe(Handler, &h2, Handler.on_event);
    var sub3 = try emitter.subscribe(Handler, &h3, Handler.on_event);
    defer sub1.deinit();
    defer sub3.deinit();

    emitter.emit(.{ .value = 10 });
    try std.testing.expect(h1.total == 10 and h2.total == 10 and h3.total == 10);

    sub2.deinit();
    emitter.emit(.{ .value = 5 });
    try std.testing.expect(h1.total == 15 and h2.total == 10 and h3.total == 15);
}

test "EventEmitter unsubscribe during emit is deferred" {
    const TestEvent = struct {};
    const Ctx = struct {
        emitter: *EventEmitter(TestEvent),
        sub: ?*Subscription = null,
        count: u32 = 0,
        fn on_event(_: TestEvent, self: *@This()) void {
            self.count += 1;
            if (self.sub) |s| {
                s.deinit();
                self.sub = null;
            }
        }
    };

    var emitter = EventEmitter(TestEvent).init(std.testing.allocator);
    defer emitter.deinit();

    var ctx: Ctx = .{ .emitter = &emitter };
    var sub = try emitter.subscribe(Ctx, &ctx, Ctx.on_event);
    ctx.sub = &sub;

    emitter.emit(.{});
    try std.testing.expect(ctx.count == 1);
    try std.testing.expect(emitter.subscriber_count() == 0);
}
