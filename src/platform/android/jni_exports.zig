// zigui ships ZiguiActivity in the fixed package io.qoinly.zigui, so the JNI native
// methods it declares resolve against these exported symbols (the name encodes that
// package/class). Each forwards to the matching internal bridge. They live in the
// library, not the app, so a consumer writes no Java and no JNI glue - referencing
// zigui.App pulls app.zig, which references this file, emitting the symbols. This
// file is reached only through the android backend, so the exports are android-only.

const ime = @import("ime.zig");
const custom_shell = @import("custom_shell.zig");
const picker = @import("napi/picker.zig");
const biometric = @import("napi/biometric.zig");
const notification_listener = @import("napi/notification_listener.zig");

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

// The document picker's onActivityResult forwards the chosen file's text here.
export fn Java_io_qoinly_zigui_ZiguiActivity_nativeOnFile(
    env: *anyopaque,
    this: *anyopaque,
    content: ?*anyopaque,
) callconv(.c) void {
    _ = this;
    picker.on_native_file(env, content);
}

// The BiometricPrompt callback forwards the terminal outcome (1 ok, 2 failed) here.
export fn Java_io_qoinly_zigui_ZiguiActivity_nativeOnBiometric(
    env: *anyopaque,
    this: *anyopaque,
    result: i32,
) callconv(.c) void {
    _ = env;
    _ = this;
    biometric.on_native_biometric(result);
}

// The shipped notification listener forwards each posted notification's package,
// title, and text here.
export fn Java_io_qoinly_zigui_ZiguiNotificationListenerService_nativeOnNotification(
    env: *anyopaque,
    this: *anyopaque,
    pkg: ?*anyopaque,
    title: ?*anyopaque,
    text: ?*anyopaque,
) callconv(.c) void {
    _ = this;
    notification_listener.on_native_notification(env, pkg, title, text);
}
