// libxkbcommon binding: turns the compositor's keymap fd + raw keycodes into
// keysyms, UTF-32 characters, and modifier state. Loaded with dlopen like the
// other Linux bindings; only the key-translation path is declared.

const std = @import("std");

pub const Context = opaque {};
pub const Keymap = opaque {};
pub const State = opaque {};

pub const Error = error{LibraryLoadFailed};

// RMLVO names for keymap_from_names; null fields fall back to xkbcommon's
// defaults (XKB_DEFAULT_* env, then rules=evdev layout=us).
pub const RuleNames = extern struct {
    rules: ?[*:0]const u8 = null,
    model: ?[*:0]const u8 = null,
    layout: ?[*:0]const u8 = null,
    variant: ?[*:0]const u8 = null,
    options: ?[*:0]const u8 = null,
};

const CONTEXT_NO_FLAGS: c_int = 0;
const KEYMAP_FORMAT_TEXT_V1: c_int = 1;
const KEYMAP_COMPILE_NO_FLAGS: c_int = 0;
const STATE_MODS_EFFECTIVE: c_int = 8;
pub const MOD_INVALID: u32 = 0xFFFFFFFF;

extern "c" fn dlopen(file: [*:0]const u8, mode: c_int) ?*anyopaque;
extern "c" fn dlsym(handle: ?*anyopaque, name: [*:0]const u8) ?*anyopaque;
const RTLD_NOW: c_int = 2;

const Fns = struct {
    xkb_context_new: *const fn (c_int) callconv(.c) ?*Context,
    xkb_context_unref: *const fn (*Context) callconv(.c) void,
    xkb_keymap_new_from_string: *const fn (
        *Context,
        [*:0]const u8,
        c_int,
        c_int,
    ) callconv(.c) ?*Keymap,
    xkb_keymap_new_from_names: *const fn (
        *Context,
        ?*const RuleNames,
        c_int,
    ) callconv(.c) ?*Keymap,
    xkb_keymap_unref: *const fn (*Keymap) callconv(.c) void,
    xkb_keymap_mod_get_index: *const fn (*Keymap, [*:0]const u8) callconv(.c) u32,
    xkb_state_new: *const fn (*Keymap) callconv(.c) ?*State,
    xkb_state_unref: *const fn (*State) callconv(.c) void,
    xkb_state_key_get_one_sym: *const fn (*State, u32) callconv(.c) u32,
    xkb_state_key_get_utf32: *const fn (*State, u32) callconv(.c) u32,
    xkb_state_update_mask: *const fn (*State, u32, u32, u32, u32, u32, u32) callconv(.c) u32,
    xkb_state_mod_index_is_active: *const fn (*State, u32, c_int) callconv(.c) c_int,
};

var fns: Fns = undefined;
var g_loaded: bool = false;

pub fn load() Error!void {
    if (g_loaded) return;
    const handle = dlopen("libxkbcommon.so.0", RTLD_NOW) orelse return error.LibraryLoadFailed;
    inline for (@typeInfo(Fns).@"struct".fields) |field| {
        const sym = dlsym(handle, field.name) orelse return error.LibraryLoadFailed;
        @field(fns, field.name) = @ptrCast(@alignCast(sym));
    }
    g_loaded = true;
    std.debug.assert(g_loaded);
}

pub fn context_new() ?*Context {
    std.debug.assert(g_loaded);
    return fns.xkb_context_new(CONTEXT_NO_FLAGS);
}

pub fn context_unref(context: *Context) void {
    std.debug.assert(g_loaded);
    fns.xkb_context_unref(context);
}

// keymap_text is the mmap'd, NUL-terminated buffer from the wl_keyboard
// keymap event (format xkb_v1).
pub fn keymap_from_string(context: *Context, keymap_text: [*:0]const u8) ?*Keymap {
    std.debug.assert(g_loaded);
    std.debug.assert(keymap_text[0] != 0);
    return fns.xkb_keymap_new_from_string(
        context,
        keymap_text,
        KEYMAP_FORMAT_TEXT_V1,
        KEYMAP_COMPILE_NO_FLAGS,
    );
}

// The X11 arm's keymap source: there is no compositor to hand us a keymap
// fd, so the names come from the root window's _XKB_RULES_NAMES property.
pub fn keymap_from_names(context: *Context, names: ?*const RuleNames) ?*Keymap {
    std.debug.assert(g_loaded);
    return fns.xkb_keymap_new_from_names(context, names, KEYMAP_COMPILE_NO_FLAGS);
}

pub fn keymap_unref(keymap: *Keymap) void {
    std.debug.assert(g_loaded);
    fns.xkb_keymap_unref(keymap);
}

pub fn mod_index(keymap: *Keymap, name: [*:0]const u8) u32 {
    std.debug.assert(g_loaded);
    std.debug.assert(name[0] != 0);
    return fns.xkb_keymap_mod_get_index(keymap, name);
}

pub fn state_new(keymap: *Keymap) ?*State {
    std.debug.assert(g_loaded);
    return fns.xkb_state_new(keymap);
}

pub fn state_unref(state: *State) void {
    std.debug.assert(g_loaded);
    fns.xkb_state_unref(state);
}

// keycode is the evdev code + 8, the xkb convention for wl_keyboard keys.
pub fn key_sym(state: *State, keycode: u32) u32 {
    std.debug.assert(g_loaded);
    std.debug.assert(keycode >= 8);
    return fns.xkb_state_key_get_one_sym(state, keycode);
}

pub fn key_utf32(state: *State, keycode: u32) u32 {
    std.debug.assert(g_loaded);
    std.debug.assert(keycode >= 8);
    return fns.xkb_state_key_get_utf32(state, keycode);
}

pub fn update_mask(state: *State, depressed: u32, latched: u32, locked: u32, group: u32) void {
    std.debug.assert(g_loaded);
    _ = fns.xkb_state_update_mask(state, depressed, latched, locked, 0, 0, group);
}

pub fn mod_active(state: *State, index: u32) bool {
    std.debug.assert(g_loaded);
    if (index == MOD_INVALID) return false;
    return fns.xkb_state_mod_index_is_active(state, index, STATE_MODS_EFFECTIVE) == 1;
}
