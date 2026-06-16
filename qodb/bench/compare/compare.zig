// Comparative benchmark: qodb vs SQLite vs LMDB on one identical workload, each engine
// driven through its own expert fast path (so no competitor is handicapped):
//   - SQLite: prepared statements, ONE transaction for the bulk insert, the index present
//     during load, tuned PRAGMAs. Measured in `:memory:` and in a WAL file.
//   - LMDB: ONE write transaction, MDB_APPEND for the in-order primary keys, a DUPSORT
//     named DB for the secondary index. Measured with MDB_NOSYNC and with default sync.
//   - qodb: the native API, in memory; its snapshot file is the on-disk figure.
// Record: { id, age, name, email, country } with a secondary index on `country`. The same
// pre-generated records and the same random get/query/scan inputs feed every engine.
//
// qodb's read speed is architectural, not a handicap on the others: a record it returns
// BORROWS its in-memory storage (valid until the next mutation) with no copy or API
// marshalling, whereas SQLite/LMDB inherently marshal each value through their API. That
// borrow is the tradeoff qodb makes for the speed (weaker value ownership/lifetime).
//
// Honest framing: qodb is an in-memory store with snapshot persistence; SQLite/LMDB are
// durable disk engines. The `:memory:` / NOSYNC rows are the like-for-like in-memory
// comparison (qodb's category); the file/sync rows show the durability the disk engines
// give that qodb does not. Memory columns measure different things per engine (qodb heap,
// SQLite's own allocator highwater, LMDB's mapped data) and are labeled, not summed.

const std = @import("std");
const qodb = @import("qodb");
const c = @cImport({
    @cInclude("sqlite3.h");
    @cInclude("lmdb.h");
});

const N: usize = 200_000;
const GETS: usize = 200_000;
const QUERIES: usize = 2_000;
const SCANS: usize = 20;

const countries = [_][]const u8{ "ID", "MY", "SG", "US", "JP", "DE", "BR", "IN" };

const Rec = struct { id: u64, age: u16, name: []const u8, email: []const u8, country: []const u8 };

var sink: u64 = 0;

// Tracks live/peak bytes of a backing allocator, to measure qodb's heap footprint.
const Counting = struct {
    backing: std.mem.Allocator,
    live: usize = 0,
    peak: usize = 0,
    fn allocator(self: *Counting) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }
    fn bump(self: *Counting, add: usize, sub: usize) void {
        self.live = self.live + add - sub;
        if (self.live > self.peak) self.peak = self.live;
    }
    fn alloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const s: *Counting = @ptrCast(@alignCast(ctx));
        const p = s.backing.vtable.alloc(s.backing.ptr, len, a, ra) orelse return null;
        s.bump(len, 0);
        return p;
    }
    fn resize(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, nl: usize, ra: usize) bool {
        const s: *Counting = @ptrCast(@alignCast(ctx));
        if (!s.backing.vtable.resize(s.backing.ptr, m, a, nl, ra)) return false;
        s.bump(nl, m.len);
        return true;
    }
    fn remap(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, nl: usize, ra: usize) ?[*]u8 {
        const s: *Counting = @ptrCast(@alignCast(ctx));
        const p = s.backing.vtable.remap(s.backing.ptr, m, a, nl, ra) orelse return null;
        s.bump(nl, m.len);
        return p;
    }
    fn free(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, ra: usize) void {
        const s: *Counting = @ptrCast(@alignCast(ctx));
        s.backing.vtable.free(s.backing.ptr, m, a, ra);
        s.live -= m.len;
    }
};

fn nowns(io: std.Io) i96 {
    return std.Io.Timestamp.now(io, .awake).nanoseconds;
}
fn since(io: std.Io, t0: i96) f64 {
    return @as(f64, @floatFromInt(@as(u64, @intCast(nowns(io) - t0)))) / 1e6; // ms
}

const Result = struct {
    label: []const u8,
    insert_ms: f64 = 0,
    get_ms: f64 = 0,
    query_ms: f64 = 0,
    scan_ms: f64 = 0,
    disk_mb: f64 = 0,
    mem_mb: f64 = 0,
    mem_src: []const u8 = "-",
};

fn header() void {
    std.debug.print("\n{s:<20} {s:>8} {s:>8} {s:>8} {s:>8} {s:>8} {s:>8}  {s}\n", .{
        "engine / mode", "insert", "get", "query", "scan", "disk", "mem", "mem source",
    });
    std.debug.print("{s:<20} {s:>8} {s:>8} {s:>8} {s:>8} {s:>8} {s:>8}\n", .{
        "", "M ops/s", "M ops/s", "k q/s", "M row/s", "MB", "MB",
    });
}
fn print_row(r: Result) void {
    const ins = @as(f64, N) / (r.insert_ms / 1e3) / 1e6;
    const get = @as(f64, GETS) / (r.get_ms / 1e3) / 1e6;
    const qps = @as(f64, QUERIES) / (r.query_ms / 1e3) / 1e3;
    const scn = @as(f64, @floatFromInt(N * SCANS)) / (r.scan_ms / 1e3) / 1e6;
    std.debug.print("{s:<20} {d:>8.2} {d:>8.2} {d:>8.1} {d:>8.1} {d:>8.2} {d:>8.1}  {s}\n", .{
        r.label, ins, get, qps, scn, r.disk_mb, r.mem_mb, r.mem_src,
    });
}

fn file_mb(io: std.Io, path: []const u8) f64 {
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return 0;
    return @as(f64, @floatFromInt(st.size)) / (1 << 20);
}

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Pre-generate the records and the random access inputs once; every engine sees them.
    var prng = std.Random.DefaultPrng.init(0x1234567);
    const rng = prng.random();
    const recs = try gpa.alloc(Rec, N);
    defer gpa.free(recs);
    const scratch = try gpa.alloc(u8, N * 32);
    defer gpa.free(scratch);
    var soff: usize = 0;
    for (recs, 0..) |*r, i| {
        const name = std.fmt.bufPrint(scratch[soff..], "user-{d}", .{i}) catch unreachable;
        soff += name.len;
        const email = std.fmt.bufPrint(scratch[soff..], "u{d}@example.io", .{i}) catch unreachable;
        soff += email.len;
        r.* = .{
            .id = i,
            .age = @intCast(rng.intRangeAtMost(u8, 0, 99)),
            .name = name,
            .email = email,
            .country = countries[rng.intRangeLessThan(usize, 0, countries.len)],
        };
    }
    const get_ids = try gpa.alloc(u64, GETS);
    defer gpa.free(get_ids);
    for (get_ids) |*g| g.* = rng.intRangeLessThan(u64, 0, N);
    const q_country = try gpa.alloc(usize, QUERIES);
    defer gpa.free(q_country);
    for (q_country) |*q| q.* = rng.intRangeLessThan(usize, 0, countries.len);

    std.debug.print("comparative benchmark - {d} records, get x{d}, query x{d}, scan x{d}\n", .{
        N, GETS, QUERIES, SCANS,
    });
    std.debug.print("sqlite {s}\n", .{c.sqlite3_libversion()});
    header();

    print_row(try bench_qodb(gpa, io, recs, get_ids, q_country));
    print_row(try bench_sqlite(io, recs, get_ids, q_country, ":memory:", false));
    print_row(try bench_sqlite(io, recs, get_ids, q_country, "/tmp/qodb_cmp_sqlite.db", true));
    print_row(try bench_lmdb(io, recs, get_ids, q_country, true));
    print_row(try bench_lmdb(io, recs, get_ids, q_country, false));

    std.debug.print("\n(sink {d})\n", .{sink});
}

fn bench_qodb(
    gpa: std.mem.Allocator,
    io: std.Io,
    recs: []const Rec,
    get_ids: []const u64,
    q_country: []const usize,
) !Result {
    const User = struct {
        id: u64,
        age: u16,
        name: []const u8,
        email: []const u8,
        country: []const u8,
    };
    const Users = qodb.Collection(User, .{ .key = "id", .indexes = &.{"country"} });
    var counting = Counting{ .backing = gpa };
    const a = counting.allocator();
    var db = Users.init(a);
    defer db.deinit();
    try db.ensure_capacity(N);

    var t0 = nowns(io);
    for (recs) |r| try db.upsert(.{
        .id = r.id,
        .age = r.age,
        .name = r.name,
        .email = r.email,
        .country = r.country,
    });
    const insert_ms = since(io, t0);
    const peak_mb = @as(f64, @floatFromInt(counting.peak)) / (1 << 20);

    t0 = nowns(io);
    for (get_ids) |id| if (db.get(id)) |u| {
        sink +%= u.age;
    };
    const get_ms = since(io, t0);

    t0 = nowns(io);
    for (q_country) |qi| {
        var it = db.find_by("country", countries[qi]);
        while (it.next()) |u| sink +%= u.id;
    }
    const query_ms = since(io, t0);

    t0 = nowns(io);
    for (0..SCANS) |_| {
        var it = db.query(qodb.query.gte("age", @as(u16, 50)));
        while (it.next()) |u| sink +%= u.id;
    }
    const scan_ms = since(io, t0);

    const path = "/tmp/qodb_cmp_qodb.bin";
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    try db.save(io, path);
    return .{
        .label = "qodb (in-mem)",
        .insert_ms = insert_ms,
        .get_ms = get_ms,
        .query_ms = query_ms,
        .scan_ms = scan_ms,
        .disk_mb = file_mb(io, path),
        .mem_mb = peak_mb,
        .mem_src = "heap",
    };
}

fn sx(rc: c_int) void {
    if (rc != c.SQLITE_OK and rc != c.SQLITE_DONE and rc != c.SQLITE_ROW) {
        std.debug.print("sqlite error {d}\n", .{rc});
    }
}

fn bench_sqlite(
    io: std.Io,
    recs: []const Rec,
    get_ids: []const u64,
    q_country: []const usize,
    path: [*c]const u8,
    is_file: bool,
) !Result {
    if (is_file) {
        std.Io.Dir.cwd().deleteFile(io, std.mem.span(path)) catch {};
    }
    var db: ?*c.sqlite3 = null;
    sx(c.sqlite3_open(path, &db));
    defer _ = c.sqlite3_close(db);
    const pragmas = if (is_file)
        "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; " ++
            "PRAGMA cache_size=-200000; PRAGMA temp_store=MEMORY;"
    else
        "PRAGMA synchronous=OFF; PRAGMA temp_store=MEMORY;";
    sx(c.sqlite3_exec(db, pragmas, null, null, null));
    sx(c.sqlite3_exec(db,
        \\CREATE TABLE users(
        \\  id INTEGER PRIMARY KEY, name TEXT, email TEXT, age INTEGER, country TEXT);
        \\CREATE INDEX idx_country ON users(country);
    , null, null, null));

    var ins: ?*c.sqlite3_stmt = null;
    sx(c.sqlite3_prepare_v2(db, "INSERT INTO users VALUES(?,?,?,?,?)", -1, &ins, null));
    defer _ = c.sqlite3_finalize(ins);
    var t0 = nowns(io);
    sx(c.sqlite3_exec(db, "BEGIN", null, null, null));
    for (recs) |r| {
        sx(c.sqlite3_bind_int64(ins, 1, @intCast(r.id)));
        sx(c.sqlite3_bind_text(ins, 2, r.name.ptr, @intCast(r.name.len), c.SQLITE_STATIC));
        sx(c.sqlite3_bind_text(ins, 3, r.email.ptr, @intCast(r.email.len), c.SQLITE_STATIC));
        sx(c.sqlite3_bind_int(ins, 4, r.age));
        sx(c.sqlite3_bind_text(ins, 5, r.country.ptr, @intCast(r.country.len), c.SQLITE_STATIC));
        sx(c.sqlite3_step(ins));
        sx(c.sqlite3_reset(ins));
    }
    sx(c.sqlite3_exec(db, "COMMIT", null, null, null));
    const insert_ms = since(io, t0);

    var get: ?*c.sqlite3_stmt = null;
    sx(c.sqlite3_prepare_v2(db, "SELECT age FROM users WHERE id=?", -1, &get, null));
    defer _ = c.sqlite3_finalize(get);
    t0 = nowns(io);
    for (get_ids) |id| {
        sx(c.sqlite3_bind_int64(get, 1, @intCast(id)));
        if (c.sqlite3_step(get) == c.SQLITE_ROW) sink +%= @intCast(c.sqlite3_column_int(get, 0));
        sx(c.sqlite3_reset(get));
    }
    const get_ms = since(io, t0);

    var qry: ?*c.sqlite3_stmt = null;
    sx(c.sqlite3_prepare_v2(db, "SELECT id FROM users WHERE country=?", -1, &qry, null));
    defer _ = c.sqlite3_finalize(qry);
    t0 = nowns(io);
    for (q_country) |qi| {
        const ct = countries[qi];
        sx(c.sqlite3_bind_text(qry, 1, ct.ptr, @intCast(ct.len), c.SQLITE_STATIC));
        while (c.sqlite3_step(qry) == c.SQLITE_ROW) {
            sink +%= @intCast(c.sqlite3_column_int64(qry, 0));
        }
        sx(c.sqlite3_reset(qry));
    }
    const query_ms = since(io, t0);

    var scn: ?*c.sqlite3_stmt = null;
    sx(c.sqlite3_prepare_v2(db, "SELECT id FROM users WHERE age>=50", -1, &scn, null));
    defer _ = c.sqlite3_finalize(scn);
    t0 = nowns(io);
    for (0..SCANS) |_| {
        while (c.sqlite3_step(scn) == c.SQLITE_ROW) {
            sink +%= @intCast(c.sqlite3_column_int64(scn, 0));
        }
        sx(c.sqlite3_reset(scn));
    }
    const scan_ms = since(io, t0);

    const hi = c.sqlite3_memory_highwater(0);
    var disk: f64 = 0;
    if (is_file) {
        sx(c.sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE)", null, null, null));
        disk = file_mb(io, std.mem.span(path));
    }
    return .{
        .label = if (is_file) "sqlite (WAL file)" else "sqlite (:memory:)",
        .insert_ms = insert_ms,
        .get_ms = get_ms,
        .query_ms = query_ms,
        .scan_ms = scan_ms,
        .disk_mb = disk,
        .mem_mb = @as(f64, @floatFromInt(hi)) / (1 << 20),
        .mem_src = "sqlite heap",
    };
}

// Pack a record's value bytes for LMDB: age(2) | name | 0 | email | 0 | country (no codec
// dependency, so LMDB is not charged qodb's encoding).
fn pack(buf: []u8, r: Rec) []u8 {
    var n: usize = 0;
    std.mem.writeInt(u16, buf[0..2], r.age, .little);
    n = 2;
    @memcpy(buf[n..][0..r.name.len], r.name);
    n += r.name.len;
    buf[n] = 0;
    n += 1;
    @memcpy(buf[n..][0..r.email.len], r.email);
    n += r.email.len;
    buf[n] = 0;
    n += 1;
    @memcpy(buf[n..][0..r.country.len], r.country);
    n += r.country.len;
    return buf[0..n];
}

fn lx(rc: c_int) void {
    if (rc != 0 and rc != c.MDB_NOTFOUND and rc != c.MDB_KEYEXIST) {
        std.debug.print("lmdb error {d}: {s}\n", .{ rc, c.mdb_strerror(rc) });
    }
}

fn bench_lmdb(
    io: std.Io,
    recs: []const Rec,
    get_ids: []const u64,
    q_country: []const usize,
    nosync: bool,
) !Result {
    const path = "/tmp/qodb_cmp_lmdb.mdb";
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    std.Io.Dir.cwd().deleteFile(io, path ++ "-lock") catch {};

    var env: ?*c.MDB_env = null;
    lx(c.mdb_env_create(&env));
    defer c.mdb_env_close(env);
    lx(c.mdb_env_set_maxdbs(env, 4));
    lx(c.mdb_env_set_mapsize(env, 1 << 30)); // 1 GiB
    const sync_flags: c_uint = if (nosync) c.MDB_NOSYNC | c.MDB_WRITEMAP else c.MDB_WRITEMAP;
    lx(c.mdb_env_open(env, path, sync_flags | c.MDB_NOSUBDIR, 0o664));

    var main_dbi: c.MDB_dbi = 0;
    var idx_dbi: c.MDB_dbi = 0;
    var pbuf: [128]u8 = undefined;
    // The integer keys/ids go in and come out as native bytes (MDB_INTEGERKEY compares as a
    // platform integer), so this harness assumes a little-endian host - x86_64 / ARM64.

    // Bulk insert: one write transaction; MDB_APPEND for the in-order integer keys; the
    // country->id secondary index in a DUPSORT db, maintained during the same load.
    var wtxn: ?*c.MDB_txn = null;
    lx(c.mdb_txn_begin(env, null, 0, &wtxn));
    lx(c.mdb_dbi_open(wtxn, "main", c.MDB_CREATE | c.MDB_INTEGERKEY, &main_dbi));
    lx(c.mdb_dbi_open(wtxn, "idx", c.MDB_CREATE | c.MDB_DUPSORT, &idx_dbi));
    var t0 = nowns(io);
    for (recs) |r| {
        var id = r.id;
        var mk = c.MDB_val{ .mv_size = 8, .mv_data = &id };
        const packed_val = pack(&pbuf, r);
        var mv = c.MDB_val{ .mv_size = packed_val.len, .mv_data = packed_val.ptr };
        lx(c.mdb_put(wtxn, main_dbi, &mk, &mv, c.MDB_APPEND));
        var ik = c.MDB_val{ .mv_size = r.country.len, .mv_data = @constCast(r.country.ptr) };
        var iv = c.MDB_val{ .mv_size = 8, .mv_data = &id };
        lx(c.mdb_put(wtxn, idx_dbi, &ik, &iv, 0));
    }
    lx(c.mdb_txn_commit(wtxn));
    const insert_ms = since(io, t0);

    var rtxn: ?*c.MDB_txn = null;
    lx(c.mdb_txn_begin(env, null, c.MDB_RDONLY, &rtxn));
    t0 = nowns(io);
    for (get_ids) |gid| {
        var id = gid;
        var mk = c.MDB_val{ .mv_size = 8, .mv_data = &id };
        var mv: c.MDB_val = undefined;
        if (c.mdb_get(rtxn, main_dbi, &mk, &mv) == 0) {
            const b: [*]const u8 = @ptrCast(mv.mv_data);
            sink +%= std.mem.readInt(u16, b[0..2], .little);
        }
    }
    const get_ms = since(io, t0);

    var cur: ?*c.MDB_cursor = null;
    lx(c.mdb_cursor_open(rtxn, idx_dbi, &cur));
    t0 = nowns(io);
    for (q_country) |qi| {
        const ct = countries[qi];
        var ik = c.MDB_val{ .mv_size = ct.len, .mv_data = @constCast(ct.ptr) };
        var iv: c.MDB_val = undefined;
        var rc = c.mdb_cursor_get(cur, &ik, &iv, c.MDB_SET);
        while (rc == 0) {
            const b: [*]const u8 = @ptrCast(iv.mv_data);
            sink +%= std.mem.readInt(u64, b[0..8], .little);
            rc = c.mdb_cursor_get(cur, &ik, &iv, c.MDB_NEXT_DUP);
        }
    }
    const query_ms = since(io, t0);
    c.mdb_cursor_close(cur);

    var scur: ?*c.MDB_cursor = null;
    lx(c.mdb_cursor_open(rtxn, main_dbi, &scur));
    t0 = nowns(io);
    for (0..SCANS) |_| {
        var mk: c.MDB_val = undefined;
        var mv: c.MDB_val = undefined;
        var rc = c.mdb_cursor_get(scur, &mk, &mv, c.MDB_FIRST);
        while (rc == 0) {
            const b: [*]const u8 = @ptrCast(mv.mv_data);
            if (std.mem.readInt(u16, b[0..2], .little) >= 50) {
                const kp: [*]const u8 = @ptrCast(mk.mv_data);
                sink +%= std.mem.readInt(u64, kp[0..8], .little);
            }
            rc = c.mdb_cursor_get(scur, &mk, &mv, c.MDB_NEXT);
        }
    }
    const scan_ms = since(io, t0);
    c.mdb_cursor_close(scur);
    c.mdb_txn_abort(rtxn);

    // The data file is sparse (created at the full mapsize); the real footprint is the
    // used pages, which is also LMDB's resident memory (it is a single mmap).
    var stat: c.MDB_stat = undefined;
    var info: c.MDB_envinfo = undefined;
    _ = c.mdb_env_stat(env, &stat);
    _ = c.mdb_env_info(env, &info);
    const used = (info.me_last_pgno + 1) * stat.ms_psize;
    const used_mb = @as(f64, @floatFromInt(used)) / (1 << 20);
    return .{
        .label = if (nosync) "lmdb (nosync)" else "lmdb (sync)",
        .insert_ms = insert_ms,
        .get_ms = get_ms,
        .query_ms = query_ms,
        .scan_ms = scan_ms,
        .disk_mb = used_mb,
        .mem_mb = used_mb,
        .mem_src = "mmap used",
    };
}
