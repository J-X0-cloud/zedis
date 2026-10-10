//! Compatibility cases: pub/sub, transactions, the wire protocol, RESP3
//! and authentication.

const std = @import("std");
const zedis = @import("zedis");
const Harness = @import("harness.zig").Harness;

pub fn pubsub(h: *Harness) !void {
    var sub = try h.connect();
    defer sub.close();
    try h.expectOn(&sub, &.{ "SUBSCRIBE", "news", "sport" }, .{ .strs = &.{ "subscribe", "news", "1" } });
    try h.expectRead(&sub, &.{"SUBSCRIBE (2nd)"}, .{ .len = 3 });
    try sub.append(&.{ "PSUBSCRIBE", "n*" });
    try sub.flush();
    try h.expectRead(&sub, &.{"PSUBSCRIBE"}, .{ .len = 3 });

    try h.expect(&.{ "PUBLISH", "news", "hello" }, .{ .int = 2 });
    try h.expectRead(&sub, &.{"message"}, .{ .strs = &.{ "message", "news", "hello" } });
    try h.expectRead(&sub, &.{"pmessage"}, .{ .strs = &.{ "pmessage", "n*", "news", "hello" } });
    try h.expect(&.{ "PUBLISH", "zzz", "x" }, .{ .int = 0 });
    try h.expect(&.{ "PUBLISH", "sport", "goal" }, .{ .int = 1 });
    try h.expectRead(&sub, &.{"message sport"}, .{ .strs = &.{ "message", "sport", "goal" } });

    try h.expect(&.{ "PUBSUB", "CHANNELS" }, .{ .unordered = &.{ "news", "sport" } });
    try h.expect(&.{ "PUBSUB", "CHANNELS", "s*" }, .{ .strs = &.{"sport"} });
    try h.expect(&.{ "PUBSUB", "NUMSUB", "news", "none" }, .{ .strs = &.{ "news", "1", "none", "0" } });
    try h.expect(&.{ "PUBSUB", "NUMPAT" }, .{ .int = 1 });

    // RESP2 subscribers may only run pub/sub commands and PING.
    try h.expectOn(&sub, &.{ "GET", "k" }, .{ .err = "ERR Can't execute 'get'" });
    try h.expectOn(&sub, &.{"PING"}, .{ .strs = &.{ "pong", "" } });
    try h.expectOn(&sub, &.{ "UNSUBSCRIBE", "news" }, .{ .strs = &.{ "unsubscribe", "news", "2" } });
    try h.expectOn(&sub, &.{"PUNSUBSCRIBE"}, .{ .strs = &.{ "punsubscribe", "n*", "1" } });
    try h.expectOn(&sub, &.{"UNSUBSCRIBE"}, .{ .strs = &.{ "unsubscribe", "sport", "0" } });
    try h.expectOn(&sub, &.{ "GET", "k" }, .nil);

    // RESP3 subscribers receive push frames and may run any command.
    var sub3 = try h.connect();
    defer sub3.close();
    try h.expectOn(&sub3, &.{ "HELLO", "3" }, .{ .len = 7 });
    const confirm = try sub3.call(&.{ "SUBSCRIBE", "r3" });
    h.assert(confirm == .push, "RESP3 subscribe confirmation should be a push frame, got {s}", .{h.render(confirm)});
    try h.expectOn(&sub3, &.{ "SET", "while-subscribed", "1" }, .ok);
    try h.expect(&.{ "PUBLISH", "r3", "payload" }, .{ .int = 1 });
    const msg = try sub3.read();
    h.assert(msg == .push and msg.push.len == 3, "RESP3 message should be a 3 element push, got {s}", .{h.render(msg)});
}

pub fn transactions(h: *Harness) !void {
    try h.expect(&.{"MULTI"}, .ok);
    try h.expect(&.{ "SET", "a", "1" }, .{ .simple = "QUEUED" });
    try h.expect(&.{ "INCR", "a" }, .{ .simple = "QUEUED" });
    try h.expect(&.{ "GET", "a" }, .{ .simple = "QUEUED" });
    const r = try h.call(&.{"EXEC"});
    h.check(&.{"EXEC"}, r, .{ .len = 3 });
    if (r.items()) |items| if (items.len == 3) {
        h.check(&.{"EXEC[0]"}, items[0], .ok);
        h.check(&.{"EXEC[1]"}, items[1], .{ .int = 2 });
        h.check(&.{"EXEC[2]"}, items[2], .{ .bulk = "2" });
    };

    // Queue-time errors abort the whole transaction.
    try h.expect(&.{"MULTI"}, .ok);
    try h.expect(&.{ "SET", "a" }, .{ .err = "ERR wrong number of arguments" });
    try h.expect(&.{ "INCR", "a" }, .{ .simple = "QUEUED" });
    try h.expect(&.{"EXEC"}, .{ .err = "EXECABORT Transaction discarded because of previous errors." });
    try h.expect(&.{ "GET", "a" }, .{ .bulk = "2" });

    // Runtime errors do not stop later commands.
    try h.expect(&.{ "SET", "s", "x" }, .ok);
    try h.expect(&.{"MULTI"}, .ok);
    try h.expect(&.{ "LPUSH", "s", "y" }, .{ .simple = "QUEUED" });
    try h.expect(&.{ "INCR", "a" }, .{ .simple = "QUEUED" });
    const r2 = try h.call(&.{"EXEC"});
    if (r2.items()) |items| if (items.len == 2) {
        h.check(&.{"EXEC[0]"}, items[0], .{ .err = "WRONGTYPE" });
        h.check(&.{"EXEC[1]"}, items[1], .{ .int = 3 });
    } else h.fail(&.{"EXEC"}, "expected 2 replies, got {s}", .{h.render(r2)});

    try h.expect(&.{"MULTI"}, .ok);
    try h.expect(&.{"MULTI"}, .{ .err = "ERR MULTI calls can not be nested" });
    try h.expect(&.{ "WATCH", "a" }, .{ .err = "ERR WATCH inside MULTI is not allowed" });
    try h.expect(&.{"DISCARD"}, .ok);
    try h.expect(&.{"EXEC"}, .{ .err = "ERR EXEC without MULTI" });
    try h.expect(&.{"DISCARD"}, .{ .err = "ERR DISCARD without MULTI" });

    // WATCH: a concurrent write aborts EXEC.
    var other = try h.connect();
    defer other.close();
    try h.expect(&.{ "WATCH", "w" }, .ok);
    try h.expectOn(&other, &.{ "SET", "w", "theirs" }, .ok);
    try h.expect(&.{"MULTI"}, .ok);
    try h.expect(&.{ "SET", "w", "mine" }, .{ .simple = "QUEUED" });
    try h.expect(&.{"EXEC"}, .nil);
    try h.expect(&.{ "GET", "w" }, .{ .bulk = "theirs" });

    // Without interference EXEC succeeds, and EXEC clears all watches.
    try h.expect(&.{ "WATCH", "w" }, .ok);
    try h.expect(&.{"MULTI"}, .ok);
    try h.expect(&.{ "SET", "w", "mine" }, .{ .simple = "QUEUED" });
    try h.expect(&.{"EXEC"}, .{ .len = 1 });
    try h.expect(&.{ "GET", "w" }, .{ .bulk = "mine" });

    // UNWATCH forgets the watched keys.
    try h.expect(&.{ "WATCH", "w" }, .ok);
    try h.expectOn(&other, &.{ "SET", "w", "theirs" }, .ok);
    try h.expect(&.{"UNWATCH"}, .ok);
    try h.expect(&.{"MULTI"}, .ok);
    try h.expect(&.{ "GET", "w" }, .{ .simple = "QUEUED" });
    try h.expect(&.{"EXEC"}, .{ .len = 1 });

    // Watching a missing key that gets created also aborts.
    try h.expect(&.{ "WATCH", "created-later" }, .ok);
    try h.expectOn(&other, &.{ "SET", "created-later", "1" }, .ok);
    try h.expect(&.{"MULTI"}, .ok);
    try h.expect(&.{"EXEC"}, .nil);

    // FLUSHALL counts as touching every watched key that existed.
    try h.expect(&.{ "SET", "fw", "1" }, .ok);
    try h.expect(&.{ "WATCH", "fw" }, .ok);
    try h.expectOn(&other, &.{"FLUSHALL"}, .ok);
    try h.expect(&.{"MULTI"}, .ok);
    try h.expect(&.{"EXEC"}, .nil);

    // An expired watched key invalidates the transaction.
    try h.expect(&.{ "SET", "ew", "1", "PX", "50" }, .ok);
    try h.expect(&.{ "WATCH", "ew" }, .ok);
    zedis.sys.sleepMs(150);
    try h.expect(&.{"MULTI"}, .ok);
    try h.expect(&.{ "SET", "ew", "2" }, .{ .simple = "QUEUED" });
    try h.expect(&.{"EXEC"}, .nil);
}

pub fn protocol(h: *Harness) !void {
    var c = try h.connect();
    defer c.close();
    // Inline commands, as typed into telnet.
    try c.appendRaw("PING\r\n");
    try c.appendRaw("SET inline \"a b\"\r\n");
    try c.appendRaw("GET inline\r\n");
    try c.appendRaw("\r\n");
    try c.appendRaw("ECHO 'it\\'s'\n");
    try c.flush();
    try h.expectRead(&c, &.{"inline PING"}, .{ .simple = "PONG" });
    try h.expectRead(&c, &.{"inline SET"}, .ok);
    try h.expectRead(&c, &.{"inline GET"}, .{ .bulk = "a b" });
    try h.expectRead(&c, &.{"inline ECHO"}, .{ .bulk = "it's" });

    // Deep pipelining: many commands in one write, replies in order.
    var i: usize = 0;
    while (i < 2000) : (i += 1) try c.append(&.{ "INCR", "pipelined" });
    try c.flush();
    var last: i64 = 0;
    i = 0;
    while (i < 2000) : (i += 1) {
        c.resetArena();
        const v = try c.read();
        if (v == .int) last = v.int;
    }
    h.assert(last == 2000, "pipelined INCR ended at {d}, expected 2000", .{last});

    // Large values cross many reads and writes.
    const big = try h.gpa.alloc(u8, 3 * 1024 * 1024 + 7);
    defer h.gpa.free(big);
    for (big, 0..) |*b, j| b.* = @intCast(j % 251);
    try h.expect(&.{ "SET", "big", big }, .ok);
    const got = try h.call(&.{ "GET", "big" });
    h.assert(got == .bulk and std.mem.eql(u8, got.bulk, big), "3 MiB value did not round-trip", .{});
    try h.expect(&.{ "STRLEN", "big" }, .{ .int = 3 * 1024 * 1024 + 7 });

    // Protocol errors are reported and the connection is closed.
    var bad = try h.connect();
    defer bad.close();
    try bad.appendRaw("*1\r\n$abc\r\n");
    try bad.flush();
    try h.expectRead(&bad, &.{"bad bulk length"}, .{ .err = "ERR Protocol error: invalid bulk length" });
    const closed = if (bad.read()) |_| false else |err| err == error.ConnectionClosed;
    h.assert(closed, "connection should be closed after a protocol error", .{});

    var bad2 = try h.connect();
    defer bad2.close();
    try bad2.appendRaw("SET k \"unterminated\r\n");
    try bad2.flush();
    try h.expectRead(&bad2, &.{"unbalanced quotes"}, .{ .err = "ERR Protocol error: unbalanced quotes in request" });

    var bad3 = try h.connect();
    defer bad3.close();
    try bad3.appendRaw("*2\r\n+GET\r\n");
    try bad3.flush();
    try h.expectRead(&bad3, &.{"expected dollar"}, .{ .err = "ERR Protocol error: expected '$', got '+'" });

    // QUIT replies and then closes.
    var q = try h.connect();
    defer q.close();
    try h.expectOn(&q, &.{"QUIT"}, .ok);
    const q_closed = if (q.read()) |_| false else |err| err == error.ConnectionClosed;
    h.assert(q_closed, "connection should be closed after QUIT", .{});
}

pub fn resp3(h: *Harness) !void {
    var c = try h.connect();
    defer c.close();
    const hello = try c.call(&.{ "HELLO", "3" });
    h.assert(hello == .map, "HELLO 3 should return a map, got {s}", .{h.render(hello)});
    if (hello == .map) {
        var proto: i64 = 0;
        var i: usize = 0;
        while (i + 1 < hello.map.len) : (i += 2) {
            if (std.mem.eql(u8, hello.map[i].str() orelse "", "proto")) proto = hello.map[i + 1].int;
        }
        h.assert(proto == 3, "HELLO 3 reported proto {d}", .{proto});
    }
    try h.expectOn(&c, &.{ "HSET", "h", "f", "v" }, .{ .int = 1 });
    const all = try c.call(&.{ "HGETALL", "h" });
    h.assert(all == .map and all.map.len == 2, "HGETALL should be a map in RESP3, got {s}", .{h.render(all)});
    const members = try c.call(&.{ "SMEMBERS", "nope" });
    h.assert(members == .set, "SMEMBERS should be a set in RESP3, got {s}", .{h.render(members)});
    try h.expectOn(&c, &.{ "ZADD", "z", "2.5", "m" }, .{ .int = 1 });
    const score = try c.call(&.{ "ZSCORE", "z", "m" });
    h.assert(score == .double and score.double == 2.5, "ZSCORE should be a double in RESP3, got {s}", .{h.render(score)});
    const ranged = try c.call(&.{ "ZRANGE", "z", "0", "-1", "WITHSCORES" });
    const nested_ok = if (ranged.items()) |items| items.len == 1 and items[0] == .array else false;
    h.assert(nested_ok, "ZRANGE WITHSCORES should nest pairs in RESP3, got {s}", .{h.render(ranged)});
    const nil = try c.call(&.{ "GET", "missing" });
    h.assert(nil == .nil, "GET missing should be RESP3 null, got {s}", .{h.render(nil)});
    try h.expectOn(&c, &.{ "HELLO", "2" }, .{ .len = 14 });
    const flat = try c.call(&.{ "HGETALL", "h" });
    h.assert(flat == .array and flat.array.len == 2, "HGETALL should be flat after HELLO 2, got {s}", .{h.render(flat)});
}

pub fn auth(h: *Harness) !void {
    try h.expect(&.{ "AUTH", "x" }, .{ .err = "ERR AUTH <password> called without any password configured" });
    try h.expect(&.{ "CONFIG", "SET", "requirepass", "s3cret" }, .ok);
    var c = try h.connect();
    defer c.close();
    try h.expectOn(&c, &.{ "GET", "k" }, .{ .err = "NOAUTH Authentication required." });
    try h.expectOn(&c, &.{ "AUTH", "wrong" }, .{ .err = "WRONGPASS invalid username-password pair or user is disabled." });
    try h.expectOn(&c, &.{ "AUTH", "default", "s3cret" }, .ok);
    try h.expectOn(&c, &.{ "GET", "k" }, .nil);
    var c2 = try h.connect();
    defer c2.close();
    try h.expectOn(&c2, &.{ "HELLO", "3", "AUTH", "default", "s3cret", "SETNAME", "n" }, .{ .len = 7 });
    try h.expectOn(&c2, &.{ "CLIENT", "GETNAME" }, .{ .bulk = "n" });
    // The suite's own connection authenticated before the password was set.
    try h.expect(&.{ "CONFIG", "SET", "requirepass", "" }, .ok);
}

pub fn server(h: *Harness) !void {
    try h.expect(&.{ "SET", "in0", "a" }, .ok);
    try h.expect(&.{ "SELECT", "1" }, .ok);
    try h.expect(&.{ "SET", "in1", "b" }, .ok);
    try h.expect(&.{ "SWAPDB", "0", "1" }, .ok);
    try h.expect(&.{ "GET", "in0" }, .{ .bulk = "a" });
    try h.expect(&.{ "SELECT", "0" }, .ok);
    try h.expect(&.{ "GET", "in1" }, .{ .bulk = "b" });
    try h.expect(&.{ "SWAPDB", "0", "99" }, .{ .err = "ERR DB index is out of range" });
    try h.expect(&.{ "SWAPDB", "x", "1" }, .{ .err = "ERR invalid first DB index" });

    try h.expect(&.{ "SET", "num", "12345" }, .ok);
    try h.expect(&.{ "SET", "word", "hello" }, .ok);
    try h.expect(&.{ "OBJECT", "ENCODING", "num" }, .{ .bulk = "int" });
    try h.expect(&.{ "OBJECT", "ENCODING", "word" }, .{ .bulk = "embstr" });
    try h.expect(&.{ "OBJECT", "ENCODING", "missing" }, .nil);
    try h.expect(&.{ "OBJECT", "NOPE", "num" }, .{ .err = "ERR unknown subcommand" });

    const info = try h.call(&.{ "INFO", "keyspace" });
    const text = info.str() orelse "";
    h.assert(std.mem.indexOf(u8, text, "# Keyspace") != null, "INFO keyspace missing header: {s}", .{text});
    h.assert(std.mem.indexOf(u8, text, "db0:keys=3") != null, "INFO keyspace missing db0 line: {s}", .{text});
    const all_info = try h.call(&.{"INFO"});
    const all_text = all_info.str() orelse "";
    for ([_][]const u8{ "# Server", "# Clients", "# Memory", "# Persistence", "# Stats", "redis_version:", "connected_clients:", "aof_enabled:" }) |needle| {
        h.assert(std.mem.indexOf(u8, all_text, needle) != null, "INFO lacks {s}", .{needle});
    }

    try h.expect(&.{ "CONFIG", "GET", "appendonly", "appendfsync" }, .{ .len = 4 });
    const globbed = try h.call(&.{ "CONFIG", "GET", "append*" });
    const globbed_len = if (globbed.items()) |items| items.len else 0;
    h.assert(globbed_len >= 6, "CONFIG GET append* returned {s}", .{h.render(globbed)});
    try h.expect(&.{ "CONFIG", "SET", "hz", "20" }, .ok);
    try h.expect(&.{ "CONFIG", "GET", "hz" }, .{ .strs = &.{ "hz", "20" } });
    try h.expect(&.{ "CONFIG", "SET", "hz", "10" }, .ok);
    try h.expect(&.{ "CONFIG", "SET", "no-such-option", "1" }, .{ .err = "ERR Unknown option or number of arguments for CONFIG SET - 'no-such-option'" });

    try h.expect(&.{ "COMMAND", "INFO", "get", "nosuchcommand" }, .{ .len = 2 });
    try h.expect(&.{ "CLIENT", "SETNAME", "listed" }, .ok);
    const list = try h.call(&.{ "CLIENT", "LIST" });
    h.assert(std.mem.indexOf(u8, list.str() orelse "", "name=listed") != null, "CLIENT LIST lacks our name: {s}", .{list.str() orelse ""});

    var victim = try h.connect();
    defer victim.close();
    const id = try victim.call(&.{ "CLIENT", "ID" });
    var id_buf: [24]u8 = undefined;
    const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{id.int}) catch unreachable;
    try h.expect(&.{ "CLIENT", "KILL", "ID", id_str }, .{ .int = 1 });
    const killed = if (victim.call(&.{"PING"})) |_| false else |err| err == error.ConnectionClosed;
    h.assert(killed, "CLIENT KILL did not close the connection", .{});
    try h.expect(&.{ "CLIENT", "KILL", "ID", "999999" }, .{ .int = 0 });
}
