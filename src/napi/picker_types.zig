// The file a picker hands back: a display name plus a local filesystem path the caller
// can open and read (the picker imports a copy into the app's own storage). Standalone
// so the facade and every platform impl share one type without an import cycle.
pub const PickedFile = struct {
    name: []const u8,
    path: []const u8,
};
