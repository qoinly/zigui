// The system document picker. open_file launches it (import mode: the OS copies the
// chosen file into the app's tmp, so the URL is a plain local path the caller can read).
// The pick is async; the delegate stashes the name + path and the app reads them once
// via take_file. UIKit delivers the delegate callback on the main thread - the same
// thread the render loop polls on - so the stash needs no lock.
const objc = @import("../../macos/objc.zig");
const util = @import("util.zig");
const cs = @import("../custom_shell.zig");
const PickedFile = @import("../../../napi/picker_types.zig").PickedFile;
const Id = objc.Id;

var g_name: [256]u8 = undefined;
var g_name_len: usize = 0;
var g_path: [1024]u8 = undefined;
var g_path_len: usize = 0;
var g_valid: bool = false;
var g_pending: bool = false;

var g_delegate: ?Id = null;

// Launch the system document picker in import mode (it hands back a local copy). The
// chosen file's name + path arrive later through the delegate; the app polls take_file.
pub fn open_file() void {
    const delegate = ensure_delegate() orelse return;
    const cls = objc.get_class("UIDocumentPickerViewController") orelse return;
    var tbuf: [32]u8 = undefined;
    const uti = util.nsstring(&tbuf, "public.data") orelse return;
    const NSArray = objc.get_class("NSArray") orelse return;
    const types = objc.msg_send(Id, NSArray, "arrayWithObject:", .{uti});
    const mode: objc.NSInteger = 0; // UIDocumentPickerModeImport
    const init_sel = "initWithDocumentTypes:inMode:";
    const picker = objc.msg_send(Id, objc.alloc(cls), init_sel, .{ types, mode });
    objc.msg_send(void, picker, "setDelegate:", .{delegate});
    const root = util.root_vc() orelse return;
    const no_completion: ?*anyopaque = null;
    const present_sel = "presentViewController:animated:completion:";
    objc.msg_send(void, root, present_sel, .{ picker, objc.YES, no_completion });
    g_valid = false; // drop any undrained prior result before starting a new pick
    g_pending = true; // the picker is up; the delegate clears it on pick or cancel
    _ = objc.msg_send(Id, picker, "autorelease", .{});
}

// Whether a pick is in flight (between open_file and the delegate's pick/cancel). A
// caller drives a spinner off this; the spinner keeps the loop polling take_file.
pub fn pending() bool {
    return g_pending;
}

// The picked file's name + local path, returned once after a pick (null until then, and
// again after the single read). The slices live until the next pick.
pub fn take_file() ?PickedFile {
    if (!g_valid) return null;
    g_valid = false;
    return .{ .name = g_name[0..g_name_len], .path = g_path[0..g_path_len] };
}

// A retained NSObject subclass carrying the picker delegate methods, built once. The
// picker's delegate property is weak, so g_delegate keeps it alive.
fn ensure_delegate() ?Id {
    if (g_delegate) |d| return d;
    const NSObject = objc.get_class("NSObject") orelse return null;
    const name = "ZiguiDocPickerDelegate";
    const cls = objc.objc_allocateClassPair(NSObject, name, 0) orelse return null;
    _ = objc.class_addMethod(
        cls,
        objc.sel("documentPicker:didPickDocumentsAtURLs:"),
        @ptrCast(&did_pick),
        "v@:@@",
    );
    _ = objc.class_addMethod(
        cls,
        objc.sel("documentPickerWasCancelled:"),
        @ptrCast(&did_cancel),
        "v@:@",
    );
    objc.objc_registerClassPair(cls);
    const d = objc.msg_send(Id, objc.alloc(cls), "init", .{});
    g_delegate = d;
    return d;
}

// documentPicker:didPickDocumentsAtURLs: - stash the first file's name + local path
// (import mode already copied it into the app's tmp, so the path is freely readable).
fn did_pick(_: Id, _: objc.Sel, _: Id, urls: Id) callconv(.c) void {
    const count = objc.msg_send(objc.NSUInteger, urls, "count", .{});
    if (count == 0) return;
    const url = objc.msg_send(Id, urls, "objectAtIndex:", .{@as(objc.NSUInteger, 0)});
    const name = objc.msg_send(Id, url, "lastPathComponent", .{});
    g_name_len = util.read_nsstring(name, &g_name).len;
    const path = objc.msg_send(Id, url, "path", .{});
    g_path_len = util.read_nsstring(path, &g_path).len;
    g_valid = true;
    g_pending = false;
    cs.request_redraw(); // wake the idle loop so the app's next poll lands the result
}

fn did_cancel(_: Id, _: objc.Sel, _: Id) callconv(.c) void {
    g_pending = false;
    cs.request_redraw();
}
