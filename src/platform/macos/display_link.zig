const std = @import("std");
const objc = @import("objc.zig");

pub const CVDisplayLink = opaque {};
pub const CVReturn = i32;
pub const CVOptionFlags = u64;
pub const CGDirectDisplayID = u32;

pub const kCVReturnSuccess: CVReturn = 0;

pub const CVTimeStamp = extern struct {
    version: u32,
    video_time_scale: i32,
    video_time: i64,
    host_time: u64,
    rate_scalar: f64,
    video_refresh_period: i64,
    smpte_time: CVSMPTETime,
    flags: u64,
    reserved: u64,
};

pub const CVSMPTETime = extern struct {
    subframes: i16,
    subframe_divisor: i16,
    counter: u32,
    time_type: u32,
    flags: u32,
    hours: i16,
    minutes: i16,
    seconds: i16,
    frames: i16,
};

pub const CVDisplayLinkOutputCallback = *const fn (
    display_link: *CVDisplayLink,
    in_now: *const CVTimeStamp,
    in_output_time: *const CVTimeStamp,
    flags_in: CVOptionFlags,
    flags_out: *CVOptionFlags,
    display_link_context: ?*anyopaque,
) callconv(.c) CVReturn;

pub const dispatch_queue_t = *opaque {};
pub const dispatch_source_t = *opaque {};
pub const dispatch_object_t = *opaque {};
pub const dispatch_source_type_t = *const opaque {};
pub const dispatch_function_t = *const fn (?*anyopaque) callconv(.c) void;

extern "CoreVideo" fn CVDisplayLinkCreateWithActiveCGDisplays(
    display_link_out: **CVDisplayLink,
) CVReturn;
extern "CoreVideo" fn CVDisplayLinkSetOutputCallback(
    display_link: *CVDisplayLink,
    callback: CVDisplayLinkOutputCallback,
    user_info: ?*anyopaque,
) CVReturn;
extern "CoreVideo" fn CVDisplayLinkSetCurrentCGDisplay(
    display_link: *CVDisplayLink,
    display_id: CGDirectDisplayID,
) CVReturn;
extern "CoreVideo" fn CVDisplayLinkStart(display_link: *CVDisplayLink) CVReturn;
extern "CoreVideo" fn CVDisplayLinkStop(display_link: *CVDisplayLink) CVReturn;
extern "CoreVideo" fn CVDisplayLinkRelease(display_link: *CVDisplayLink) void;

// dispatch_get_main_queue() is a macro; underlying symbol is _dispatch_main_q.
extern "c" var _dispatch_main_q: anyopaque;

fn get_main_queue() dispatch_queue_t {
    return @ptrCast(&_dispatch_main_q);
}

extern "c" fn dispatch_source_create(
    type_: dispatch_source_type_t,
    handle: usize,
    mask: usize,
    queue: dispatch_queue_t,
) dispatch_source_t;
extern "c" fn dispatch_source_set_event_handler_f(
    source: dispatch_source_t,
    handler: dispatch_function_t,
) void;
extern "c" fn dispatch_set_context(object: dispatch_object_t, context: ?*anyopaque) void;
extern "c" fn dispatch_resume(object: dispatch_object_t) void;
extern "c" fn dispatch_suspend(object: dispatch_object_t) void;
extern "c" fn dispatch_source_merge_data(source: dispatch_source_t, value: usize) void;
extern "c" fn dispatch_source_cancel(source: dispatch_source_t) void;
extern "c" fn dispatch_release(object: dispatch_object_t) void;

extern "c" var _dispatch_source_type_data_add: anyopaque;

fn get_dispatch_source_type_data_add() dispatch_source_type_t {
    return @ptrCast(&_dispatch_source_type_data_add);
}

pub const Error = error{
    CVDisplayLinkCreateFailed,
    CVDisplayLinkSetCallbackFailed,
    CVDisplayLinkSetDisplayFailed,
    CVDisplayLinkStartFailed,
};

pub const DisplayLink = struct {
    cv_display_link: ?*CVDisplayLink = null,
    frame_requests: ?dispatch_source_t = null,
    running: bool = false,

    // CV callback fires on a background thread; coalesce frame requests
    // onto the main queue via a data-add dispatch source.
    pub fn init(
        display_id: CGDirectDisplayID,
        context: ?*anyopaque,
        callback: dispatch_function_t,
    ) Error!DisplayLink {
        var self = DisplayLink{};

        const frame_requests = dispatch_source_create(
            get_dispatch_source_type_data_add(),
            0,
            0,
            get_main_queue(),
        );
        self.frame_requests = frame_requests;
        errdefer dispatch_source_cancel(frame_requests); // tear down on any error return below
        dispatch_set_context(@ptrCast(frame_requests), context);
        dispatch_source_set_event_handler_f(frame_requests, callback);

        var cv_display_link: *CVDisplayLink = undefined;
        var result = CVDisplayLinkCreateWithActiveCGDisplays(&cv_display_link);
        if (result != kCVReturnSuccess) return Error.CVDisplayLinkCreateFailed;
        self.cv_display_link = cv_display_link;

        result = CVDisplayLinkSetOutputCallback(
            cv_display_link,
            display_link_callback,
            @ptrCast(frame_requests),
        );
        if (result != kCVReturnSuccess) {
            CVDisplayLinkRelease(cv_display_link);
            return Error.CVDisplayLinkSetCallbackFailed;
        }

        result = CVDisplayLinkSetCurrentCGDisplay(cv_display_link, display_id);
        if (result != kCVReturnSuccess) {
            CVDisplayLinkRelease(cv_display_link);
            return Error.CVDisplayLinkSetDisplayFailed;
        }

        return self;
    }

    pub fn deinit(self: *DisplayLink) void {
        self.stop();
        // Do NOT CVDisplayLinkRelease: the CV background thread may still
        // be in flight and releasing under that race crashes. Accept the
        // leak - DisplayLink.deinit runs at process exit.
        self.cv_display_link = null;

        if (self.frame_requests) |fr| {
            dispatch_source_cancel(fr);
        }
        self.frame_requests = null;
    }

    pub fn start(self: *DisplayLink) Error!void {
        if (self.running) return;

        if (self.frame_requests) |fr| {
            dispatch_resume(@ptrCast(fr));
        }
        if (self.cv_display_link) |dl| {
            const result = CVDisplayLinkStart(dl);
            if (result != kCVReturnSuccess) return Error.CVDisplayLinkStartFailed;
        }
        self.running = true;
    }

    pub fn stop(self: *DisplayLink) void {
        if (!self.running) return;
        if (self.cv_display_link) |dl| _ = CVDisplayLinkStop(dl);
        if (self.frame_requests) |fr| dispatch_suspend(@ptrCast(fr));
        self.running = false;
    }
};

// Runs on a CV background thread - signal only, never render here.
fn display_link_callback(
    _: *CVDisplayLink,
    _: *const CVTimeStamp,
    _: *const CVTimeStamp,
    _: CVOptionFlags,
    _: *CVOptionFlags,
    context: ?*anyopaque,
) callconv(.c) CVReturn {
    const frame_requests: dispatch_source_t = @ptrCast(@alignCast(context));
    dispatch_source_merge_data(frame_requests, 1);
    return kCVReturnSuccess;
}

pub fn get_main_display_id() CGDirectDisplayID {
    return CGMainDisplayID();
}

extern "CoreGraphics" fn CGMainDisplayID() CGDirectDisplayID;
