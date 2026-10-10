//! Compatibility cases: lists, hashes, sets and sorted sets.

const std = @import("std");
const zedis = @import("zedis");
const Harness = @import("harness.zig").Harness;

pub fn lists(h: *Harness) !void {
    try h.expect(&.{ "RPUSH", "l", "a", "b", "c" }, .{ .int = 3 });
    try h.expect(&.{ "LPUSH", "l", "z" }, .{ .int = 4 });
    try h.expect(&.{ "LRANGE", "l", "0", "-1" }, .{ .strs = &.{ "z", "a", "b", "c" } });
    try h.expect(&.{ "LRANGE", "l", "-2", "100" }, .{ .strs = &.{ "b", "c" } });
    try h.expect(&.{ "LRANGE", "l", "5", "10" }, .{ .strs = &.{} });
    try h.expect(&.{ "LRANGE", "nope", "0", "-1" }, .{ .strs = &.{} });
    try h.expect(&.{ "LLEN", "l" }, .{ .int = 4 });
    try h.expect(&.{ "LINDEX", "l", "0" }, .{ .bulk = "z" });
    try h.expect(&.{ "LINDEX", "l", "-1" }, .{ .bulk = "c" });
    try h.expect(&.{ "LINDEX", "l", "99" }, .nil);
    try h.expect(&.{ "LSET", "l", "1", "A" }, .ok);
    try h.expect(&.{ "LSET", "l", "99", "x" }, .{ .err = "ERR index out of range" });
    try h.expect(&.{ "LSET", "nope", "0", "x" }, .{ .err = "ERR no such key" });
    try h.expect(&.{ "LPOP", "l" }, .{ .bulk = "z" });
    try h.expect(&.{ "RPOP", "l" }, .{ .bulk = "c" });
    try h.expect(&.{ "RPUSH", "l", "d", "e", "f" }, .{ .int = 5 });
    try h.expect(&.{ "LPOP", "l", "2" }, .{ .strs = &.{ "A", "b" } });
    try h.expect(&.{ "RPOP", "l", "10" }, .{ .strs = &.{ "f", "e", "d" } });
    try h.expect(&.{ "EXISTS", "l" }, .{ .int = 0 });
    try h.expect(&.{ "LPOP", "l" }, .nil);
    try h.expect(&.{ "LPOP", "l", "2" }, .nil);
    try h.expect(&.{ "LPOP", "l", "-1" }, .{ .err = "ERR value is out of range, must be positive" });
    try h.expect(&.{ "LPUSHX", "l", "x" }, .{ .int = 0 });
    try h.expect(&.{ "RPUSHX", "l", "x" }, .{ .int = 0 });

    try h.expect(&.{ "RPUSH", "t", "1", "2", "3", "4", "5" }, .{ .int = 5 });
    try h.expect(&.{ "LTRIM", "t", "1", "-2" }, .ok);
    try h.expect(&.{ "LRANGE", "t", "0", "-1" }, .{ .strs = &.{ "2", "3", "4" } });
    try h.expect(&.{ "LTRIM", "t", "5", "10" }, .ok);
    try h.expect(&.{ "EXISTS", "t" }, .{ .int = 0 });

    try h.expect(&.{ "RPUSH", "r", "x", "a", "x", "b", "x", "c", "x" }, .{ .int = 7 });
    try h.expect(&.{ "LREM", "r", "-2", "x" }, .{ .int = 2 });
    try h.expect(&.{ "LRANGE", "r", "0", "-1" }, .{ .strs = &.{ "x", "a", "x", "b", "c" } });
    try h.expect(&.{ "LREM", "r", "0", "x" }, .{ .int = 2 });
    try h.expect(&.{ "LRANGE", "r", "0", "-1" }, .{ .strs = &.{ "a", "b", "c" } });

    try h.expect(&.{ "LINSERT", "r", "BEFORE", "b", "ab" }, .{ .int = 4 });
    try h.expect(&.{ "LINSERT", "r", "AFTER", "c", "cd" }, .{ .int = 5 });
    try h.expect(&.{ "LINSERT", "r", "AFTER", "zz", "q" }, .{ .int = -1 });
    try h.expect(&.{ "LINSERT", "nope", "AFTER", "zz", "q" }, .{ .int = 0 });
    try h.expect(&.{ "LINSERT", "r", "MIDDLE", "b", "q" }, .{ .err = "ERR syntax error" });
    try h.expect(&.{ "LRANGE", "r", "0", "-1" }, .{ .strs = &.{ "a", "ab", "b", "c", "cd" } });

    try h.expect(&.{ "RPUSH", "p", "a", "b", "c", "1", "2", "3", "c", "c" }, .{ .int = 8 });
    try h.expect(&.{ "LPOS", "p", "c" }, .{ .int = 2 });
    try h.expect(&.{ "LPOS", "p", "c", "RANK", "2" }, .{ .int = 6 });
    try h.expect(&.{ "LPOS", "p", "c", "RANK", "-1" }, .{ .int = 7 });
    try h.expect(&.{ "LPOS", "p", "c", "COUNT", "2" }, .{ .len = 2 });
    try h.expect(&.{ "LPOS", "p", "c", "COUNT", "0" }, .{ .len = 3 });
    try h.expect(&.{ "LPOS", "p", "c", "COUNT", "0", "MAXLEN", "3" }, .{ .len = 1 });
    try h.expect(&.{ "LPOS", "p", "zz" }, .nil);
    try h.expect(&.{ "LPOS", "p", "c", "RANK", "0" }, .{ .err = "ERR RANK can't be zero" });

    try h.expect(&.{ "RPUSH", "src", "1", "2", "3" }, .{ .int = 3 });
    try h.expect(&.{ "LMOVE", "src", "dst", "LEFT", "RIGHT" }, .{ .bulk = "1" });
    try h.expect(&.{ "RPOPLPUSH", "src", "dst" }, .{ .bulk = "3" });
    try h.expect(&.{ "LRANGE", "dst", "0", "-1" }, .{ .strs = &.{ "3", "1" } });
    try h.expect(&.{ "LMOVE", "src", "src", "LEFT", "RIGHT" }, .{ .bulk = "2" });
    try h.expect(&.{ "LMOVE", "nope", "dst", "LEFT", "RIGHT" }, .nil);
    try h.expect(&.{ "LMOVE", "src", "dst", "UP", "RIGHT" }, .{ .err = "ERR syntax error" });
    try h.expect(&.{ "SET", "str", "x" }, .ok);
    try h.expect(&.{ "LMOVE", "src", "str", "LEFT", "RIGHT" }, .{ .err = "WRONGTYPE" });
    try h.expect(&.{ "LPUSH", "str", "x" }, .{ .err = "WRONGTYPE" });
    try h.expect(&.{ "LRANGE", "str", "0", "1" }, .{ .err = "WRONGTYPE" });
}

pub fn blocking(h: *Harness) !void {
    // Data already present: BLPOP returns immediately.
    try h.expect(&.{ "RPUSH", "q", "job1" }, .{ .int = 1 });
    try h.expect(&.{ "BLPOP", "empty", "q", "1" }, .{ .strs = &.{ "q", "job1" } });
    // Timeout yields a null reply.
    try h.expect(&.{ "BLPOP", "q", "0.1" }, .nil);
    try h.expect(&.{ "BLPOP", "q", "-1" }, .{ .err = "ERR timeout is negative" });
    try h.expect(&.{ "BLPOP", "q", "abc" }, .{ .err = "ERR timeout is not a float or out of range" });

    // A waiting client is served by a push from another connection, in FIFO order.
    var c1 = try h.connect();
    defer c1.close();
    var c2 = try h.connect();
    defer c2.close();
    try c1.append(&.{ "BRPOP", "q", "q2", "5" });
    try c1.flush();
    zedis.sys.sleepMs(50);
    try c2.append(&.{ "BLPOP", "q2", "5" });
    try c2.flush();
    zedis.sys.sleepMs(50);
    try h.expect(&.{ "RPUSH", "q2", "first", "second" }, .{ .int = 2 });
    try h.expectRead(&c1, &.{"BRPOP (served)"}, .{ .strs = &.{ "q2", "second" } });
    try h.expectRead(&c2, &.{"BLPOP (served)"}, .{ .strs = &.{ "q2", "first" } });
    try h.expect(&.{ "EXISTS", "q2" }, .{ .int = 0 });

    // BLMOVE moves into the destination when data arrives.
    try c1.append(&.{ "BLMOVE", "inbox", "work", "LEFT", "RIGHT", "5" });
    try c1.flush();
    zedis.sys.sleepMs(50);
    try h.expect(&.{ "LPUSH", "inbox", "task" }, .{ .int = 1 });
    try h.expectRead(&c1, &.{"BLMOVE (served)"}, .{ .bulk = "task" });
    try h.expect(&.{ "LRANGE", "work", "0", "-1" }, .{ .strs = &.{"task"} });

    // A blocked client wakes up on its timeout.
    try c1.append(&.{ "BLPOP", "never", "0.2" });
    try c1.flush();
    try h.expectRead(&c1, &.{"BLPOP (timeout)"}, .nil);

    // Inside MULTI, blocking pops do not block.
    try h.expect(&.{"MULTI"}, .ok);
    try h.expect(&.{ "BLPOP", "never", "0" }, .{ .simple = "QUEUED" });
    try h.expect(&.{"EXEC"}, .{ .len = 1 });

    // BZPOPMIN is served by ZADD.
    try c1.append(&.{ "BZPOPMIN", "zq", "5" });
    try c1.flush();
    zedis.sys.sleepMs(50);
    try h.expect(&.{ "ZADD", "zq", "2", "b", "1", "a" }, .{ .int = 2 });
    try h.expectRead(&c1, &.{"BZPOPMIN (served)"}, .{ .strs = &.{ "zq", "a", "1" } });

    // Pipelined commands after a blocking one run once it is served.
    try c1.append(&.{ "BLPOP", "pipe", "5" });
    try c1.append(&.{"PING"});
    try c1.flush();
    zedis.sys.sleepMs(50);
    try h.expect(&.{ "RPUSH", "pipe", "v" }, .{ .int = 1 });
    try h.expectRead(&c1, &.{"BLPOP (pipelined)"}, .{ .strs = &.{ "pipe", "v" } });
    try h.expectRead(&c1, &.{"PING (after unblock)"}, .{ .simple = "PONG" });
}

pub fn hashes(h: *Harness) !void {
    try h.expect(&.{ "HSET", "h", "a", "1", "b", "2" }, .{ .int = 2 });
    try h.expect(&.{ "HSET", "h", "a", "10", "c", "3" }, .{ .int = 1 });
    try h.expect(&.{ "HSET", "h", "a" }, .{ .err = "ERR wrong number of arguments for 'hset' command" });
    try h.expect(&.{ "HGET", "h", "a" }, .{ .bulk = "10" });
    try h.expect(&.{ "HGET", "h", "zz" }, .nil);
    try h.expect(&.{ "HMGET", "h", "a", "zz", "b" }, .{ .len = 3 });
    try h.expect(&.{ "HLEN", "h" }, .{ .int = 3 });
    try h.expect(&.{ "HEXISTS", "h", "c" }, .{ .int = 1 });
    try h.expect(&.{ "HSTRLEN", "h", "a" }, .{ .int = 2 });
    try h.expect(&.{ "HKEYS", "h" }, .{ .unordered = &.{ "a", "b", "c" } });
    try h.expect(&.{ "HVALS", "h" }, .{ .unordered = &.{ "10", "2", "3" } });
    try h.expect(&.{ "HGETALL", "h" }, .{ .len = 6 });
    try h.expect(&.{ "HSETNX", "h", "a", "x" }, .{ .int = 0 });
    try h.expect(&.{ "HSETNX", "h", "d", "4" }, .{ .int = 1 });
    try h.expect(&.{ "HMSET", "h", "e", "5" }, .ok);
    try h.expect(&.{ "HDEL", "h", "a", "zz", "b" }, .{ .int = 2 });
    try h.expect(&.{ "HINCRBY", "h", "c", "5" }, .{ .int = 8 });
    try h.expect(&.{ "HINCRBY", "h", "new", "-3" }, .{ .int = -3 });
    try h.expect(&.{ "HSET", "h", "s", "abc" }, .{ .int = 1 });
    try h.expect(&.{ "HINCRBY", "h", "s", "1" }, .{ .err = "ERR hash value is not an integer" });
    try h.expect(&.{ "HINCRBYFLOAT", "h", "fl", "1.5" }, .{ .bulk = "1.5" });
    try h.expect(&.{ "HINCRBYFLOAT", "h", "fl", "0.25" }, .{ .bulk = "1.75" });
    try h.expect(&.{ "HINCRBYFLOAT", "h", "s", "1" }, .{ .err = "ERR hash value is not a float" });
    try h.expect(&.{ "HRANDFIELD", "h" }, .any);
    try h.expect(&.{ "HRANDFIELD", "h", "3" }, .{ .len = 3 });
    try h.expect(&.{ "HRANDFIELD", "h", "100" }, .{ .len = 6 });
    try h.expect(&.{ "HRANDFIELD", "h", "-10" }, .{ .len = 10 });
    try h.expect(&.{ "HRANDFIELD", "h", "2", "WITHVALUES" }, .{ .len = 4 });
    try h.expect(&.{ "HRANDFIELD", "nope", "2" }, .{ .len = 0 });
    try h.expect(&.{ "HDEL", "h", "c", "d", "e", "new", "s", "fl" }, .{ .int = 6 });
    try h.expect(&.{ "EXISTS", "h" }, .{ .int = 0 });
    try h.expect(&.{ "HGETALL", "h" }, .{ .len = 0 });
    try h.expect(&.{ "SET", "str", "x" }, .ok);
    try h.expect(&.{ "HGET", "str", "a" }, .{ .err = "WRONGTYPE" });

    var i: usize = 0;
    while (i < 500) : (i += 1) {
        var fb: [16]u8 = undefined;
        const f = std.fmt.bufPrint(&fb, "f{d}", .{i}) catch unreachable;
        _ = try h.call(&.{ "HSET", "big", f, "v" });
    }
    var cursor_buf: [32]u8 = undefined;
    var cursor: []const u8 = "0";
    var total: usize = 0;
    while (true) {
        const v = try h.call(&.{ "HSCAN", "big", cursor, "COUNT", "50" });
        const items = v.items().?;
        cursor = std.fmt.bufPrint(&cursor_buf, "{s}", .{items[0].str().?}) catch unreachable;
        total += items[1].items().?.len / 2;
        if (std.mem.eql(u8, cursor, "0")) break;
    }
    h.assert(total == 500, "HSCAN returned {d} fields, expected 500", .{total});
    try h.expect(&.{ "HSCAN", "big", "0", "MATCH", "f49*", "COUNT", "1000" }, .{ .len = 2 });
}

pub fn sets(h: *Harness) !void {
    try h.expect(&.{ "SADD", "s", "a", "b", "c", "a" }, .{ .int = 3 });
    try h.expect(&.{ "SADD", "s", "c", "d" }, .{ .int = 1 });
    try h.expect(&.{ "SCARD", "s" }, .{ .int = 4 });
    try h.expect(&.{ "SISMEMBER", "s", "a" }, .{ .int = 1 });
    try h.expect(&.{ "SISMEMBER", "s", "z" }, .{ .int = 0 });
    try h.expect(&.{ "SMISMEMBER", "s", "a", "z" }, .{ .len = 2 });
    try h.expect(&.{ "SMEMBERS", "s" }, .{ .unordered = &.{ "a", "b", "c", "d" } });
    try h.expect(&.{ "SREM", "s", "d", "z" }, .{ .int = 1 });
    try h.expect(&.{ "SADD", "t", "b", "c", "e" }, .{ .int = 3 });
    try h.expect(&.{ "SINTER", "s", "t" }, .{ .unordered = &.{ "b", "c" } });
    try h.expect(&.{ "SUNION", "s", "t" }, .{ .unordered = &.{ "a", "b", "c", "e" } });
    try h.expect(&.{ "SDIFF", "s", "t" }, .{ .unordered = &.{"a"} });
    try h.expect(&.{ "SDIFF", "s", "nope" }, .{ .unordered = &.{ "a", "b", "c" } });
    try h.expect(&.{ "SINTER", "s", "nope" }, .{ .unordered = &.{} });
    try h.expect(&.{ "SINTERSTORE", "dst", "s", "t" }, .{ .int = 2 });
    try h.expect(&.{ "SMEMBERS", "dst" }, .{ .unordered = &.{ "b", "c" } });
    try h.expect(&.{ "SUNIONSTORE", "dst", "dst", "t" }, .{ .int = 3 });
    try h.expect(&.{ "SDIFFSTORE", "dst", "s", "s" }, .{ .int = 0 });
    try h.expect(&.{ "EXISTS", "dst" }, .{ .int = 0 });
    try h.expect(&.{ "SINTERCARD", "2", "s", "t" }, .{ .int = 2 });
    try h.expect(&.{ "SINTERCARD", "2", "s", "t", "LIMIT", "1" }, .{ .int = 1 });
    try h.expect(&.{ "SINTERCARD", "0", "s" }, .{ .err = "ERR numkeys should be greater than 0" });
    try h.expect(&.{ "SMOVE", "s", "t", "a" }, .{ .int = 1 });
    try h.expect(&.{ "SMOVE", "s", "t", "zz" }, .{ .int = 0 });
    try h.expect(&.{ "SISMEMBER", "t", "a" }, .{ .int = 1 });
    try h.expect(&.{ "SRANDMEMBER", "t" }, .any);
    try h.expect(&.{ "SRANDMEMBER", "t", "2" }, .{ .len = 2 });
    try h.expect(&.{ "SRANDMEMBER", "t", "-6" }, .{ .len = 6 });
    try h.expect(&.{ "SRANDMEMBER", "t", "50" }, .{ .len = 4 });
    try h.expect(&.{ "SPOP", "t" }, .any);
    try h.expect(&.{ "SPOP", "t", "10" }, .{ .len = 3 });
    try h.expect(&.{ "EXISTS", "t" }, .{ .int = 0 });
    try h.expect(&.{ "SPOP", "t" }, .nil);
    try h.expect(&.{ "SET", "str", "x" }, .ok);
    try h.expect(&.{ "SADD", "str", "x" }, .{ .err = "WRONGTYPE" });
    try h.expect(&.{ "SUNION", "s", "str" }, .{ .err = "WRONGTYPE" });
}

pub fn zsets(h: *Harness) !void {
    try h.expect(&.{ "ZADD", "z", "1", "a", "2", "b", "3", "c" }, .{ .int = 3 });
    try h.expect(&.{ "ZADD", "z", "1.5", "a" }, .{ .int = 0 });
    try h.expect(&.{ "ZADD", "z", "CH", "1", "a", "4", "d" }, .{ .int = 2 });
    try h.expect(&.{ "ZADD", "z", "NX", "100", "a" }, .{ .int = 0 });
    try h.expect(&.{ "ZADD", "z", "XX", "100", "nope" }, .{ .int = 0 });
    try h.expect(&.{ "ZADD", "z", "GT", "CH", "0", "a" }, .{ .int = 0 });
    try h.expect(&.{ "ZADD", "z", "LT", "CH", "0.5", "a" }, .{ .int = 1 });
    try h.expect(&.{ "ZADD", "z", "NX", "XX", "1", "a" }, .{ .err = "ERR XX and NX options at the same time are not compatible" });
    try h.expect(&.{ "ZADD", "z", "GT", "LT", "1", "a" }, .{ .err = "ERR GT, LT, and/or NX options at the same time are not compatible" });
    try h.expect(&.{ "ZADD", "z", "1", "a", "2" }, .{ .err = "ERR syntax error" });
    try h.expect(&.{ "ZADD", "z", "x", "a" }, .{ .err = "ERR value is not a valid float" });
    try h.expect(&.{ "ZADD", "z", "INCR", "1", "a", "2", "b" }, .{ .err = "ERR INCR option supports a single increment-element pair" });
    try h.expect(&.{ "ZADD", "z", "INCR", "10", "a" }, .{ .double = "10.5" });
    try h.expect(&.{ "ZADD", "z", "NX", "INCR", "10", "a" }, .nil);
    try h.expect(&.{ "ZSCORE", "z", "a" }, .{ .double = "10.5" });
    try h.expect(&.{ "ZSCORE", "z", "nope" }, .nil);
    try h.expect(&.{ "ZINCRBY", "z", "-0.5", "a" }, .{ .double = "10" });
    try h.expect(&.{ "ZMSCORE", "z", "a", "nope", "b" }, .{ .len = 3 });
    try h.expect(&.{ "ZCARD", "z" }, .{ .int = 4 });

    try h.expect(&.{ "ZRANGE", "z", "0", "-1" }, .{ .strs = &.{ "b", "c", "d", "a" } });
    try h.expect(&.{ "ZRANGE", "z", "0", "1", "WITHSCORES" }, .{ .strs = &.{ "b", "2", "c", "3" } });
    try h.expect(&.{ "ZRANGE", "z", "0", "1", "REV" }, .{ .strs = &.{ "a", "d" } });
    try h.expect(&.{ "ZREVRANGE", "z", "0", "-1" }, .{ .strs = &.{ "a", "d", "c", "b" } });
    try h.expect(&.{ "ZRANGE", "z", "2", "3", "BYSCORE" }, .{ .strs = &.{ "b", "c" } });
    try h.expect(&.{ "ZRANGE", "z", "(2", "+inf", "BYSCORE", "LIMIT", "1", "1" }, .{ .strs = &.{"d"} });
    try h.expect(&.{ "ZRANGE", "z", "+inf", "-inf", "BYSCORE", "REV", "LIMIT", "0", "2" }, .{ .strs = &.{ "a", "d" } });
    try h.expect(&.{ "ZRANGE", "z", "0", "1", "LIMIT", "0", "1" }, .{ .err = "ERR syntax error, LIMIT is only supported in combination with either BYSCORE or BYLEX" });
    try h.expect(&.{ "ZRANGEBYSCORE", "z", "-inf", "3" }, .{ .strs = &.{ "b", "c" } });
    try h.expect(&.{ "ZRANGEBYSCORE", "z", "(2", "(4" }, .{ .strs = &.{"c"} });
    try h.expect(&.{ "ZRANGEBYSCORE", "z", "x", "3" }, .{ .err = "ERR min or max is not a float" });
    try h.expect(&.{ "ZREVRANGEBYSCORE", "z", "+inf", "3", "WITHSCORES" }, .{ .strs = &.{ "a", "10", "d", "4", "c", "3" } });
    try h.expect(&.{ "ZCOUNT", "z", "2", "4" }, .{ .int = 3 });
    try h.expect(&.{ "ZCOUNT", "z", "(2", "(4" }, .{ .int = 1 });
    try h.expect(&.{ "ZRANK", "z", "c" }, .{ .int = 1 });
    try h.expect(&.{ "ZREVRANK", "z", "c" }, .{ .int = 2 });
    try h.expect(&.{ "ZRANK", "z", "nope" }, .nil);
    try h.expect(&.{ "ZRANK", "z", "c", "WITHSCORE" }, .{ .len = 2 });

    try h.expect(&.{ "ZADD", "lex", "0", "a", "0", "b", "0", "c", "0", "d", "0", "e" }, .{ .int = 5 });
    try h.expect(&.{ "ZRANGEBYLEX", "lex", "-", "[c" }, .{ .strs = &.{ "a", "b", "c" } });
    try h.expect(&.{ "ZRANGEBYLEX", "lex", "(a", "(d" }, .{ .strs = &.{ "b", "c" } });
    try h.expect(&.{ "ZRANGEBYLEX", "lex", "-", "+", "LIMIT", "1", "2" }, .{ .strs = &.{ "b", "c" } });
    try h.expect(&.{ "ZREVRANGEBYLEX", "lex", "+", "[c" }, .{ .strs = &.{ "e", "d", "c" } });
    try h.expect(&.{ "ZRANGE", "lex", "[b", "[d", "BYLEX" }, .{ .strs = &.{ "b", "c", "d" } });
    try h.expect(&.{ "ZRANGEBYLEX", "lex", "a", "c" }, .{ .err = "ERR min or max not valid string range item" });
    try h.expect(&.{ "ZLEXCOUNT", "lex", "[b", "+" }, .{ .int = 4 });
    try h.expect(&.{ "ZREMRANGEBYLEX", "lex", "[b", "(d" }, .{ .int = 2 });
    try h.expect(&.{ "ZRANGE", "lex", "0", "-1" }, .{ .strs = &.{ "a", "d", "e" } });

    try h.expect(&.{ "ZADD", "r", "1", "a", "2", "b", "3", "c", "4", "d", "5", "e" }, .{ .int = 5 });
    try h.expect(&.{ "ZREMRANGEBYRANK", "r", "0", "1" }, .{ .int = 2 });
    try h.expect(&.{ "ZREMRANGEBYSCORE", "r", "(3", "5" }, .{ .int = 2 });
    try h.expect(&.{ "ZRANGE", "r", "0", "-1" }, .{ .strs = &.{"c"} });
    try h.expect(&.{ "ZREM", "r", "c", "nope" }, .{ .int = 1 });
    try h.expect(&.{ "EXISTS", "r" }, .{ .int = 0 });

    try h.expect(&.{ "ZADD", "p", "1", "a", "2", "b", "3", "c" }, .{ .int = 3 });
    try h.expect(&.{ "ZPOPMIN", "p" }, .{ .strs = &.{ "a", "1" } });
    try h.expect(&.{ "ZPOPMAX", "p", "5" }, .{ .strs = &.{ "c", "3", "b", "2" } });
    try h.expect(&.{ "ZPOPMIN", "p" }, .{ .strs = &.{} });

    try h.expect(&.{ "ZADD", "z1", "1", "a", "2", "b" }, .{ .int = 2 });
    try h.expect(&.{ "ZADD", "z2", "10", "b", "20", "c" }, .{ .int = 2 });
    try h.expect(&.{ "SADD", "plain", "a", "c" }, .{ .int = 2 });
    try h.expect(&.{ "ZUNIONSTORE", "u", "2", "z1", "z2" }, .{ .int = 3 });
    try h.expect(&.{ "ZRANGE", "u", "0", "-1", "WITHSCORES" }, .{ .strs = &.{ "a", "1", "b", "12", "c", "20" } });
    try h.expect(&.{ "ZUNIONSTORE", "u", "2", "z1", "z2", "WEIGHTS", "2", "0.5", "AGGREGATE", "MAX" }, .{ .int = 3 });
    try h.expect(&.{ "ZRANGE", "u", "0", "-1", "WITHSCORES" }, .{ .strs = &.{ "a", "2", "b", "5", "c", "10" } });
    try h.expect(&.{ "ZINTERSTORE", "i", "2", "z1", "z2" }, .{ .int = 1 });
    try h.expect(&.{ "ZSCORE", "i", "b" }, .{ .double = "12" });
    try h.expect(&.{ "ZINTERSTORE", "i", "2", "z1", "plain", "AGGREGATE", "MIN" }, .{ .int = 1 });
    try h.expect(&.{ "ZRANGE", "i", "0", "-1", "WITHSCORES" }, .{ .strs = &.{ "a", "1" } });
    try h.expect(&.{ "ZDIFFSTORE", "d", "2", "z1", "z2" }, .{ .int = 1 });
    try h.expect(&.{ "ZRANGE", "d", "0", "-1" }, .{ .strs = &.{"a"} });
    try h.expect(&.{ "ZUNION", "2", "z1", "z2", "WITHSCORES" }, .{ .strs = &.{ "a", "1", "b", "12", "c", "20" } });
    try h.expect(&.{ "ZINTER", "2", "z1", "z2" }, .{ .strs = &.{"b"} });
    try h.expect(&.{ "ZDIFF", "2", "z1", "z2" }, .{ .strs = &.{"a"} });
    try h.expect(&.{ "ZINTERCARD", "2", "z1", "z2" }, .{ .int = 1 });
    try h.expect(&.{ "ZUNIONSTORE", "u", "0", "z1" }, .{ .err = "ERR at least 1 input key is needed for 'zunionstore' command" });
    try h.expect(&.{ "ZUNIONSTORE", "u", "3", "z1", "z2" }, .{ .err = "ERR syntax error" });
    try h.expect(&.{ "ZUNIONSTORE", "u", "2", "z1", "z2", "WEIGHTS", "1", "x" }, .{ .err = "ERR weight value is not a float" });
    try h.expect(&.{ "ZRANGESTORE", "rs", "z2", "0", "0" }, .{ .int = 1 });
    try h.expect(&.{ "ZRANGE", "rs", "0", "-1" }, .{ .strs = &.{"b"} });
    try h.expect(&.{ "ZRANGESTORE", "rs", "z2", "100", "200" }, .{ .int = 0 });
    try h.expect(&.{ "EXISTS", "rs" }, .{ .int = 0 });

    try h.expect(&.{ "ZADD", "inf", "-inf", "lo", "+inf", "hi", "0", "mid" }, .{ .int = 3 });
    try h.expect(&.{ "ZRANGE", "inf", "0", "-1", "WITHSCORES" }, .{ .strs = &.{ "lo", "-inf", "mid", "0", "hi", "inf" } });
    try h.expect(&.{ "ZINCRBY", "inf", "-inf", "hi" }, .{ .err = "ERR resulting score is not a number (NaN)" });
    try h.expect(&.{ "ZADD", "flt", "1.1", "x", "0.30000000000000004", "y", "1e20", "z" }, .{ .int = 3 });
    try h.expect(&.{ "ZSCORE", "flt", "x" }, .{ .double = "1.1" });
    try h.expect(&.{ "ZSCORE", "flt", "y" }, .{ .double = "0.30000000000000004" });
    try h.expect(&.{ "ZSCORE", "flt", "z" }, .{ .double = "1e+20" });
    try h.expect(&.{ "ZRANDMEMBER", "flt", "2" }, .{ .len = 2 });
    try h.expect(&.{ "ZRANDMEMBER", "flt", "-5", "WITHSCORES" }, .{ .len = 10 });

    var i: usize = 0;
    while (i < 300) : (i += 1) {
        var mb: [16]u8 = undefined;
        var sb: [16]u8 = undefined;
        const m = std.fmt.bufPrint(&mb, "m{d}", .{i}) catch unreachable;
        const s = std.fmt.bufPrint(&sb, "{d}", .{i}) catch unreachable;
        _ = try h.call(&.{ "ZADD", "bigz", s, m });
    }
    try h.expect(&.{ "ZRANGE", "bigz", "100", "102" }, .{ .strs = &.{ "m100", "m101", "m102" } });
    try h.expect(&.{ "ZRANK", "bigz", "m250" }, .{ .int = 250 });
    try h.expect(&.{ "ZCOUNT", "bigz", "10", "19" }, .{ .int = 10 });
    var cursor_buf: [32]u8 = undefined;
    var cursor: []const u8 = "0";
    var total: usize = 0;
    while (true) {
        const v = try h.call(&.{ "ZSCAN", "bigz", cursor, "COUNT", "40" });
        const items = v.items().?;
        cursor = std.fmt.bufPrint(&cursor_buf, "{s}", .{items[0].str().?}) catch unreachable;
        total += items[1].items().?.len / 2;
        if (std.mem.eql(u8, cursor, "0")) break;
    }
    h.assert(total == 300, "ZSCAN returned {d} members, expected 300", .{total});
}
