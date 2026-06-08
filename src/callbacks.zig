// `ctx` is always `?*anyopaque`; the caller threads its own state pointer
// through it. Several callbacks share the bare `fn (ctx) void` shape - distinct
// type names keep the event nouns honest at the field declaration.

pub const ClickFn = *const fn (ctx: ?*anyopaque) void; // momentary press
// boolean flip: checkbox, switch, toggle button
pub const ToggleFn = *const fn (ctx: ?*anyopaque) void;
// pick one from a FLAT list: radio, tabs, tabbar
pub const SelectFn = *const fn (ctx: ?*anyopaque, index: usize) void;
// pick one KEYED item: menu, select, sidebar, toolbar
pub const SelectIdFn = *const fn (ctx: ?*anyopaque, id: []const u8) void;
pub const ChangeFn = *const fn (ctx: ?*anyopaque, value: f32) void; // continuous value: slider
// drag with the live point: resizable
pub const DragFn = *const fn (ctx: ?*anyopaque, x: f32, y: f32) void;
pub const DragEndFn = *const fn (ctx: ?*anyopaque) void; // drag released
pub const FocusFn = *const fn (ctx: ?*anyopaque) void; // gained focus
pub const CloseFn = *const fn (ctx: ?*anyopaque) void; // dismissed
pub const ScrollFn = *const fn (ctx: ?*anyopaque, dx: f32, dy: f32) void; // wheel delta
// expand/collapse a keyed section: sidebar
pub const DiscloseFn = *const fn (ctx: ?*anyopaque, id: []const u8, open: bool) void;
// hover an item/series (null = nothing): chart
pub const HoverFn = *const fn (ctx: ?*anyopaque, index: ?usize) void;
