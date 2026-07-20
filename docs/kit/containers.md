# Containers

Containers group and stack content (`card`), switch between views (`tabs`,
`sidebar`, `tabbar`), and float above the page (`dialog`, `sheet`, `menu`,
`popover`). The floating ones are *overlay-region* nodes - see [Overlays](#overlays).

- [Card](#card) - a styled surface (no facade fn; build it from `col`)
- [Tabs](#tabs) - switch between related views
- [Sidebar](#sidebar) - a nav tree with disclosure + resize
- [Tab bar](#tab-bar) - closeable, reorderable page tabs
- [Bottom bar](#bottom-bar) - a mobile bottom navigation bar
- [Resize handle](#resize-handle) - a draggable divider between two panes
- [Overlays](#overlays) - dialog, sheet, menu, popover, `modal_backdrop`

Scrolling (`scroll`) and z-stacking (`layers`) are core layout nodes, documented
in [Layout](../layout.md).

## Card

There is no `zigui.card`. A card is a `col` (or `row`) with the theme's card
surface, border, and radius pulled from `f.theme`:

```zig
fn card(t: *const zigui.Theme, kids: []const *zigui.Node) *zigui.Node {
    return zigui.col(.{
        .gap = .sm,
        .pad = .lg,
        .bg = t.card,
        .border = t.border,
        .radius = t.radius,
    }, kids);
}
```

```zig
card(f.theme, &.{
    zigui.text("Total Revenue", .{ .size = 13, .muted = true }),
    zigui.text("$15,231.89", .{ .size = 26, .weight = .semi_bold }),
})
```

`pad` and `gap` take `Spacing` tokens (`.sm`, `.lg`, ... or `.{ .px = 24 }`),
not bare numbers. `bg` / `border` are `Rgba`; read them off `f.theme`, never
hardcode. Full `col` / `row` options are in [Layout](../layout.md).

## Tabs

A horizontal tab strip over a shared content area. You own the selected index
and a `TabsState` (cross-frame scratch).

```zig
const App = struct {
    sel: usize = 0,
    state: zigui.kit.tabs.TabsState = .{},
};

const LABELS = [_][]const u8{ "Account", "Password", "Team", "Billing" };

fn on_select(app: *App, idx: usize) void {
    app.sel = idx;
}

zigui.tabs(&LABELS, &app.state, .{
    .selected = app.sel,
    .on_select = zigui.on_index(App, on_select),
})
```

`tabs(labels, state, o)` - `labels` is the strip, `state` is a
`*kit.tabs.TabsState`, `o` is:

| Option | Type | Default | Meaning |
|---|---|---|---|
| `selected` | `usize` | `0` | active tab index |
| `height` | `f32` | `36` | strip height |
| `on_select` | `?SelectFn` | `null` | wrap with `zigui.on_index(State, f)` (`fn(*State, usize)`) |

`tabs` only draws the strip; render the body yourself, switching on `selected`.

## Sidebar

A nav tree: groups, items, collapsible parents with children, an optional badge,
internal scroll, a drag-resize handle, and a mini icon-rail collapse. You own
the `SidebarState`, the scroll offset, and the width.

```zig
const App = struct {
    nav: zigui.SidebarState = .{},
    nav_scroll: f32 = 0,
    sidebar_w: f32 = 260,
    sidebar_collapsed: bool = false,
    forms_open: bool = true,
};

const FORMS = [_]zigui.SidebarEntry{
    .{ .kind = .item, .id = "button", .label = "Button" },
    .{ .kind = .item, .id = "input", .label = "Input" },
};

fn select(app: *App, id: []const u8) void {
    app.nav.selected_id = id; // item ids are static literals, safe to store
}
fn disclose(app: *App, id: []const u8, open: bool) void {
    if (std.mem.eql(u8, id, "grp_forms")) app.forms_open = open;
}
fn resize(app: *App, x: f32, _: f32) void {
    app.sidebar_w = std.math.clamp(x, 200, 360); // sidebar at the left: x is the new width
}

zigui.sidebar(.{
    .items = &.{
        .{ .kind = .group, .label = "Components" },
        .{
            .kind = .item,
            .id = "grp_forms",
            .label = "Forms",
            .icon = .copy,
            .expanded = app.forms_open,
            .children = &FORMS,
        },
    },
    .state = &app.nav,
    .scroll = &app.nav_scroll,
    .width = app.sidebar_w,
    .collapsed = app.sidebar_collapsed,
    .on_select = zigui.on_id(App, select),
    .on_disclose = zigui.on_disclose(App, disclose),
    .on_resize = zigui.on_drag(App, resize),
})
```

`sidebar(o)`:

| Option | Type | Default | Meaning |
|---|---|---|---|
| `items` | `[]const SidebarEntry` | required | top-level entries |
| `state` | `*SidebarState` | required | cross-frame; keep a stable address |
| `scroll` | `*f32` | required | caller-owned scroll offset |
| `width` | `f32` | `260` | expanded width |
| `collapsed` | `bool` | `false` | render the mini icon rail |
| `on_select` | `?SelectIdFn` | `null` | wrap with `zigui.on_id(State, f)` (`fn(*State, []const u8)`) |
| `on_disclose` | `?DiscloseFn` | `null` | wrap with `zigui.on_disclose(State, f)` (`fn(*State, []const u8, bool)`) |
| `on_resize` | `?DragFn` | `null` | wrap with `zigui.on_drag(State, f)` (`fn(*State, f32, f32)`) |

`SidebarEntry`:

| Field | Type | Default | Meaning |
|---|---|---|---|
| `kind` | `SidebarKind` | required | `.group` (heading) or `.item` |
| `id` | `[]const u8` | `""` | select id; use a static literal |
| `label` | `[]const u8` | required | row text |
| `icon` | `?Icon` | `null` | leading glyph |
| `color` | `?Rgba` | `null` | colored backplate behind a white icon |
| `badge` | `[]const u8` | `""` | count pill at the row's right edge |
| `children` | `[]const SidebarEntry` | `&.{}` | a non-empty list makes the row a disclosure parent |
| `collapsible` | `bool` | `false` | `.group` only: toggle its items vs static heading |
| `expanded` | `bool` | `true` | initial open state for a parent / collapsible group |

`SidebarState` holds `selected_id` (read it back to know the current page). The
state and the entry slices' children must outlive the frame - store entry
arrays as module-level constants, drive `expanded` off your own bools.
Re-exported: `SidebarState`, `SidebarEntry`, `SidebarKind`.

## Tab bar

A Postman/Insomnia-style strip of open pages: closeable, reorderable, pinnable,
with an optional trailing + button. You own the `TabBarState` (it must keep a
stable address - hitboxes back-point into it), the horizontal scroll, and the
active index.

```zig
const App = struct {
    state: zigui.TabBarState = .{},
    active: usize = 0,
    scroll: f32 = 0,
};

fn on_select(app: *App, i: usize) void { app.active = i; }
fn on_close(app: *App, i: usize) void { /* remove tab i */ }
fn on_new(app: *App) void { /* append a tab */ }
fn on_move(app: *App, from: usize, to: usize) void { /* reorder */ }
fn on_pin(app: *App, i: usize) void { /* unpin tab i */ }

zigui.tabbar(.{
    .tabs = items, // []const zigui.TabItem
    .active = app.active,
    .state = &app.state,
    .scroll_x = &app.scroll,
    .on_select = zigui.on_index(App, on_select),
    .on_close = zigui.on_index(App, on_close),
    .on_new = zigui.on(App, on_new),
    .on_move = zigui.on_move2(App, on_move),
    .on_pin = zigui.on_index(App, on_pin),
})
```

`tabbar(o)`:

| Option | Type | Default | Meaning |
|---|---|---|---|
| `tabs` | `[]const TabItem` | required | the open tabs |
| `state` | `*TabBarState` | required | cross-frame; stable address |
| `scroll_x` | `*f32` | required | caller-owned horizontal pan |
| `active` | `usize` | `0` | active tab index |
| `height` | `f32` | `36` | strip height |
| `on_select` | `?TabSelectFn` | `null` | wrap with `zigui.on_index(State, f)` (`fn(*State, usize)`) |
| `on_close` | `?TabCloseFn` | `null` | wrap with `zigui.on_index(State, f)` |
| `on_new` | `?TabNewFn` | `null` | wrap with `zigui.on(State, f)`; `null` = no + button |
| `on_move` | `?TabMoveFn` | `null` | wrap with `zigui.on_move2(State, f)` (`fn(*State, usize, usize)`) - enables drag-reorder |
| `on_pin` | `?TabPinFn` | `null` | wrap with `zigui.on_index(State, f)` |
| `on_context` | `?TabContextFn` | `null` | wrap with `zigui.on_index(State, f)`; fires on right-click so you can anchor a menu at that tab |
| `label_size` | `f32` | `0` | tab label font size; `0` = the theme font size |
| `min_tab_w` | `f32` | `120` | tabs shrink to fill the strip down to this, then the strip scrolls |
| `max_tab_w` | `f32` | `220` | tabs never grow past this; set `min == max` for a fixed tab width |

`TabItem`:

| Field | Type | Default | Meaning |
|---|---|---|---|
| `id` | `[]const u8` | required | stable id |
| `title` | `[]const u8` | required | tab label (ellipsizes when tight) |
| `icon` | `?Icon` | `null` | leading glyph |
| `prefix` | `[]const u8` | `""` | always-shown tag, e.g. `"GET"` |
| `prefix_color` | `?Rgba` | `null` | `null` = muted |
| `dirty` | `bool` | `false` | unsaved dot that swaps to a close x on hover |
| `pinned` | `bool` | `false` | shows a pin glyph; fires `on_pin`, not `on_close` |

The kit reports a proposed move/close/pin index - you mutate your own list. Keep
pinned tabs grouped at the front and clamp `on_move` so they stay grouped.
Re-exported: `TabItem`, `TabBarState`.

## Bottom bar

A bottom navigation bar: a persistent row of 3-5 top-level destinations (icon +
label) pinned to the screen bottom. A tap fires `on_select` with the index; the
active destination is highlighted. It is platform-agnostic - you describe the
destinations and the engine renders the host platform's bottom-nav idiom (a
Material-style bar on Android, the tab bar on iOS), so one definition feels
native on each. You own the selected index and a `BottomBarState` (it must keep
a stable address - hitboxes back-point into it). Two layouts:

- `.standard` - a full-width bar flush at the bottom edge.
- `.floating` - a detached, rounded bar inset from the edges, lifted on a shadow.

```zig
const App = struct {
    nav: zigui.BottomBarState = .{},
    tab: usize = 0,
};

const ITEMS = [_]zigui.BottomBarItem{
    .{ .icon = .grid, .label = "Home" },
    .{ .icon = .search, .label = "Search" },
    .{ .icon = .bell, .label = "Alerts" },
    .{ .icon = .person, .label = "Profile" },
};

fn on_select(app: *App, i: usize) void { app.tab = i; }

// The real system nav inset, from the safe-area body (device-specific, not a
// guess): the standard surface fills down into it to the screen edge.
const inset = f.size.height - (f.body.origin.y + f.body.size.height);

zigui.bottom_bar(&ITEMS, &app.nav, .{
    .active = app.tab,
    .style = .standard,
    .safe_bottom = inset,
    .on_select = zigui.on_index(App, on_select),
})
```

`bottom_bar(items, state, o)` - `items` is the destinations (borrowed for the
frame; keep it static), `state` is a `*BottomBarState`, `o` is:

| Option | Type | Default | Meaning |
|---|---|---|---|
| `active` | `usize` | `0` | active destination index |
| `style` | `BottomBarStyle` | `.standard` | `.standard` full-width bar or `.floating` detached bar |
| `indicator` | `bool` | `true` | highlight the active destination (the platform picks the treatment) |
| `safe_bottom` | `f32` | `0` | system nav inset; extends the standard surface down to the screen edge |
| `surface` | `?Rgba` | `null` | band / capsule fill (`null` = `theme.secondary`) |
| `active_color` | `?Rgba` | `null` | active icon + label (`null` = `theme.foreground`) |
| `inactive_color` | `?Rgba` | `null` | inactive icon + label (`null` = `theme.muted_foreground`) |
| `indicator_color` | `?Rgba` | `null` | the pill fill (`null` = a translucent `foreground`) |
| `on_select` | `?SelectFn` | `null` | wrap with `zigui.on_index(State, f)` (`fn(*State, usize)`) |

`BottomBarItem`: `icon: Icon`, `label: []const u8`.

`safe_bottom` is the bottom system-nav inset, derived from the frame, not
hardcoded - so it adapts to any device. The `.standard` bar's *surface* fills
down through it to the physical screen edge (behind the gesture handle) while
the icons + labels stay in the safe area above it; `.floating` floats clear of
the nav and ignores it. The default `surface` is `theme.secondary` (a distinct
elevated tone) because some themes set `card == background`; override any color
to match your palette. `bottom_bar` only draws the bar - render the body per
`active` yourself. The `state` and the `items` slice must outlive the frame -
store `items` as a module-level constant. Re-exported: `BottomBarItem`,
`BottomBarState`, `BottomBarStyle`, `BottomBarOpts`.

## Resize handle

A single draggable divider as a composable node: drop it between two panes in a
`row` (or `col`) and it reads its own laid-out length. The `(x, y)` it reports is
window-space, so clamp it into the new pane size yourself (as the sidebar's own
handle does).

```zig
fn resize(app: *App, x: f32, _: f32) void {
    app.left_w = std.math.clamp(x, 200, 600);
}

zigui.row(.{ .grow = 1 }, &.{
    left_pane(app),
    zigui.resize_handle(.{ .on_drag = zigui.on_drag(App, resize) }),
    right_pane(app),
})
```

`resize_handle(o)`:

| Option | Type | Default | Meaning |
|---|---|---|---|
| `orientation` | `Orientation` | `.horizontal` | `.horizontal` = panes side by side (a vertical grabber); `.vertical` = stacked panes |
| `kind` | `HandleKind` | `.line` | the grabber styling (a hairline) |
| `on_drag` | `?DragFn` | `null` | wrap with `zigui.on_drag(State, f)` (`fn(*State, f32, f32)`) |
| `on_drag_end` | `?DragEndFn` | `null` | wrap with `zigui.on(State, f)`; fires on release |
| `ctx` | `?*anyopaque` | `null` | handler context (defaults to the run state) |

## Overlays

`dialog`, `sheet`, `menu_overlay`, and `popover_overlay` are not placed in the
body. They go in the window's **overlay region** - a modal/anchored layer that
draws on top of and blocks the body when present.

`app.run` takes a `Views` struct with an `overlay` view (`fn(*Frame, State)
?*Node`). Return the overlay node when open, `null` when not:

```zig
try app.run(&state, .{
    .body = App.body,
    .overlay = App.overlay, // dialog / sheet / anchored menu / popover
});
```

```zig
fn overlay(f: *zigui.Frame, app: *App) ?*zigui.Node {
    if (!app.dialog_open) return null;
    return zigui.dialog(.{ ... });
}
```

When several overlays can be open, chain them - first non-null wins:

```zig
fn overlay(f: *zigui.Frame, app: *App) ?*zigui.Node {
    if (menu_overlay_view(f, app)) |n| return n;
    if (popover_overlay_view(f, app)) |n| return n;
    if (!app.dialog_open) return null;
    return zigui.dialog(.{ ... });
}
```

The facade injects `paint`, `ctx`, and `theme` - leave those option fields
unset.

### rect_out anchoring

`menu` and `popover` float *next to a trigger*, so they need the trigger's
laid-out screen rect. A trigger (`button`, `select`) writes its post-layout box
to a `rect_out: ?*[4]f32` you own (`{x, y, w, h}`), and the overlay reads it back
through its `trigger: *const [4]f32` field the same frame:

```zig
const App = struct {
    open: bool = false,
    rect: [4]f32 = .{ 0, 0, 0, 0 },
};

// in body:
zigui.button("Open menu", .{
    .variant = .outline,
    .on_click = zigui.on(App, on_open),
    .rect_out = &app.rect, // the button stamps its rect here
})

// in overlay:
zigui.menu_overlay(.{ .trigger = &app.rect, ... })
```

`dialog` and `sheet` cover the whole region (modal), so they take no `trigger`.

### Dismiss

Overlays close on an outside click via `on_dismiss` (`dialog`, `menu`,
`popover`) or `on_close` (`sheet`). Wire it to a handler that clears your open
flag:

```zig
fn on_dismiss(app: *App) void { app.open = false; }
```

### dialog

A modal alert/confirm. Frosts the backdrop, scrims, centers a card, and blocks
the body.

```zig
fn cancel(app: *App) void { app.open = false; }
fn confirm(app: *App) void { app.open = false; /* do it */ }

zigui.dialog(.{
    .title = "Are you absolutely sure?",
    .description = "This permanently deletes your account.",
    .actions = &.{
        .{ .label = "Cancel", .variant = .outline, .on_click = zigui.on(App, cancel) },
        .{ .label = "Delete", .variant = .destructive, .on_click = zigui.on(App, confirm) },
    },
    .on_dismiss = zigui.on(App, cancel),
})
```

`dialog(o)`:

| Option | Type | Default | Meaning |
|---|---|---|---|
| `title` | `[]const u8` | required | heading |
| `description` | `?[]const u8` | `null` | body text |
| `actions` | `[]const DialogAction` | `&.{}` | footer buttons (max 4) |
| `width` | `f32` | `420` | card width |
| `height` | `f32` | `188` | card height |
| `on_dismiss` | `?ClickFn` | `null` | wrap with `zigui.on(State, f)`; outside-click close |

`DialogAction`: `label: []const u8`, `variant: Variant = .default`,
`on_click: ?ClickFn`.

### sheet

A modal panel sliding in from an edge. You own the eased `open_t` (0..1); ease
it toward your target each frame and call `zigui.animate()` while it moves.

```zig
fn on_close(app: *App) void { app.sheet_open = false; }

fn overlay(f: *zigui.Frame, app: *App) ?*zigui.Node {
    const target: f32 = if (app.sheet_open) 1 else 0;
    app.sheet_t += (target - app.sheet_t) * 0.25;
    if (@abs(target - app.sheet_t) < 0.005) app.sheet_t = target;
    if (app.sheet_t != target) zigui.animate(); // keep ticking mid-slide
    if (app.sheet_t <= 0.001) return null;
    return zigui.sheet(.{
        .open_t = app.sheet_t,
        .top_inset = f.body.origin.y, // keep the titlebar crisp + live
        .title = "Edit profile",
        .description = "Make changes, then save.",
        .dismiss = app.sheet_open,
        .on_close = zigui.on(App, on_close),
    });
}
```

`sheet(o)`:

| Option | Type | Default | Meaning |
|---|---|---|---|
| `side` | `SheetSide` | `.right` | `.top`, `.right`, `.bottom`, `.left` |
| `size` | `f32` | `360` | panel extent on its axis |
| `open_t` | `f32` | `1` | caller-eased slide progress 0..1 |
| `top_inset` | `f32` | `0` | leave the title band uncovered (pass `f.body.origin.y`) |
| `title` | `[]const u8` | `""` | header |
| `description` | `[]const u8` | `""` | subheader |
| `scrim_alpha` | `f32` | `0.18` | body dim at fully open |
| `dismiss` | `bool` | `true` | wire the scrim outside-click |
| `on_close` | `?ClickFn` | `null` | wrap with `zigui.on(State, f)` |

Re-exported: `SheetSide`.

### menu_overlay

A dropdown of actions anchored below a trigger. You own a `MenuState`
(cross-frame flyout/click scratch); call `state.reset()` when you open the menu
to collapse stale flyouts.

```zig
const App = struct {
    open: bool = false,
    state: zigui.MenuState = .{},
    rect: [4]f32 = .{ 0, 0, 0, 0 },
    notify: bool = false,
};

fn on_dismiss(app: *App) void { app.open = false; }
fn on_select(app: *App, id: []const u8) void {
    if (std.mem.eql(u8, id, "notify")) { app.notify = !app.notify; return; }
    app.open = false;
}

fn overlay(f: *zigui.Frame, app: *App) ?*zigui.Node {
    if (!app.open) return null;
    const items = [_]zigui.MenuEntry{
        .{ .kind = .item, .id = "profile", .label = "Profile", .icon = .person,
           .shortcut = zigui.key_command ++ " P" },
        .{ .kind = .item, .id = "settings", .label = "Settings", .icon = .gear },
        .{ .kind = .separator },
        .{ .kind = .checkbox, .id = "notify", .label = "Notifications", .checked = app.notify },
        .{ .kind = .separator },
        .{ .kind = .item, .id = "logout", .label = "Log out", .destructive = true },
    };
    return zigui.menu_overlay(.{
        .items = &items,
        .state = &app.state,
        .trigger = &app.rect,
        .view_y = f.body.origin.y,
        .view_h = f.body.size.height,
        .on_select = zigui.on_id(App, on_select),
        .on_dismiss = zigui.on(App, on_dismiss),
    });
}
```

`menu_overlay(o)`:

| Option | Type | Default | Meaning |
|---|---|---|---|
| `items` | `[]const MenuEntry` | required | menu rows |
| `state` | `*MenuState` | required | cross-frame; `state.reset()` on open |
| `trigger` | `*const [4]f32` | required | the trigger's `rect_out` |
| `view_y` | `f32` | `0` | content top (`f.body.origin.y`) for edge-flip + clip |
| `view_h` | `f32` | `0` | content height; `0` disables vertical flip/clip |
| `on_select` | `?SelectIdFn` | `null` | wrap with `zigui.on_id(State, f)` (`fn(*State, []const u8)`) |
| `on_dismiss` | `?ClickFn` | `null` | wrap with `zigui.on(State, f)` |

`MenuEntry`:

| Field | Type | Default | Meaning |
|---|---|---|---|
| `kind` | `ItemKind` | `.item` | `.item`, `.separator`, `.label`, `.checkbox`, `.radio`, `.submenu` |
| `id` | `[]const u8` | `""` | select id |
| `label` | `[]const u8` | `""` | row text |
| `icon` | `?Icon` | `null` | leading glyph; on a checked `.radio` it makes a select-style row (icon leads, the check moves to the trailing edge) |
| `shortcut` | `[]const u8` | `""` | right-aligned text hint, e.g. `zigui.key_command ++ " P"` |
| `keys` | `[]const []const u8` | `&.{}` | right-aligned `kbd` chips; takes precedence over `shortcut` |
| `checked` | `bool` | `false` | for `.checkbox` / `.radio` |
| `disabled` | `bool` | `false` | dimmed, non-interactive |
| `destructive` | `bool` | `false` | red text, red hover fill |
| `dot` | `?Rgba` | `null` | a colour dot in its own column (e.g. an environment colour), independent of the check; when any row sets it, all rows reserve the column |
| `dot_ring` | `bool` | `false` | draw the dot as a hollow ring instead of a filled disc (e.g. a "none" option) |
| `children` | `[]const MenuEntry` | `&.{}` | submenu rows (with `kind = .submenu`) |

`on_select` fires with the row's `id`; close the menu yourself (a `.checkbox`
row typically stays open). The top-level `items` may be a stack array - it's
copied into the arena - but submenu `children` slices must be static.
Re-exported: `MenuEntry`, `MenuState`.

### popover_overlay

A floating panel anchored below a trigger. Like `menu_overlay`, but it draws its
own title + description; an outside click closes.

```zig
zigui.popover_overlay(.{
    .title = "Dimensions",
    .description = "Set the layout for this view.",
    .trigger = &app.popover_rect,
    .view_y = f.body.origin.y,
    .view_h = f.body.size.height,
    .on_dismiss = zigui.on(App, on_dismiss),
})
```

`popover_overlay(o)`:

| Option | Type | Default | Meaning |
|---|---|---|---|
| `title` | `[]const u8` | required | panel heading |
| `description` | `[]const u8` | `""` | body text |
| `trigger` | `*const [4]f32` | required | the trigger's `rect_out` |
| `view_y` | `f32` | `0` | content top for the flip-above clamp |
| `view_h` | `f32` | `0` | content height; `0` disables the flip |
| `on_dismiss` | `?ClickFn` | `null` | wrap with `zigui.on(State, f)` |

### modal_backdrop

`zigui.modal_backdrop()` is a zero-size marker node. Drop it as the first child of
a modal you compose yourself - a `col` card in the overlay region, placed after
your own scrim - to lift every sibling drawn after it onto the modal top layer,
crisp over a frosted backdrop (the same layer the built-in `dialog` / `sheet`
use). You only need it when hand-composing a modal; the facade overlays lift
themselves.

## See also

- [Overview](overview.md) - stateless vs stateful, callbacks
- [Layout](../layout.md) - `col` / `row` / `grid` and `Config`
- [App & window](../app-window.md) - `App.run`, the `Views` struct, regions
- [Feedback](feedback.md) - `toasts` and `tooltip_overlay` (hud region)
