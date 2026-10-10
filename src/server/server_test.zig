//! In-process tests for command execution and AOF propagation. These run
//! commands through the real dispatcher without sockets, then inspect the
//! reply bytes and the AOF buffer directly.

const std = @import("std");
const resp = @import("../resp.zig");
const Server = @import("server.zig").Server;
const Client = @import("client.zig").Client;
const Config = @import("config.zig").Config;
const testing = std.testing;

const Fixture = struct {
    server: *Server,
    clients: [2]*Client,

    fn init() !Fixture {
        const gpa = testing.allocator;
        const server = try Server.init(gpa, Config{ .databases = 4 });
        errdefer server.deinit();
        server.log.quiet = true;
        // Enable propagation without a file: commands accumulate in the
        // AOF buffer, which is what these tests inspect.
        server.aof.enabled = true;
        var f: Fixture = .{ .server = server, .clients = undefined };
        for (&f.clients, 0..) |*c, i| {
            c.* = try gpa.create(Client);
            // A descriptor that is never registered with epoll; replies stay
            // buffered in `out`.
            c.*.* = Client.init(gpa, 100 + i, 1000 + @as(i32, @intCast(i)), .{ .addr = .{ 127, 0, 0, 1 }, .port = 0 }, 0);
            c.*.authenticated = true;
        }
        return f;
    }

    fn deinit(f: *Fixture) void {
        for (f.clients) |c| {
            if (c.blocked != null) f.server.unblockClient(c, false);
            f.server.unwatchAll(c);
            f.server.unsubscribeAll(c, false);
            c.deinit();
            testing.allocator.destroy(c);
        }
        f.server.pending_writes.clearRetainingCapacity();
        f.server.unblocked.clearRetainingCapacity();
        f.server.aof.enabled = false;
        f.server.deinit();
    }

    /// Runs an inline command line on client `ci` and returns its reply.
    fn run(f: *Fixture, ci: usize, line: []const u8) ![]const u8 {
        const gpa = testing.allocator;
        var storage: std.ArrayList(u8) = .empty;
        defer storage.deinit(gpa);
        var bounds: std.ArrayList(struct { start: usize, len: usize }) = .empty;
        defer bounds.deinit(gpa);
        try resp.splitArgs(gpa, line, &storage, &bounds);
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(gpa);
        for (bounds.items) |b| try args.append(gpa, storage.items[b.start..][0..b.len]);
        const c = f.clients[ci];
        c.out.clearRetainingCapacity();
        f.server.processCommand(c, args.items);
        return c.out.items;
    }

    fn aof(f: *Fixture) []const u8 {
        return f.server.aof.buf.items;
    }

    fn clearAof(f: *Fixture) void {
        f.server.aof.buf.clearRetainingCapacity();
    }

    /// Decodes the AOF buffer into one line per command, args joined by spaces.
    fn aofCommands(f: *Fixture, gpa: std.mem.Allocator) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        var p = resp.RequestParser.init(gpa);
        defer p.deinit();
        var off: usize = 0;
        const data = f.aof();
        while (off < data.len) {
            const r = (try p.parse(data[off..])).?;
            for (r.args, 0..) |a, i| {
                if (i > 0) try out.append(gpa, ' ');
                try out.appendSlice(gpa, a);
            }
            try out.append(gpa, '\n');
            off += r.consumed;
        }
        return out.toOwnedSlice(gpa);
    }
};

fn expectAof(f: *Fixture, expected: []const u8) !void {
    const got = try f.aofCommands(testing.allocator);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected, got);
}

test "writes propagate, reads do not, SELECT is emitted once" {
    var f = try Fixture.init();
    defer f.deinit();
    try testing.expectEqualStrings("+OK\r\n", try f.run(0, "SET a 1"));
    try testing.expectEqualStrings("$1\r\n1\r\n", try f.run(0, "GET a"));
    _ = try f.run(0, "SET b 2");
    _ = try f.run(0, "SET a 1 NX");
    try expectAof(&f, "SELECT 0\nSET a 1\nSET b 2\n");
    f.clearAof();
    _ = try f.run(0, "SELECT 2");
    _ = try f.run(0, "DEL nothing");
    _ = try f.run(0, "SET c 3");
    try expectAof(&f, "SELECT 2\nSET c 3\n");
}

test "relative TTLs are rewritten as absolute deadlines" {
    var f = try Fixture.init();
    defer f.deinit();
    _ = try f.run(0, "SET k v EX 100");
    _ = try f.run(0, "EXPIRE k 50");
    _ = try f.run(0, "SETEX s 10 v");
    const got = try f.aofCommands(testing.allocator);
    defer testing.allocator.free(got);
    var lines = std.mem.splitScalar(u8, got, '\n');
    _ = lines.next(); // SELECT
    try testing.expect(std.mem.startsWith(u8, lines.next().?, "SET k v PXAT "));
    try testing.expect(std.mem.startsWith(u8, lines.next().?, "PEXPIREAT k "));
    try testing.expect(std.mem.startsWith(u8, lines.next().?, "SET s v PXAT "));
}

test "non-deterministic commands propagate their effect" {
    var f = try Fixture.init();
    defer f.deinit();
    _ = try f.run(0, "SADD s only");
    f.clearAof();
    f.server.aof.selected_db = 0;
    try testing.expectEqualStrings("$4\r\nonly\r\n", try f.run(0, "SPOP s"));
    try testing.expectEqualStrings("$3\r\n1.5\r\n", try f.run(0, "INCRBYFLOAT f 1.5"));
    _ = try f.run(0, "ZADD z 1 m");
    _ = try f.run(0, "ZINCRBY z 2 m");
    _ = try f.run(0, "HINCRBYFLOAT h x 0.5");
    _ = try f.run(0, "GETDEL f");
    try expectAof(&f, "SREM s only\nSET f 1.5 KEEPTTL\nZADD z 1 m\nZADD z 3 m\nHSET h x 0.5\nDEL f\n");
}

test "EXEC wraps writes in MULTI/EXEC and skips read-only blocks" {
    var f = try Fixture.init();
    defer f.deinit();
    _ = try f.run(0, "MULTI");
    try testing.expectEqualStrings("+QUEUED\r\n", try f.run(0, "SET a 1"));
    _ = try f.run(0, "INCR a");
    try testing.expectEqualStrings("*2\r\n+OK\r\n:2\r\n", try f.run(0, "EXEC"));
    try expectAof(&f, "SELECT 0\nMULTI\nSET a 1\nINCR a\nEXEC\n");
    f.clearAof();
    _ = try f.run(0, "MULTI");
    _ = try f.run(0, "GET a");
    try testing.expectEqualStrings("*1\r\n$1\r\n2\r\n", try f.run(0, "EXEC"));
    try testing.expectEqualStrings("", f.aof());
}

test "lazy expiry propagates DEL and touches watchers" {
    var f = try Fixture.init();
    defer f.deinit();
    _ = try f.run(0, "SET k v PX 1");
    _ = try f.run(1, "WATCH k");
    f.clearAof();
    // Move the command clock past the deadline without sleeping.
    f.server.dbs[0].expires.values()[0] = 0;
    try testing.expectEqualStrings("$-1\r\n", try f.run(0, "GET k"));
    try expectAof(&f, "DEL k\n");
    try testing.expect(f.clients[1].dirty_cas);
    _ = try f.run(1, "MULTI");
    _ = try f.run(1, "SET k mine");
    try testing.expectEqualStrings("*-1\r\n", try f.run(1, "EXEC"));
}

test "blocked client is served by a push and the pop is propagated" {
    var f = try Fixture.init();
    defer f.deinit();
    try testing.expectEqualStrings("", try f.run(1, "BLPOP q 0"));
    try testing.expect(f.clients[1].blocked != null);
    try testing.expectEqual(@as(usize, 1), f.server.blocked_clients);
    f.clearAof();
    try testing.expectEqualStrings(":1\r\n", try f.run(0, "RPUSH q hello"));
    try testing.expect(f.clients[1].blocked == null);
    try testing.expectEqualStrings("*2\r\n$1\r\nq\r\n$5\r\nhello\r\n", f.clients[1].out.items);
    try expectAof(&f, "SELECT 0\nRPUSH q hello\nLPOP q\n");
    try testing.expectEqualStrings(":0\r\n", try f.run(0, "EXISTS q"));
}

test "BLMOVE chains readiness to the destination list" {
    var f = try Fixture.init();
    defer f.deinit();
    _ = try f.run(0, "BLMOVE a b LEFT RIGHT 0");
    _ = try f.run(1, "BLPOP b 0");
    // Pushing to `a` serves client 0, whose move makes `b` ready for client 1.
    var extra = try testing.allocator.create(Client);
    defer testing.allocator.destroy(extra);
    extra.* = Client.init(testing.allocator, 200, 2000, .{ .addr = .{ 127, 0, 0, 1 }, .port = 0 }, 0);
    defer extra.deinit();
    extra.authenticated = true;
    f.server.processCommand(extra, &.{ "LPUSH", "a", "x" });
    try testing.expectEqualStrings("$1\r\nx\r\n", f.clients[0].out.items);
    try testing.expectEqualStrings("*2\r\n$1\r\nb\r\n$1\r\nx\r\n", f.clients[1].out.items);
    try testing.expectEqualStrings(":0\r\n", try f.run(0, "EXISTS a b"));
}

test "pub/sub delivery and RESP2 subscriber restrictions" {
    var f = try Fixture.init();
    defer f.deinit();
    try testing.expectEqualStrings("*3\r\n$9\r\nsubscribe\r\n$2\r\nch\r\n:1\r\n", try f.run(1, "SUBSCRIBE ch"));
    f.clients[1].out.clearRetainingCapacity();
    try testing.expectEqualStrings(":1\r\n", try f.run(0, "PUBLISH ch hi"));
    try testing.expectEqualStrings("*3\r\n$7\r\nmessage\r\n$2\r\nch\r\n$2\r\nhi\r\n", f.clients[1].out.items);
    const denied = try f.run(1, "GET x");
    try testing.expect(std.mem.startsWith(u8, denied, "-ERR Can't execute 'get'"));
}

test "unknown commands and arity errors flag the transaction" {
    var f = try Fixture.init();
    defer f.deinit();
    _ = try f.run(0, "MULTI");
    try testing.expectEqualStrings("-ERR unknown command 'BOGUS', with args beginning with: 'x' \r\n", try f.run(0, "BOGUS x"));
    try testing.expect(f.clients[0].multi_error);
    try testing.expectEqualStrings("-EXECABORT Transaction discarded because of previous errors.\r\n", try f.run(0, "EXEC"));
    try testing.expect(!f.clients[0].in_multi);
}

test "replay applies a command stream and reports truncation" {
    var f = try Fixture.init();
    defer f.deinit();
    f.server.aof.enabled = false;
    const stream = "*3\r\n$3\r\nSET\r\n$1\r\na\r\n$1\r\n1\r\n*1\r\n$5\r\nMULTI\r\n*2\r\n$4\r\nINCR\r\n$1\r\na\r\n";
    const r = try f.server.replay(stream);
    // The trailing MULTI has no EXEC, so the valid prefix ends before it.
    try testing.expect(r.outcome == .open_multi);
    try testing.expectEqual(@as(usize, 27), r.valid_len);
    try testing.expectEqualStrings("$1\r\n1\r\n", try f.run(0, "GET a"));
    const bad = try f.server.replay("*1\r\n$x\r\n");
    try testing.expect(bad.outcome == .bad_format);
}
