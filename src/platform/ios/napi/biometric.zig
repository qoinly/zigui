// Face ID / Touch ID via LocalAuthentication (LAContext). authenticate raises the system
// prompt and returns immediately; evaluatePolicy's reply block fires later on a private
// queue, so the outcome is held in one atomic and the main render loop polls take_result.
const objc = @import("../../macos/objc.zig");
const util = @import("util.zig");
const cs = @import("../custom_shell.zig");
const Id = objc.Id;

// LAPolicyDeviceOwnerAuthenticationWithBiometrics.
const POLICY: objc.NSInteger = 1;

// 0 idle, 1 pending, 2 success, 3 failed. Written by the background reply, read on the
// main thread - hence atomic.
var g_state: i32 = 0;
// The LAContext must outlive the async evaluation; kept retained until the next call.
var g_ctx: ?Id = null;

var g_desc: objc.BlockDescriptor = .{ .size = @sizeOf(objc.Block) };
var g_block: objc.Block = undefined;

fn new_context() ?Id {
    const cls = objc.get_class("LAContext") orelse return null;
    return objc.msg_send(Id, objc.alloc(cls), "init", .{});
}

// canEvaluatePolicy with the biometrics policy - true when Face/Touch ID is enrolled.
pub fn available() bool {
    const ctx = new_context() orelse return false;
    const no_err: ?*anyopaque = null;
    const can = objc.msg_send(objc.BOOL, ctx, "canEvaluatePolicy:error:", .{ POLICY, no_err });
    _ = objc.msg_send(Id, ctx, "autorelease", .{});
    return can != 0;
}

// The reply fires on a private LA queue: stash the outcome, then request_redraw (which
// only flips the renderer's dirty flag the main link reads, so it is safe off-thread).
fn reply(_: *objc.Block, success: objc.BOOL, _: ?Id) callconv(.c) void {
    @atomicStore(i32, &g_state, if (success != 0) 2 else 3, .release);
    cs.request_redraw();
}

// Raise the system prompt; the subtitle (else the title) is the localized reason iOS shows.
pub fn authenticate(title: []const u8, subtitle: []const u8) void {
    if (@atomicLoad(i32, &g_state, .acquire) == 1) return; // a prompt is already in flight
    if (g_ctx) |old| _ = objc.msg_send(Id, old, "release", .{});
    g_ctx = null;
    const ctx = new_context() orelse return;
    g_ctx = ctx; // retained (no autorelease) so it survives the async evaluation
    var rbuf: [256]u8 = undefined;
    const src = if (subtitle.len > 0) subtitle else title;
    const reason = util.nsstring(&rbuf, src) orelse return;
    g_block = objc.global_block(@ptrCast(&reply), &g_desc);
    @atomicStore(i32, &g_state, 1, .monotonic);
    const sel = "evaluatePolicy:localizedReason:reply:";
    objc.msg_send(void, ctx, sel, .{ POLICY, reason, &g_block });
}

// The terminal outcome once: 1 success, 0 failed, null until the prompt resolves.
pub fn take_result() ?i32 {
    const s = @atomicLoad(i32, &g_state, .acquire);
    if (s != 2 and s != 3) return null;
    @atomicStore(i32, &g_state, 0, .monotonic);
    return if (s == 2) 1 else 0;
}
