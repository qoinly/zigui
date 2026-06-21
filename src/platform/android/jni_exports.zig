// zigui ships ZiguiActivity in the fixed package io.qoinly.zigui, so the JNI native
// methods it declares resolve against these exported symbols (the name encodes that
// package/class). Each forwards to the matching internal bridge. They live in the
// library, not the app, so a consumer writes no Java and no JNI glue - referencing
// zigui.App pulls app.zig, which references this file, emitting the symbols. This
// file is reached only through the android backend, so the exports are android-only.
//
// The optional bridges (accessibility, notification listener, broadcast, biometric)
// are gated by android_caps: a comptime-false cap drops its @export, and since nothing
// else references that bridge, Zig leaves the whole napi module out of the .so. So an
// app that does not declare a capability carries none of its code.

const caps = @import("android_caps");

const ime = @import("ime.zig");
const custom_shell = @import("custom_shell.zig");
const picker = @import("napi/picker.zig");
const biometric = @import("napi/biometric.zig");
const notification_listener = @import("napi/notification_listener.zig");
const broadcast = @import("napi/broadcast.zig");
const accessibility = @import("napi/accessibility.zig");

// ZiguiActivity's hidden EditText pushes every edit here (the erased env + String).
export fn Java_io_qoinly_zigui_ZiguiActivity_nativeOnText(
    env: *anyopaque,
    this: *anyopaque,
    text: ?*anyopaque,
    caret: i32,
) callconv(.c) void {
    _ = this;
    ime.on_native_text(env, text, caret);
}

// The back funnel: pop the route stack; the jboolean is whether the press was
// consumed (the Java side backgrounds the app when it was not).
export fn Java_io_qoinly_zigui_ZiguiActivity_nativeOnBack(
    env: *anyopaque,
    this: *anyopaque,
) callconv(.c) u8 {
    _ = env;
    _ = this;
    return @intFromBool(custom_shell.dispatch_back());
}

// The document picker's onActivityResult forwards the chosen file's display name +
// local path here.
export fn Java_io_qoinly_zigui_ZiguiActivity_nativeOnFile(
    env: *anyopaque,
    this: *anyopaque,
    name: ?*anyopaque,
    path: ?*anyopaque,
) callconv(.c) void {
    _ = this;
    picker.on_native_file(env, name, path);
}

// A dismissed picker or a failed import: clear the in-flight flag.
export fn Java_io_qoinly_zigui_ZiguiActivity_nativeOnFileCancel(
    env: *anyopaque,
    this: *anyopaque,
) callconv(.c) void {
    _ = env;
    _ = this;
    picker.on_native_cancel();
}

// The BiometricPrompt callback forwards the terminal outcome (1 ok, 2 failed) here.
fn on_biometric(env: *anyopaque, this: *anyopaque, result: i32) callconv(.c) void {
    _ = env;
    _ = this;
    biometric.on_native_biometric(result);
}

// The shipped notification listener forwards each posted notification's package,
// title, and text here.
fn on_notification(
    env: *anyopaque,
    this: *anyopaque,
    pkg: ?*anyopaque,
    title: ?*anyopaque,
    text: ?*anyopaque,
) callconv(.c) void {
    _ = this;
    notification_listener.on_native_notification(env, pkg, title, text);
}

// A subscribed (runtime) broadcast receiver forwards each match's action + a String[]
// of alternating key, value extras here.
fn on_broadcast(
    env: *anyopaque,
    this: *anyopaque,
    action: ?*anyopaque,
    kv: ?*anyopaque,
) callconv(.c) void {
    _ = this;
    broadcast.on_native_broadcast(env, action, kv);
}

// The manifest-declared (static) receiver forwards each broadcast here for the
// headless path (may run on a cold-started process).
fn on_static_broadcast(
    env: *anyopaque,
    this: *anyopaque,
    action: ?*anyopaque,
    kv: ?*anyopaque,
) callconv(.c) void {
    _ = this;
    broadcast.on_native_static_broadcast(env, action, kv);
}

// The accessibility service forwards each subscribed event's type, package, and text.
fn on_a11y_event(
    env: *anyopaque,
    this: *anyopaque,
    event_type: i32,
    pkg: ?*anyopaque,
    text: ?*anyopaque,
) callconv(.c) void {
    _ = this;
    accessibility.on_native_a11y_event(env, event_type, pkg, text);
}

comptime {
    if (caps.biometric) @export(&on_biometric, .{
        .name = "Java_io_qoinly_zigui_ZiguiActivity_nativeOnBiometric",
    });
    if (caps.notification_listener) @export(&on_notification, .{
        .name = "Java_io_qoinly_zigui_ZiguiNotificationListenerService_nativeOnNotification",
    });
    if (caps.broadcast) @export(&on_broadcast, .{
        .name = "Java_io_qoinly_zigui_ZiguiActivity_nativeOnBroadcast",
    });
    if (caps.broadcast) @export(&on_static_broadcast, .{
        .name = "Java_io_qoinly_zigui_ZiguiBroadcastReceiver_nativeOnBroadcast",
    });
    if (caps.accessibility) @export(&on_a11y_event, .{
        .name = "Java_io_qoinly_zigui_ZiguiAccessibilityService_nativeOnA11yEvent",
    });
}
