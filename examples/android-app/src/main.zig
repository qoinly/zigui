// The Android entry (the exported ANativeActivity_onCreate) lives in zigui's
// Android backend; importing zigui pulls it into this .so, and the backend
// stands up the surface and draws through the real renderer. Referencing a
// zigui decl forces the module (and that export) into the binary.
const zigui = @import("zigui");

comptime {
    _ = zigui.App;
}
