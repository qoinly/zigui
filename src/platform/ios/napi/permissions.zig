// Runtime permissions through the per-API iOS frameworks - there is no single permission
// registry like Android's manifest. camera/microphone (AVCaptureDevice) and photos
// (PHPhotoLibrary) read status synchronously; notifications (UNUserNotificationCenter) only
// answer asynchronously, so that status is cached. request() raises the system prompt via a
// completion block. iOS denial is permanent (only Settings reverses it).
const std = @import("std");
const objc = @import("../../macos/objc.zig");
const util = @import("util.zig");
const cs = @import("../custom_shell.zig");
const Id = objc.Id;

const Kind = enum { camera, microphone, photos, notifications, location, unknown };

fn kind_of(name: []const u8) Kind {
    if (std.mem.eql(u8, name, "camera")) return .camera;
    if (std.mem.eql(u8, name, "microphone")) return .microphone;
    if (std.mem.eql(u8, name, "photos")) return .photos;
    if (std.mem.eql(u8, name, "notifications")) return .notifications;
    if (std.mem.eql(u8, name, "location")) return .location;
    return .unknown;
}

// One descriptor (all blocks are @sizeOf(Block)); separate block storage per callback shape.
var g_desc: objc.BlockDescriptor = .{ .size = @sizeOf(objc.Block) };
var g_wake_block: objc.Block = undefined;
var g_ns_block: objc.Block = undefined;
var g_nr_block: objc.Block = undefined;

// Cached UN authorization status (notifications answer asynchronously); 1 = not_requested.
var g_notif: u8 = 1;
var g_notif_seeded: bool = false;

// The camera/mic/photos completion only wakes; the status is then re-polled synchronously.
// One ignored arg covers both the AVCaptureDevice BOOL and the PHPhotoLibrary status.
fn wake_reply(_: *objc.Block, _: usize) callconv(.c) void {
    cs.request_redraw();
}

// --- camera / microphone (AVCaptureDevice) ---

fn av_media(k: Kind) []const u8 {
    return if (k == .camera) "vide" else "soun";
}

// AVAuthorizationStatus 0 notDetermined / 1 restricted / 2 denied / 3 authorized.
fn map_av(s: objc.NSInteger) u8 {
    return switch (s) {
        3 => 0,
        0 => 1,
        else => 3,
    };
}

fn av_status(k: Kind) u8 {
    const cls = objc.get_class("AVCaptureDevice") orelse return 1;
    var buf: [8]u8 = undefined;
    const m = util.nsstring(&buf, av_media(k)) orelse return 1;
    return map_av(objc.msg_send(objc.NSInteger, cls, "authorizationStatusForMediaType:", .{m}));
}

fn av_request(k: Kind) void {
    const cls = objc.get_class("AVCaptureDevice") orelse return;
    var buf: [8]u8 = undefined;
    const m = util.nsstring(&buf, av_media(k)) orelse return;
    g_wake_block = objc.global_block(@ptrCast(&wake_reply), &g_desc);
    objc.msg_send(void, cls, "requestAccessForMediaType:completionHandler:", .{ m, &g_wake_block });
}

// --- photos (PHPhotoLibrary) ---

// PHAuthorizationStatus 0 notDetermined / 1 restricted / 2 denied / 3 authorized / 4 limited.
fn map_ph(s: objc.NSInteger) u8 {
    return switch (s) {
        3, 4 => 0,
        0 => 1,
        else => 3,
    };
}

fn photo_status() u8 {
    const cls = objc.get_class("PHPhotoLibrary") orelse return 1;
    return map_ph(objc.msg_send(objc.NSInteger, cls, "authorizationStatus", .{}));
}

fn photo_request() void {
    const cls = objc.get_class("PHPhotoLibrary") orelse return;
    g_wake_block = objc.global_block(@ptrCast(&wake_reply), &g_desc);
    objc.msg_send(void, cls, "requestAuthorization:", .{&g_wake_block});
}

// --- notifications (UNUserNotificationCenter) ---

// UNAuthorizationStatus 0 notDetermined / 1 denied / 2 authorized / 3 provisional / 4 ephemeral.
fn map_un(s: objc.NSInteger) u8 {
    return switch (s) {
        2, 3, 4 => 0,
        0 => 1,
        else => 3,
    };
}

fn notif_center() ?Id {
    const cls = objc.get_class("UNUserNotificationCenter") orelse return null;
    return objc.msg_send(?Id, cls, "currentNotificationCenter", .{});
}

// getNotificationSettings reply (background queue): cache the status, then wake.
fn notif_settings(_: *objc.Block, settings: Id) callconv(.c) void {
    const s = objc.msg_send(objc.NSInteger, settings, "authorizationStatus", .{});
    @atomicStore(u8, &g_notif, map_un(s), .release);
    cs.request_redraw();
}

// requestAuthorization completion (background queue): cache granted/denied, then wake.
fn notif_reply(_: *objc.Block, did_grant: objc.BOOL, _: ?Id) callconv(.c) void {
    @atomicStore(u8, &g_notif, if (did_grant != 0) 0 else 3, .release);
    cs.request_redraw();
}

fn notif_status() u8 {
    if (!g_notif_seeded) {
        g_notif_seeded = true;
        const c = notif_center() orelse return 1;
        g_ns_block = objc.global_block(@ptrCast(&notif_settings), &g_desc);
        // fills the cache asynchronously; the reply wakes the loop to re-poll
        objc.msg_send(void, c, "getNotificationSettingsWithCompletionHandler:", .{&g_ns_block});
    }
    return @atomicLoad(u8, &g_notif, .acquire);
}

fn notif_request() void {
    const c = notif_center() orelse return;
    g_nr_block = objc.global_block(@ptrCast(&notif_reply), &g_desc);
    const opts: objc.NSUInteger = 7; // alert | badge | sound
    const sel = "requestAuthorizationWithOptions:completionHandler:";
    objc.msg_send(void, c, sel, .{ opts, &g_nr_block });
}

// --- location (CLLocationManager) ---

var g_loc_mgr: ?Id = null;
var g_loc_delegate: ?Id = null;

// locationManagerDidChangeAuthorization: (iOS 14+) fires after the prompt; just wake so the
// app re-polls the synchronous status.
fn loc_changed(_: Id, _: objc.Sel, _: Id) callconv(.c) void {
    cs.request_redraw();
}

fn loc_manager() ?Id {
    if (g_loc_mgr) |m| return m;
    const cls = objc.get_class("CLLocationManager") orelse return null;
    const m = objc.msg_send(Id, objc.alloc(cls), "init", .{});
    const NSObject = objc.get_class("NSObject") orelse return null;
    const dcls = objc.objc_allocateClassPair(NSObject, "ZiguiLocDelegate", 0) orelse return null;
    const sel = "locationManagerDidChangeAuthorization:";
    _ = objc.class_addMethod(dcls, objc.sel(sel), @ptrCast(&loc_changed), "v@:@");
    objc.objc_registerClassPair(dcls);
    const d = objc.msg_send(Id, objc.alloc(dcls), "init", .{});
    g_loc_delegate = d; // the manager's delegate is weak, keep it alive
    objc.msg_send(void, m, "setDelegate:", .{d});
    g_loc_mgr = m;
    return m;
}

// CLAuthorizationStatus 0 notDetermined / 1 restricted / 2 denied / 3 always / 4 whenInUse.
fn map_cl(s: objc.NSInteger) u8 {
    return switch (s) {
        3, 4 => 0,
        0 => 1,
        else => 3,
    };
}

fn loc_status() u8 {
    const m = loc_manager() orelse return 1;
    return map_cl(objc.msg_send(objc.NSInteger, m, "authorizationStatus", .{}));
}

fn loc_request() void {
    const m = loc_manager() orelse return;
    objc.msg_send(void, m, "requestWhenInUseAuthorization", .{});
}

// --- facade ---

pub fn status_code(name: []const u8) u8 {
    return switch (kind_of(name)) {
        .camera, .microphone => |k| av_status(k),
        .photos => photo_status(),
        .notifications => notif_status(),
        .location => loc_status(),
        .unknown => 1,
    };
}

pub fn granted(name: []const u8) bool {
    return status_code(name) == 0;
}

pub fn request(name: []const u8) void {
    switch (kind_of(name)) {
        .camera, .microphone => |k| av_request(k),
        .photos => photo_request(),
        .notifications => notif_request(),
        .location => loc_request(),
        .unknown => {},
    }
}
