//! zedis-compat: a compatibility suite driven by the bundled Zig client.
//!
//! By default it boots zedis in-process (on a background thread and an
//! ephemeral port), runs every case against it over real TCP, restarts it
//! for the persistence cases, and finally checks the server's allocator for
//! leaks. With `--host/--port` it runs the protocol-level cases against any
//! server instead, which is how the expectations themselves are validated
//! against a reference Redis.

const std = @import("std");
const zedis = @import("zedis");
const harness = @import("harness.zig");
const basic = @import("cases_basic.zig");
const collections = @import("cases_collections.zig");
const advanced = @import("cases_advanced.zig");
const Harness = harness.Harness;
const sys = zedis.sys;

const Case = struct {
    name: []const u8,
    run: *const fn (*Harness) anyerror!void,
};

const cases = [_]Case{
    .{ .name = "connection", .run = basic.connection },
    .{ .name = "strings", .run = basic.strings },
    .{ .name = "counters", .run = basic.counters },
    .{ .name = "bits", .run = basic.bits },
    .{ .name = "keyspace", .run = basic.keyspace },
    .{ .name = "expiry", .run = basic.expiry },
    .{ .name = "scan", .run = basic.scan },
    .{ .name = "lists", .run = collections.lists },
    .{ .name = "blocking", .run = collections.blocking },
    .{ .name = "hashes", .run = collections.hashes },
    .{ .name = "sets", .run = collections.sets },
    .{ .name = "zsets", .run = collections.zsets },
    .{ .name = "pubsub", .run = advanced.pubsub },
    .{ .name = "transactions", .run = advanced.transactions },
    .{ .name = "protocol", .run = advanced.protocol },
    .{ .name = "resp3", .run = advanced.resp3 },
    .{ .name = "auth", .run = advanced.auth },
};

/// A zedis server running on a background thread.
const Embedded = struct {
    server: *zedis.Server,
    thread: std.Thread,

    fn start(gpa: std.mem.Allocator, dir: []const u8, appendonly: bool) !Embedded {
        var config: zedis.Config = .{ .port = 0, .dir = dir, .appendonly = appendonly, .hz = 50 };
        config.appendfsync = .always;
        const server = try zedis.Server.init(gpa, config);
        errdefer server.deinit();
        server.log.quiet = true;
        try server.start();
        const thread = try std.Thread.spawn(.{}, runServer, .{server});
        return .{ .server = server, .thread = thread };
    }

    fn runServer(server: *zedis.Server) void {
        server.run() catch |err| std.debug.print("embedded server stopped: {s}\n", .{@errorName(err)});
    }

    fn port(self: *const Embedded) u16 {
        return self.server.port;
    }

    fn stop(self: *Embedded) void {
        self.server.stop();
        self.thread.join();
        self.server.deinit();
    }
};

fn infoField(h: *Harness, section: []const u8, field: []const u8) ![]const u8 {
    const v = try h.call(&.{ "INFO", section });
    const text = v.str() orelse return error.NoInfo;
    var it = std.mem.splitSequence(u8, text, "\r\n");
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, field) and line.len > field.len and line[field.len] == ':') {
            return line[field.len + 1 ..];
        }
    }
    return error.NoSuchField;
}

/// Writes a representative dataset whose AOF exercises every rewrite rule
/// (relative TTLs, random pops, float increments, transactions, SELECT).
fn writeDataset(h: *Harness) !void {
    try h.expect(&.{ "SET", "str", "hello" }, .ok);
    try h.expect(&.{ "SET", "ttl", "v", "EX", "1000" }, .ok);
    try h.expect(&.{ "SET", "gone", "v", "PX", "1" }, .ok);
    try h.expect(&.{ "INCRBYFLOAT", "flt", "1.25" }, .{ .bulk = "1.25" });
    try h.expect(&.{ "RPUSH", "list", "a", "b", "c", "d" }, .{ .int = 4 });
    try h.expect(&.{ "LMOVE", "list", "list2", "LEFT", "LEFT" }, .{ .bulk = "a" });
    try h.expect(&.{ "HSET", "hash", "f1", "v1", "f2", "v2" }, .{ .int = 2 });
    try h.expect(&.{ "HINCRBYFLOAT", "hash", "n", "0.5" }, .{ .bulk = "0.5" });
    try h.expect(&.{ "SADD", "set", "x", "y", "z" }, .{ .int = 3 });
    try h.expect(&.{ "SPOP", "set" }, .any);
    try h.expect(&.{ "ZADD", "zset", "1.5", "a", "-2", "b" }, .{ .int = 2 });
    try h.expect(&.{ "ZINCRBY", "zset", "10", "b" }, .{ .double = "8" });
    try h.expect(&.{ "EXPIRE", "hash", "5000" }, .{ .int = 1 });
    try h.expect(&.{"MULTI"}, .ok);
    try h.expect(&.{ "INCR", "counter" }, .{ .simple = "QUEUED" });
    try h.expect(&.{ "INCR", "counter" }, .{ .simple = "QUEUED" });
    try h.expect(&.{"EXEC"}, .{ .len = 2 });
    try h.expect(&.{ "SELECT", "3" }, .ok);
    try h.expect(&.{ "SET", "in-db3", "yes" }, .ok);
    try h.expect(&.{ "SELECT", "0" }, .ok);
    try h.expect(&.{ "SET", "deleted", "x" }, .ok);
    try h.expect(&.{ "DEL", "deleted" }, .{ .int = 1 });
}

fn verifyDataset(h: *Harness, set_card: i64) !void {
    try h.expect(&.{ "GET", "str" }, .{ .bulk = "hello" });
    const ttl = try h.call(&.{ "TTL", "ttl" });
    h.assert(ttl == .int and ttl.int > 990 and ttl.int <= 1000, "TTL survived restart as {s}", .{h.render(ttl)});
    try h.expect(&.{ "EXISTS", "gone" }, .{ .int = 0 });
    try h.expect(&.{ "GET", "flt" }, .{ .bulk = "1.25" });
    try h.expect(&.{ "LRANGE", "list", "0", "-1" }, .{ .strs = &.{ "b", "c", "d" } });
    try h.expect(&.{ "LRANGE", "list2", "0", "-1" }, .{ .strs = &.{"a"} });
    try h.expect(&.{ "HGET", "hash", "n" }, .{ .bulk = "0.5" });
    try h.expect(&.{ "HLEN", "hash" }, .{ .int = 3 });
    const httl = try h.call(&.{ "TTL", "hash" });
    h.assert(httl == .int and httl.int > 4990, "hash TTL survived restart as {s}", .{h.render(httl)});
    try h.expect(&.{ "SCARD", "set" }, .{ .int = set_card });
    try h.expect(&.{ "ZRANGE", "zset", "0", "-1", "WITHSCORES" }, .{ .strs = &.{ "a", "1.5", "b", "8" } });
    try h.expect(&.{ "GET", "counter" }, .{ .bulk = "2" });
    try h.expect(&.{ "EXISTS", "deleted" }, .{ .int = 0 });
    try h.expect(&.{ "SELECT", "3" }, .ok);
    try h.expect(&.{ "GET", "in-db3" }, .{ .bulk = "yes" });
    try h.expect(&.{ "SELECT", "0" }, .ok);
}

fn persistence(gpa: std.mem.Allocator, dir: []const u8, failures: *usize, checks: *usize) !void {
    var server = try Embedded.start(gpa, dir, true);
    var running = true;
    defer if (running) server.stop();
    var h = try Harness.init(gpa, "127.0.0.1", server.port(), false);
    defer h.deinit();
    h.case = "persistence";
    defer {
        checks.* += h.checks;
        failures.* += h.failures.items.len;
        report(&h);
    }

    try writeDataset(&h);
    var i: usize = 0;
    while (i < 500) : (i += 1) try h.expect(&.{ "INCR", "hot" }, .any);
    try h.expect(&.{ "SET", "rewrite-marker", "before" }, .ok);

    // Restart and reload from the AOF.
    h.conn.close();
    server.stop();
    running = false;
    server = try Embedded.start(gpa, dir, true);
    running = true;
    h.conn = try zedis.client.Connection.connect(gpa, "127.0.0.1", server.port());
    h.port = server.port();
    try verifyDataset(&h, 2);
    try h.expect(&.{ "GET", "hot" }, .{ .bulk = "500" });

    // Background rewrite compacts the log while writes continue.
    const size_before = try std.fmt.parseInt(u64, try infoField(&h, "persistence", "aof_current_size"), 10);
    try h.expect(&.{"BGREWRITEAOF"}, .{ .simple = "Background append only file rewriting started" });
    try h.expect(&.{ "SET", "rewrite-marker", "during" }, .ok);
    var waited: usize = 0;
    while (waited < 10_000) : (waited += 20) {
        const in_progress = try infoField(&h, "persistence", "aof_rewrite_in_progress");
        if (std.mem.eql(u8, in_progress, "0")) break;
        sys.sleepMs(20);
    }
    try h.expect(&.{ "SET", "rewrite-marker", "after" }, .ok);
    const status = try infoField(&h, "persistence", "aof_last_bgrewrite_status");
    h.assert(std.mem.eql(u8, status, "ok"), "rewrite status was {s}", .{status});
    const size_after = try std.fmt.parseInt(u64, try infoField(&h, "persistence", "aof_current_size"), 10);
    h.assert(size_after < size_before, "AOF did not shrink: {d} -> {d} bytes", .{ size_before, size_after });

    h.conn.close();
    server.stop();
    running = false;
    server = try Embedded.start(gpa, dir, true);
    running = true;
    h.conn = try zedis.client.Connection.connect(gpa, "127.0.0.1", server.port());
    try verifyDataset(&h, 2);
    try h.expect(&.{ "GET", "rewrite-marker" }, .{ .bulk = "after" });
    try h.expect(&.{ "GET", "hot" }, .{ .bulk = "500" });

    // A torn write at the end of the file is truncated on load.
    h.conn.close();
    server.stop();
    running = false;
    var pbuf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&pbuf, "{s}/appendonly.aof", .{dir});
    const fd = try sys.open(path, .append_create);
    try sys.writeAll(fd, "*3\r\n$3\r\nSET\r\n$4\r\ntorn\r\n$5\r\nhal");
    sys.close(fd);
    server = try Embedded.start(gpa, dir, true);
    running = true;
    h.conn = try zedis.client.Connection.connect(gpa, "127.0.0.1", server.port());
    try h.expect(&.{ "EXISTS", "torn" }, .{ .int = 0 });
    try h.expect(&.{ "GET", "rewrite-marker" }, .{ .bulk = "after" });
    try h.expect(&.{ "SET", "after-truncate", "ok" }, .ok);

    // DEBUG RELOAD replays the AOF in place.
    try h.expect(&.{ "DEBUG", "RELOAD" }, .ok);
    try h.expect(&.{ "GET", "after-truncate" }, .{ .bulk = "ok" });
    try verifyDataset(&h, 2);

    // CONFIG SET appendonly toggles persistence at runtime.
    try h.expect(&.{ "CONFIG", "SET", "appendonly", "no" }, .ok);
    try h.expect(&.{ "SET", "not-persisted", "1" }, .ok);
    try h.expect(&.{ "CONFIG", "SET", "appendonly", "yes" }, .ok);
    try h.expect(&.{ "SET", "persisted-again", "1" }, .ok);
    h.conn.close();
    server.stop();
    running = false;
    server = try Embedded.start(gpa, dir, true);
    running = true;
    h.conn = try zedis.client.Connection.connect(gpa, "127.0.0.1", server.port());
    // Enabling AOF writes a full snapshot, so both keys survive.
    try h.expect(&.{ "EXISTS", "not-persisted", "persisted-again" }, .{ .int = 2 });
    server.stop();
    running = false;
}

fn report(h: *Harness) void {
    for (h.failures.items) |f| {
        std.debug.print("  FAIL [{s}] {s}\n       {s}\n", .{ f.case, f.command, f.detail });
    }
}

fn makeTempDir(buf: []u8) ![]const u8 {
    const path = try std.fmt.bufPrint(buf, "/tmp/zedis-compat-{d}-{d}", .{ sys.getPid(), sys.nowUs() });
    var z = try sys.PathZ.init(path);
    _ = std.os.linux.mkdir(z.ptr(), 0o755);
    _ = &z;
    return path;
}

fn removeTempDir(dir: []const u8) void {
    var pbuf: [512]u8 = undefined;
    const files = [_][]const u8{"appendonly.aof"};
    for (files) |f| {
        const p = std.fmt.bufPrint(&pbuf, "{s}/{s}", .{ dir, f }) catch continue;
        sys.unlink(p) catch {};
    }
    var z = sys.PathZ.init(dir) catch return;
    _ = std.os.linux.rmdir(z.ptr());
    _ = &z;
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(arena);
    var host: []const u8 = "127.0.0.1";
    var port: ?u16 = null;
    var filter: ?[]const u8 = null;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--host") and i + 1 < argv.len) {
            host = argv[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, a, "--port") and i + 1 < argv.len) {
            port = try std.fmt.parseInt(u16, argv[i + 1], 10);
            i += 1;
        } else if (std.mem.eql(u8, a, "--filter") and i + 1 < argv.len) {
            filter = argv[i + 1];
            i += 1;
        } else {
            std.debug.print("usage: zedis-compat [--host H --port P] [--filter NAME]\n", .{});
            std.process.exit(2);
        }
    }
    sys.ignoreSigpipe();

    // The embedded server gets its own leak-checking allocator.
    var debug_alloc: std.heap.DebugAllocator(.{}) = .init;
    const server_gpa = debug_alloc.allocator();
    const gpa = init.gpa;

    var dir_buf: [128]u8 = undefined;
    const dir = try makeTempDir(&dir_buf);
    defer removeTempDir(dir);

    var embedded: ?Embedded = null;
    const external = port != null;
    if (!external) embedded = try Embedded.start(server_gpa, dir, false);
    const target_port = port orelse embedded.?.port();

    var total_checks: usize = 0;
    var total_failures: usize = 0;
    const t0 = sys.monotonicNs();
    for (cases) |case| {
        if (filter) |f| if (std.mem.indexOf(u8, case.name, f) == null) continue;
        var h = try Harness.init(gpa, host, target_port, external);
        defer h.deinit();
        h.case = case.name;
        _ = try h.call(&.{"FLUSHALL"});
        case.run(&h) catch |err| {
            h.fail(&.{}, "case aborted: {s}", .{@errorName(err)});
        };
        total_checks += h.checks;
        total_failures += h.failures.items.len;
        const status = if (h.failures.items.len == 0) "ok  " else "FAIL";
        std.debug.print("{s} {s:<14} {d} checks\n", .{ status, case.name, h.checks });
        report(&h);
    }

    if (embedded) |*e| e.stop();
    if (!external and (filter == null or std.mem.indexOf(u8, "persistence", filter.?) != null)) {
        var checks: usize = 0;
        var failures: usize = 0;
        persistence(server_gpa, dir, &failures, &checks) catch |err| {
            std.debug.print("  FAIL [persistence] aborted: {s}\n", .{@errorName(err)});
            failures += 1;
        };
        std.debug.print("{s} {s:<14} {d} checks\n", .{ if (failures == 0) "ok  " else "FAIL", "persistence", checks });
        total_checks += checks;
        total_failures += failures;
    }

    if (!external) {
        if (debug_alloc.deinit() == .leak) {
            std.debug.print("FAIL server allocator reported leaks\n", .{});
            total_failures += 1;
        }
    }
    const elapsed_ms = (sys.monotonicNs() - t0) / 1_000_000;
    std.debug.print("\n{d} checks, {d} failures ({d} ms)\n", .{ total_checks, total_failures, elapsed_ms });
    if (total_failures > 0) std.process.exit(1);
}
