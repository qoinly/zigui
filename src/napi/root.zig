// Native-API facade: one platform-agnostic surface (zigui.napi.<domain>.<fn>) over
// each platform's napi/ implementation. A function a target does not provide is a
// COMPILE ERROR the moment a caller uses it there - never a silent no-op - so an
// app learns at build time which APIs its target lacks. Functions a caller never
// references on an unsupported target stay uncompiled, so the library and unrelated
// apps build everywhere (the namespace keeps each call lazily analyzed).
pub const haptics = @import("haptics.zig");
pub const links = @import("links.zig");
pub const notifications = @import("notifications.zig");
pub const permissions = @import("permissions.zig");
pub const picker = @import("picker.zig");
pub const clipboard = @import("clipboard.zig");
pub const display = @import("display.zig");
pub const device = @import("device.zig");
pub const biometric = @import("biometric.zig");
