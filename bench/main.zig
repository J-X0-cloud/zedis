//! zedis-bench: a small load generator in the spirit of redis-benchmark.
//!
//!   zedis-bench [-h host] [-p port] [-c clients] [-n requests] [-P pipeline]
//!               [-d value-size] [-t set,get,incr,lpush,rpop,sadd,zadd,hset]
//!
//! Each client runs on its own thread with its own connection and keeps
//! `-P` requests in flight. Latency is measured per pipeline batch and
//! reported as percentiles of the per-request share of that batch.

const std = @import("std");
const zedis = @import("zedis");
const sys = zedis.sys;
const Connection = zedis.client.Connection;

const Options = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 6379,
    clients: usize = 50,
    requests: usize = 100_000,
    pipeline: usize = 1,
    value_size: usize = 3,
    tests: []const u8 = "set,get,incr,lpush,rpop,sadd,zadd,hset",
};

const Worker = struct {
    opts: *const Options,
    test_name: []const u8,
    requests: usize,
    id: usize,
    latencies_us: std.ArrayList(u32) = .empty,
    errors: usize = 0,
    failed: bool = false,

    fn run(self: *Worker) void {
        self.runInner() catch {
            self.failed = true;
        };
    }

    fn runInner(self: *Worker) !void {
        const gpa = std.heap.smp_allocator;
        var conn = try Connection.connect(gpa, self.opts.host, self.opts.port);
        defer conn.close();
        const value = try gpa.alloc(u8, self.opts.value_size);
        defer gpa.free(value);
        @memset(value, 'x');
        try self.latencies_us.ensureTotalCapacity(gpa, self.requests / self.opts.pipeline + 1);
        var key_buf: [32]u8 = undefined;
        var member_buf: [32]u8 = undefined;
        var done: usize = 0;
        var seq: usize = 0;
        while (done < self.requests) {
            const batch = @min(self.opts.pipeline, self.requests - done);
            var i: usize = 0;
            while (i < batch) : (i += 1) {
                seq += 1;
                const key = std.fmt.bufPrint(&key_buf, "key:{d}", .{(self.id * 7919 + seq) % 100_000}) catch unreachable;
                const member = std.fmt.bufPrint(&member_buf, "m:{d}", .{seq % 10_000}) catch unreachable;
                const t = self.test_name;
                if (std.mem.eql(u8, t, "set")) {
                    try conn.append(&.{ "SET", key, value });
                } else if (std.mem.eql(u8, t, "get")) {
                    try conn.append(&.{ "GET", key });
                } else if (std.mem.eql(u8, t, "incr")) {
                    try conn.append(&.{ "INCR", "counter" });
                } else if (std.mem.eql(u8, t, "lpush")) {
                    try conn.append(&.{ "LPUSH", "mylist", value });
                } else if (std.mem.eql(u8, t, "rpop")) {
                    try conn.append(&.{ "RPOP", "mylist" });
                } else if (std.mem.eql(u8, t, "sadd")) {
                    try conn.append(&.{ "SADD", "myset", member });
                } else if (std.mem.eql(u8, t, "zadd")) {
                    try conn.append(&.{ "ZADD", "myzset", "1", member });
                } else if (std.mem.eql(u8, t, "hset")) {
                    try conn.append(&.{ "HSET", "myhash", member, value });
                } else return error.UnknownTest;
            }
            const t0 = sys.monotonicNs();
            try conn.flush();
            i = 0;
            while (i < batch) : (i += 1) {
                const v = try conn.read();
                if (v == .err) self.errors += 1;
            }
            conn.resetArena();
            const per_request = (sys.monotonicNs() - t0) / 1000 / batch;
            self.latencies_us.appendAssumeCapacity(@intCast(@min(per_request, std.math.maxInt(u32))));
            done += batch;
        }
    }
};

fn percentile(sorted: []const u32, p: f64) u32 {
    if (sorted.len == 0) return 0;
    const idx: usize = @intFromFloat(@floor(p / 100.0 * @as(f64, @floatFromInt(sorted.len - 1))));
    return sorted[idx];
}

fn runTest(opts: *const Options, name: []const u8) !void {
    const gpa = std.heap.smp_allocator;
    const workers = try gpa.alloc(Worker, opts.clients);
    defer gpa.free(workers);
    const threads = try gpa.alloc(std.Thread, opts.clients);
    defer gpa.free(threads);
    const per_client = opts.requests / opts.clients;
    for (workers, 0..) |*w, i| {
        const extra: usize = if (i < opts.requests % opts.clients) 1 else 0;
        w.* = .{ .opts = opts, .test_name = name, .requests = per_client + extra, .id = i };
    }
    const t0 = sys.monotonicNs();
    for (threads, workers) |*t, *w| t.* = try std.Thread.spawn(.{}, Worker.run, .{w});
    for (threads) |t| t.join();
    const elapsed_ns = sys.monotonicNs() - t0;

    var all: std.ArrayList(u32) = .empty;
    defer all.deinit(gpa);
    var errors: usize = 0;
    for (workers) |*w| {
        if (w.failed) {
            std.debug.print("{s}: a client failed (is the server running on {s}:{d}?)\n", .{ name, opts.host, opts.port });
            return error.ClientFailed;
        }
        try all.appendSlice(gpa, w.latencies_us.items);
        errors += w.errors;
        w.latencies_us.deinit(gpa);
    }
    std.mem.sort(u32, all.items, {}, std.sort.asc(u32));
    const secs = @as(f64, @floatFromInt(elapsed_ns)) / 1e9;
    const rps = @as(f64, @floatFromInt(opts.requests)) / secs;
    var upper: [16]u8 = undefined;
    std.debug.print("{s:<6} {d:>12.0} requests/s   p50 {d} us   p99 {d} us   max {d} us{s}\n", .{
        std.ascii.upperString(&upper, name[0..@min(name.len, 16)]),
        rps,
        percentile(all.items, 50),
        percentile(all.items, 99),
        if (all.items.len > 0) all.items[all.items.len - 1] else 0,
        if (errors > 0) "   (errors!)" else "",
    });
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(arena);
    var opts: Options = .{};
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (i + 1 >= argv.len) {
            std.debug.print("missing value for {s}\n", .{a});
            std.process.exit(2);
        }
        const v = argv[i + 1];
        i += 1;
        if (std.mem.eql(u8, a, "-h")) {
            opts.host = v;
        } else if (std.mem.eql(u8, a, "-p")) {
            opts.port = try std.fmt.parseInt(u16, v, 10);
        } else if (std.mem.eql(u8, a, "-c")) {
            opts.clients = @max(1, try std.fmt.parseInt(usize, v, 10));
        } else if (std.mem.eql(u8, a, "-n")) {
            opts.requests = @max(1, try std.fmt.parseInt(usize, v, 10));
        } else if (std.mem.eql(u8, a, "-P")) {
            opts.pipeline = @max(1, try std.fmt.parseInt(usize, v, 10));
        } else if (std.mem.eql(u8, a, "-d")) {
            opts.value_size = try std.fmt.parseInt(usize, v, 10);
        } else if (std.mem.eql(u8, a, "-t")) {
            opts.tests = v;
        } else {
            std.debug.print("unknown option {s}\n", .{a});
            std.process.exit(2);
        }
    }
    sys.ignoreSigpipe();
    std.debug.print("{d} clients, {d} requests, pipeline {d}, {d} byte values\n", .{ opts.clients, opts.requests, opts.pipeline, opts.value_size });
    var it = std.mem.splitScalar(u8, opts.tests, ',');
    while (it.next()) |name| {
        if (name.len == 0) continue;
        try runTest(&opts, name);
    }
}
