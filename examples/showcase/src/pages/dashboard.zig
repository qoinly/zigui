const zigui = @import("zigui");
const Node = zigui.Node;
const Frame = zigui.Frame;
const Theme = zigui.Theme;
const App = @import("../app.zig").App;
const page = @import("../scaffold/page.zig");

const ch = zigui.kit.chart;
const C_BLUE = zigui.Rgba.from_hex(0x3B82F6);

const Kpi = struct {
    title: []const u8,
    value: []const u8,
    delta: []const u8,
    icon: zigui.Icon,
};
const KPIS = [_]Kpi{
    .{
        .title = "Total Revenue",
        .value = "$45,231.89",
        .delta = "+20.1% from last month",
        .icon = .dollar_sign,
    },
    .{
        .title = "Subscriptions",
        .value = "+2,350",
        .delta = "+180.1% from last month",
        .icon = .people,
    },
    .{ .title = "Sales", .value = "+12,234", .delta = "+19% from last month", .icon = .creditcard },
    .{ .title = "Active Now", .value = "+573", .delta = "+201 since last hour", .icon = .bolt },
};

const Sale = struct {
    initials: []const u8,
    name: []const u8,
    email: []const u8,
    amount: []const u8,
};
const SALES = [_]Sale{
    .{
        .initials = "OM",
        .name = "Olivia Martin",
        .email = "olivia.martin@email.com",
        .amount = "+$1,999.00",
    },
    .{
        .initials = "JL",
        .name = "Jackson Lee",
        .email = "jackson.lee@email.com",
        .amount = "+$39.00",
    },
    .{
        .initials = "IN",
        .name = "Isabella Nguyen",
        .email = "isabella.nguyen@email.com",
        .amount = "+$299.00",
    },
    .{
        .initials = "WK",
        .name = "William Kim",
        .email = "will@email.com",
        .amount = "+$99.00",
    },
    .{
        .initials = "SD",
        .name = "Sofia Davis",
        .email = "sofia.davis@email.com",
        .amount = "+$39.00",
    },
};

const MONTHS = [_][]const u8{
    "Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
};
const OVERVIEW = [_]f32{ 4200, 6600, 3400, 5800, 7800, 5400, 8900, 4000, 6300, 3000, 7200, 4900 };
const OVERVIEW_SERIES = [_]ch.Series{.{ .color = C_BLUE, .values = &OVERVIEW }};

fn surface(t: *const Theme, min_w: f32, kids: []const *Node) *Node {
    return zigui.col(.{
        .gap = .sm,
        .pad = .lg,
        .grow = 1,
        .min_width = min_w,
        .bg = t.card,
        .border = t.border,
        .radius = t.radius,
    }, kids);
}

fn kpi_card(t: *const Theme, k: Kpi) *Node {
    return surface(t, 185, &.{
        zigui.row(.{ .cross = .center }, &.{
            zigui.text(k.title, .{ .size = 13, .weight = .medium, .muted = true }),
            zigui.spacer(),
            zigui.icon(k.icon, .{ .size = 16, .color = t.muted_foreground }),
        }),
        zigui.text(k.value, .{ .size = 24, .weight = .semi_bold }),
        zigui.text(k.delta, .{ .size = 12, .muted = true }),
    });
}

fn overview_card(t: *const Theme) *Node {
    return surface(t, 360, &.{
        zigui.text("Overview", .{ .size = 16, .weight = .semi_bold }),
        zigui.bar_chart(.{
            .theme = t,
            .series = &OVERVIEW_SERIES,
            .labels = &MONTHS,
            .grid = true,
        }, 260),
    });
}

fn sale_row(s: Sale) *Node {
    return zigui.row(.{ .gap = .sm, .cross = .center }, &.{
        zigui.avatar(s.initials, 36),
        zigui.col(.{ .gap = .xs, .grow = 1 }, &.{
            zigui.text(s.name, .{ .size = 13, .weight = .semi_bold }),
            zigui.text(s.email, .{ .size = 12, .muted = true }),
        }),
        zigui.text(s.amount, .{ .size = 13, .weight = .semi_bold }),
    });
}

fn sales_card(t: *const Theme) *Node {
    return surface(t, 320, &.{
        zigui.text("Recent Sales", .{ .size = 16, .weight = .semi_bold }),
        zigui.text("You made 265 sales this month.", .{ .size = 12, .muted = true }),
        sale_row(SALES[0]),
        sale_row(SALES[1]),
        sale_row(SALES[2]),
        sale_row(SALES[3]),
        sale_row(SALES[4]),
    });
}

const Product = struct {
    sku: []const u8,
    name: []const u8,
    category: []const u8,
    units: []const u8,
    stock: f32,
    delta: []const u8,
    up: bool,
    icon: zigui.Icon,
};
const PRODUCTS = [_]Product{
    .{
        .sku = "TS",
        .name = "Cotton Tee",
        .category = "Apparel",
        .units = "1,284",
        .stock = 0.82,
        .delta = "+12%",
        .up = true,
        .icon = .package,
    },
    .{
        .sku = "HD",
        .name = "Zip Hoodie",
        .category = "Apparel",
        .units = "972",
        .stock = 0.64,
        .delta = "+8%",
        .up = true,
        .icon = .package,
    },
    .{
        .sku = "MG",
        .name = "Ceramic Mug",
        .category = "Home",
        .units = "861",
        .stock = 0.41,
        .delta = "-3%",
        .up = false,
        .icon = .archive,
    },
    .{
        .sku = "SK",
        .name = "Wool Socks",
        .category = "Apparel",
        .units = "740",
        .stock = 0.90,
        .delta = "+5%",
        .up = true,
        .icon = .package,
    },
    .{
        .sku = "BG",
        .name = "Tote Bag",
        .category = "Accessories",
        .units = "613",
        .stock = 0.22,
        .delta = "+19%",
        .up = true,
        .icon = .archive,
    },
    .{
        .sku = "CP",
        .name = "Snap Cap",
        .category = "Accessories",
        .units = "498",
        .stock = 0.55,
        .delta = "-1%",
        .up = false,
        .icon = .package,
    },
    .{
        .sku = "NB",
        .name = "Pocket Notebook",
        .category = "Stationery",
        .units = "455",
        .stock = 0.73,
        .delta = "+4%",
        .up = true,
        .icon = .doc,
    },
    .{
        .sku = "ST",
        .name = "Sticker Pack",
        .category = "Stationery",
        .units = "402",
        .stock = 0.31,
        .delta = "+2%",
        .up = true,
        .icon = .doc,
    },
};

fn product_card(t: *const Theme, p: Product) *Node {
    return zigui.col(.{
        .gap = .sm,
        .pad = .md,
        .grow = 1,
        .bg = t.card,
        .border = t.border,
        .radius = t.radius,
    }, &.{
        zigui.row(.{ .gap = .sm, .cross = .center }, &.{
            zigui.avatar(p.sku, 36),
            zigui.col(.{ .gap = .xs, .grow = 1 }, &.{
                zigui.text(p.name, .{ .size = 13, .weight = .semi_bold }),
                zigui.text(p.category, .{ .size = 12, .muted = true }),
            }),
            zigui.icon(p.icon, .{ .size = 16, .color = t.muted_foreground }),
        }),
        zigui.text(p.units, .{ .size = 22, .weight = .semi_bold }),
        zigui.text("units sold", .{ .size = 11, .muted = true }),
        zigui.progress(p.stock, 6),
        zigui.row(.{ .cross = .center }, &.{
            zigui.text("in stock", .{ .size = 11, .muted = true }),
            zigui.spacer(),
            zigui.text(p.delta, .{
                .size = 11,
                .weight = .medium,
                .color = if (p.up) t.success else t.destructive,
            }),
        }),
    });
}

fn top_products(t: *const Theme) *Node {
    return zigui.col(.{
        .gap = .sm,
        .pad = .lg,
        .bg = t.card,
        .border = t.border,
        .radius = t.radius,
    }, &.{
        zigui.text("Top Products", .{ .size = 16, .weight = .semi_bold }),
        zigui.text("Best sellers this month, by units sold.", .{ .size = 12, .muted = true }),
        zigui.grid_cols(.{ .base = 1, .sm = 2, .md = 4 }, .{ .gap = .md }, &.{
            product_card(t, PRODUCTS[0]),
            product_card(t, PRODUCTS[1]),
            product_card(t, PRODUCTS[2]),
            product_card(t, PRODUCTS[3]),
            product_card(t, PRODUCTS[4]),
            product_card(t, PRODUCTS[5]),
            product_card(t, PRODUCTS[6]),
            product_card(t, PRODUCTS[7]),
        }),
    });
}

pub fn view(f: *Frame, app: *App) *Node {
    _ = app;
    const t = f.theme;
    return page.page(&.{
        zigui.row(.{ .cross = .center, .gap = .md, .wrap = true }, &.{
            zigui.col(.{ .grow = 1, .min_width = 240 }, &.{
                page.header("Dashboard", "Here's an overview of your store this month."),
            }),
            zigui.button("Jan 20 - Feb 09, 2024", .{ .variant = .outline }),
            zigui.button("Download", .{ .variant = .default }),
        }),
        zigui.grid(.{ .gap = .md }, &.{
            kpi_card(t, KPIS[0]),
            kpi_card(t, KPIS[1]),
            kpi_card(t, KPIS[2]),
            kpi_card(t, KPIS[3]),
        }),
        zigui.row(.{ .gap = .md, .wrap = true }, &.{
            overview_card(t),
            sales_card(t),
        }),
        top_products(t),
    });
}
