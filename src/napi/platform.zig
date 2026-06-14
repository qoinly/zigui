// The current target's native-api aggregate, selected at comptime, plus the
// compile-error a domain facade raises for a function the target does not provide.

const builtin = @import("builtin");

pub const target = if (builtin.abi.isAndroid())
    @import("../platform/android/napi/root.zig")
else switch (builtin.os.tag) {
    .macos => @import("../platform/macos/napi/root.zig"),
    .windows => @import("../platform/windows/napi/root.zig"),
    .linux => @import("../platform/linux/napi/root.zig"),
    else => @compileError("zigui: unsupported OS for native apis"),
};

// Reached only from a comptime-false branch, so it fires exactly when a caller
// references an api the target lacks - never during the library's own build.
pub fn unsupported(comptime name: []const u8) noreturn {
    const os = @tagName(builtin.os.tag);
    @compileError("napi." ++ name ++ " is unsupported on this target: " ++ os);
}

// The selected aggregate's domain, or an empty namespace when the target has none;
// the @hasDecl in the facade then routes to unsupported().
pub fn domain(comptime name: []const u8) type {
    if (@hasDecl(target, name)) return @field(target, name);
    return struct {};
}
