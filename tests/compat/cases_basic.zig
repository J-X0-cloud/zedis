//! Compatibility cases: connection, strings, keyspace and expiry.

const std = @import("std");
const zedis = @import("zedis");
const Harness = @import("harness.zig").Harness;

pub fn connection(h: *Harness) !void {
    try h.expect(&.{"PING"}, .{ .simple = "PONG" });
    try h.expect(&.{ "PING", "hello" }, .{ .bulk = "hello" });
    try h.expect(&.{ "PING", "a", "b" }, .{ .err = "ERR wrong number of arguments for 'ping' command" });
    try h.expect(&.{ "ECHO", "x y" }, .{ .bulk = "x y" });
    try h.expect(&.{ "NOSUCHCMD", "a", "b" }, .{ .err = "ERR unknown command 'NOSUCHCMD', with args beginning with: 'a' 'b' " });
    try h.expect(&.{"GET"}, .{ .err = "ERR wrong number of arguments for 'get' command" });
    try h.expect(&.{ "SELECT", "1" }, .ok);
    try h.expect(&.{ "SET", "k", "db1" }, .ok);
    try h.expect(&.{ "SELECT", "0" }, .ok);
    try h.expect(&.{ "GET", "k" }, .nil);
    try h.expect(&.{ "SELECT", "99" }, .{ .err = "ERR DB index is out of range" });
    try h.expect(&.{ "SELECT", "x" }, .{ .err = "ERR value is not an integer or out of range" });
    try h.expect(&.{ "CLIENT", "SETNAME", "tester" }, .ok);
    try h.expect(&.{ "CLIENT", "GETNAME" }, .{ .bulk = "tester" });
    try h.expect(&.{ "CLIENT", "SETNAME", "bad name" }, .{ .err = "ERR Client names cannot contain spaces" });
    try h.expect(&.{ "CLIENT", "ID" }, .any);
    try h.expect(&.{"DBSIZE"}, .{ .int = 0 });
    try h.expect(&.{"TIME"}, .{ .len = 2 });
    try h.expect(&.{ "COMMAND", "COUNT" }, .any);
    try h.expect(&.{ "CONFIG", "GET", "appendonly" }, .{ .strs = &.{ "appendonly", "no" } });
    try h.expect(&.{ "HELLO", "4" }, .{ .err = "NOPROTO" });
}

pub fn strings(h: *Harness) !void {
    try h.expect(&.{ "SET", "k", "v" }, .ok);
    try h.expect(&.{ "GET", "k" }, .{ .bulk = "v" });
    try h.expect(&.{ "GET", "missing" }, .nil);
    try h.expect(&.{ "SET", "k", "v2", "NX" }, .nil);
    try h.expect(&.{ "SET", "k", "v2", "XX" }, .ok);
    try h.expect(&.{ "SET", "nx", "1", "XX" }, .nil);
    try h.expect(&.{ "SET", "k", "v3", "GET" }, .{ .bulk = "v2" });
    try h.expect(&.{ "SET", "fresh", "x", "GET" }, .nil);
    try h.expect(&.{ "SET", "k", "v", "NX", "XX" }, .{ .err = "ERR syntax error" });
    try h.expect(&.{ "SET", "k", "v", "EX", "0" }, .{ .err = "ERR invalid expire time in 'set' command" });
    try h.expect(&.{ "SET", "k", "v", "EX", "-5" }, .{ .err = "ERR invalid expire time in 'set' command" });
    try h.expect(&.{ "SET", "k", "v", "EX", "abc" }, .{ .err = "ERR value is not an integer or out of range" });
    try h.expect(&.{ "SET", "k", "v", "EX", "10", "PX", "100" }, .{ .err = "ERR syntax error" });
    try h.expect(&.{ "SET", "k", "v", "EX", "100" }, .ok);
    try h.expect(&.{ "TTL", "k" }, .{ .int = 100 });
    try h.expect(&.{ "SET", "k", "w", "KEEPTTL" }, .ok);
    try h.expect(&.{ "TTL", "k" }, .{ .int = 100 });
    try h.expect(&.{ "SET", "k", "w" }, .ok);
    try h.expect(&.{ "TTL", "k" }, .{ .int = -1 });

    try h.expect(&.{ "SETNX", "sn", "1" }, .{ .int = 1 });
    try h.expect(&.{ "SETNX", "sn", "2" }, .{ .int = 0 });
    try h.expect(&.{ "GETSET", "sn", "3" }, .{ .bulk = "1" });
    try h.expect(&.{ "GETDEL", "sn" }, .{ .bulk = "3" });
    try h.expect(&.{ "GETDEL", "sn" }, .nil);
    try h.expect(&.{ "SETEX", "se", "50", "v" }, .ok);
    try h.expect(&.{ "TTL", "se" }, .{ .int = 50 });
    try h.expect(&.{ "SETEX", "se", "0", "v" }, .{ .err = "ERR invalid expire time in 'setex' command" });
    try h.expect(&.{ "PSETEX", "pse", "5000", "v" }, .ok);
    try h.expect(&.{ "GETEX", "pse", "PERSIST" }, .{ .bulk = "v" });
    try h.expect(&.{ "TTL", "pse" }, .{ .int = -1 });
    try h.expect(&.{ "GETEX", "pse", "EX", "30" }, .{ .bulk = "v" });
    try h.expect(&.{ "TTL", "pse" }, .{ .int = 30 });
    try h.expect(&.{ "GETEX", "pse", "EX", "1", "PERSIST" }, .{ .err = "ERR syntax error" });

    try h.expect(&.{ "MSET", "a", "1", "b", "2" }, .ok);
    try h.expect(&.{ "MSET", "a", "1", "b" }, .{ .err = "ERR wrong number of arguments for 'mset' command" });
    try h.expect(&.{ "MGET", "a", "b", "nope" }, .{ .len = 3 });
    try h.expect(&.{ "MSETNX", "a", "9", "c", "3" }, .{ .int = 0 });
    try h.expect(&.{ "MSETNX", "c", "3", "d", "4" }, .{ .int = 1 });

    try h.expect(&.{ "APPEND", "ap", "Hello" }, .{ .int = 5 });
    try h.expect(&.{ "APPEND", "ap", " World" }, .{ .int = 11 });
    try h.expect(&.{ "STRLEN", "ap" }, .{ .int = 11 });
    try h.expect(&.{ "STRLEN", "nope" }, .{ .int = 0 });
    try h.expect(&.{ "GETRANGE", "ap", "0", "4" }, .{ .bulk = "Hello" });
    try h.expect(&.{ "GETRANGE", "ap", "-5", "-1" }, .{ .bulk = "World" });
    try h.expect(&.{ "GETRANGE", "ap", "-1", "-5" }, .{ .bulk = "" });
    try h.expect(&.{ "GETRANGE", "ap", "5", "1000" }, .{ .bulk = " World" });
    try h.expect(&.{ "GETRANGE", "nope", "0", "1" }, .{ .bulk = "" });
    try h.expect(&.{ "SETRANGE", "ap", "6", "Zedis" }, .{ .int = 11 });
    try h.expect(&.{ "GET", "ap" }, .{ .bulk = "Hello Zedis" });
    try h.expect(&.{ "SETRANGE", "pad", "3", "x" }, .{ .int = 4 });
    try h.expect(&.{ "GET", "pad" }, .{ .bulk = "\x00\x00\x00x" });
    try h.expect(&.{ "SETRANGE", "pad", "-1", "x" }, .{ .err = "ERR offset is out of range" });
    try h.expect(&.{ "SETRANGE", "empty", "0", "" }, .{ .int = 0 });
    try h.expect(&.{ "EXISTS", "empty" }, .{ .int = 0 });

    // Binary safety.
    try h.expect(&.{ "SET", "bin", "a\r\nb\x00c" }, .ok);
    try h.expect(&.{ "GET", "bin" }, .{ .bulk = "a\r\nb\x00c" });
}

pub fn counters(h: *Harness) !void {
    try h.expect(&.{ "INCR", "n" }, .{ .int = 1 });
    try h.expect(&.{ "INCRBY", "n", "10" }, .{ .int = 11 });
    try h.expect(&.{ "DECR", "n" }, .{ .int = 10 });
    try h.expect(&.{ "DECRBY", "n", "20" }, .{ .int = -10 });
    try h.expect(&.{ "SET", "n", "9223372036854775807" }, .ok);
    try h.expect(&.{ "INCR", "n" }, .{ .err = "ERR increment or decrement would overflow" });
    try h.expect(&.{ "SET", "n", " 1" }, .ok);
    try h.expect(&.{ "INCR", "n" }, .{ .err = "ERR value is not an integer or out of range" });
    try h.expect(&.{ "SET", "n", "01" }, .ok);
    try h.expect(&.{ "INCR", "n" }, .{ .err = "ERR value is not an integer or out of range" });
    try h.expect(&.{ "INCRBY", "n2", "abc" }, .{ .err = "ERR value is not an integer or out of range" });
    try h.expect(&.{ "LPUSH", "lst", "x" }, .{ .int = 1 });
    try h.expect(&.{ "INCR", "lst" }, .{ .err = "WRONGTYPE" });

    try h.expect(&.{ "SET", "f", "10.50" }, .ok);
    try h.expect(&.{ "INCRBYFLOAT", "f", "0.1" }, .{ .bulk = "10.6" });
    try h.expect(&.{ "INCRBYFLOAT", "f", "-5" }, .{ .bulk = "5.6" });
    try h.expect(&.{ "SET", "f2", "5.0e3" }, .ok);
    try h.expect(&.{ "INCRBYFLOAT", "f2", "2.0e2" }, .{ .bulk = "5200" });
    try h.expect(&.{ "INCRBYFLOAT", "f3", "0.1" }, .{ .bulk = "0.1" });
    try h.expect(&.{ "INCRBYFLOAT", "f3", "0.2" }, .{ .bulk = "0.3" });
    try h.expect(&.{ "INCRBYFLOAT", "f3", "abc" }, .{ .err = "ERR value is not a valid float" });
    try h.expect(&.{ "SET", "big", "1" }, .ok);
    try h.expect(&.{ "INCRBYFLOAT", "big", "inf" }, .{ .err = "ERR increment would produce NaN or Infinity" });
}

pub fn bits(h: *Harness) !void {
    try h.expect(&.{ "SETBIT", "b", "7", "1" }, .{ .int = 0 });
    try h.expect(&.{ "SETBIT", "b", "7", "0" }, .{ .int = 1 });
    try h.expect(&.{ "SETBIT", "b", "100", "1" }, .{ .int = 0 });
    try h.expect(&.{ "GETBIT", "b", "100" }, .{ .int = 1 });
    try h.expect(&.{ "GETBIT", "b", "99999" }, .{ .int = 0 });
    try h.expect(&.{ "STRLEN", "b" }, .{ .int = 13 });
    try h.expect(&.{ "SETBIT", "b", "1", "2" }, .{ .err = "ERR bit is not an integer or out of range" });
    try h.expect(&.{ "SETBIT", "b", "-1", "1" }, .{ .err = "ERR bit offset is not an integer or out of range" });
    try h.expect(&.{ "SET", "bc", "foobar" }, .ok);
    try h.expect(&.{ "BITCOUNT", "bc" }, .{ .int = 26 });
    try h.expect(&.{ "BITCOUNT", "bc", "0", "0" }, .{ .int = 4 });
    try h.expect(&.{ "BITCOUNT", "bc", "1", "1" }, .{ .int = 6 });
    try h.expect(&.{ "BITCOUNT", "bc", "1", "1", "BYTE" }, .{ .int = 6 });
    try h.expect(&.{ "BITCOUNT", "bc", "5", "30", "BIT" }, .{ .int = 17 });
    try h.expect(&.{ "BITCOUNT", "bc", "-2", "-1" }, .{ .int = 7 });
    try h.expect(&.{ "BITCOUNT", "nope" }, .{ .int = 0 });
}

pub fn keyspace(h: *Harness) !void {
    try h.expect(&.{ "MSET", "a", "1", "b", "2", "c", "3" }, .ok);
    try h.expect(&.{ "EXISTS", "a", "b", "a", "zz" }, .{ .int = 3 });
    try h.expect(&.{ "DEL", "a", "zz" }, .{ .int = 1 });
    try h.expect(&.{ "UNLINK", "b" }, .{ .int = 1 });
    try h.expect(&.{ "TYPE", "c" }, .{ .simple = "string" });
    try h.expect(&.{ "TYPE", "nope" }, .{ .simple = "none" });
    try h.expect(&.{ "RPUSH", "l", "x" }, .{ .int = 1 });
    try h.expect(&.{ "TYPE", "l" }, .{ .simple = "list" });
    try h.expect(&.{ "HSET", "hh", "f", "v" }, .{ .int = 1 });
    try h.expect(&.{ "TYPE", "hh" }, .{ .simple = "hash" });
    try h.expect(&.{ "SADD", "ss", "m" }, .{ .int = 1 });
    try h.expect(&.{ "TYPE", "ss" }, .{ .simple = "set" });
    try h.expect(&.{ "ZADD", "zz", "1", "m" }, .{ .int = 1 });
    try h.expect(&.{ "TYPE", "zz" }, .{ .simple = "zset" });

    try h.expect(&.{ "RENAME", "c", "c2" }, .ok);
    try h.expect(&.{ "GET", "c2" }, .{ .bulk = "3" });
    try h.expect(&.{ "RENAME", "nope", "x" }, .{ .err = "ERR no such key" });
    try h.expect(&.{ "RENAMENX", "c2", "l" }, .{ .int = 0 });
    try h.expect(&.{ "RENAMENX", "c2", "c3" }, .{ .int = 1 });
    try h.expect(&.{ "RENAME", "c3", "c3" }, .ok);
    try h.expect(&.{ "EXPIRE", "c3", "100" }, .{ .int = 1 });
    try h.expect(&.{ "RENAME", "c3", "c4" }, .ok);
    try h.expect(&.{ "TTL", "c4" }, .{ .int = 100 });

    try h.expect(&.{ "MOVE", "c4", "1" }, .{ .int = 1 });
    try h.expect(&.{ "EXISTS", "c4" }, .{ .int = 0 });
    try h.expect(&.{ "SELECT", "1" }, .ok);
    try h.expect(&.{ "GET", "c4" }, .{ .bulk = "3" });
    try h.expect(&.{ "TTL", "c4" }, .{ .int = 100 });
    try h.expect(&.{ "SELECT", "0" }, .ok);
    try h.expect(&.{ "MOVE", "l", "0" }, .{ .err = "ERR source and destination objects are the same" });

    try h.expect(&.{ "COPY", "hh", "hh2" }, .{ .int = 1 });
    try h.expect(&.{ "COPY", "hh", "hh2" }, .{ .int = 0 });
    try h.expect(&.{ "HSET", "hh", "f", "changed" }, .{ .int = 0 });
    try h.expect(&.{ "HGET", "hh2", "f" }, .{ .bulk = "v" });
    try h.expect(&.{ "COPY", "hh", "hh2", "REPLACE" }, .{ .int = 1 });
    try h.expect(&.{ "HGET", "hh2", "f" }, .{ .bulk = "changed" });
    try h.expect(&.{ "COPY", "zz", "zz", "DB", "2" }, .{ .int = 1 });
    // REPLACE deletes the destination, which swap-removes the newest key
    // into its slot; the source must be read before that happens.
    try h.expect(&.{ "SELECT", "5" }, .ok);
    try h.expect(&.{ "SET", "cdst", "old" }, .ok);
    try h.expect(&.{ "RPUSH", "csrc", "a", "b" }, .{ .int = 2 });
    try h.expect(&.{ "EXPIRE", "csrc", "100" }, .{ .int = 1 });
    try h.expect(&.{ "COPY", "csrc", "cdst", "REPLACE" }, .{ .int = 1 });
    try h.expect(&.{ "LRANGE", "cdst", "0", "-1" }, .{ .strs = &.{ "a", "b" } });
    try h.expect(&.{ "TTL", "cdst" }, .{ .int = 100 });
    try h.expect(&.{ "LRANGE", "csrc", "0", "-1" }, .{ .strs = &.{ "a", "b" } });
    try h.expect(&.{"FLUSHDB"}, .ok);
    try h.expect(&.{ "SELECT", "0" }, .ok);

    try h.expect(&.{"FLUSHDB"}, .ok);
    try h.expect(&.{ "MSET", "user:1", "a", "user:2", "b", "item:1", "c" }, .ok);
    try h.expect(&.{ "KEYS", "user:*" }, .{ .unordered = &.{ "user:1", "user:2" } });
    try h.expect(&.{ "KEYS", "*:1" }, .{ .unordered = &.{ "user:1", "item:1" } });
    try h.expect(&.{ "KEYS", "u?er:[12]" }, .{ .unordered = &.{ "user:1", "user:2" } });
    try h.expect(&.{"DBSIZE"}, .{ .int = 3 });
    try h.expect(&.{"RANDOMKEY"}, .any);
    try h.expect(&.{ "TOUCH", "user:1", "nope" }, .{ .int = 1 });
    try h.expect(&.{"FLUSHALL"}, .ok);
    try h.expect(&.{"RANDOMKEY"}, .nil);
}

pub fn expiry(h: *Harness) !void {
    try h.expect(&.{ "SET", "k", "v" }, .ok);
    try h.expect(&.{ "TTL", "k" }, .{ .int = -1 });
    try h.expect(&.{ "PTTL", "k" }, .{ .int = -1 });
    try h.expect(&.{ "TTL", "nope" }, .{ .int = -2 });
    try h.expect(&.{ "EXPIRE", "nope", "10" }, .{ .int = 0 });
    try h.expect(&.{ "EXPIRE", "k", "10", "XX" }, .{ .int = 0 });
    try h.expect(&.{ "EXPIRE", "k", "10", "NX" }, .{ .int = 1 });
    try h.expect(&.{ "EXPIRE", "k", "20", "NX" }, .{ .int = 0 });
    try h.expect(&.{ "EXPIRE", "k", "5", "GT" }, .{ .int = 0 });
    try h.expect(&.{ "EXPIRE", "k", "50", "GT" }, .{ .int = 1 });
    try h.expect(&.{ "EXPIRE", "k", "60", "LT" }, .{ .int = 0 });
    try h.expect(&.{ "EXPIRE", "k", "40", "LT" }, .{ .int = 1 });
    try h.expect(&.{ "TTL", "k" }, .{ .int = 40 });
    try h.expect(&.{ "EXPIRE", "k", "40", "NX", "XX" }, .{ .err = "ERR NX and XX, GT or LT options at the same time are not compatible" });
    try h.expect(&.{ "EXPIRE", "k", "40", "GT", "LT" }, .{ .err = "ERR GT and LT options at the same time are not compatible" });
    try h.expect(&.{ "EXPIRE", "k", "40", "BOGUS" }, .{ .err = "ERR Unsupported option BOGUS" });
    try h.expect(&.{ "EXPIRE", "k", "notanumber" }, .{ .err = "ERR value is not an integer or out of range" });
    try h.expect(&.{ "PERSIST", "k" }, .{ .int = 1 });
    try h.expect(&.{ "PERSIST", "k" }, .{ .int = 0 });
    try h.expect(&.{ "SET", "nottl", "v" }, .ok);
    try h.expect(&.{ "EXPIRE", "nottl", "10", "LT" }, .{ .int = 1 });
    try h.expect(&.{ "SET", "nottl2", "v" }, .ok);
    try h.expect(&.{ "EXPIRE", "nottl2", "10", "GT" }, .{ .int = 0 });

    try h.expect(&.{ "SET", "abs", "v" }, .ok);
    try h.expect(&.{ "EXPIREAT", "abs", "4102444800" }, .{ .int = 1 });
    try h.expect(&.{ "EXPIRETIME", "abs" }, .{ .int = 4102444800 });
    try h.expect(&.{ "PEXPIRETIME", "abs" }, .{ .int = 4102444800000 });
    try h.expect(&.{ "EXPIRETIME", "k" }, .{ .int = -1 });
    try h.expect(&.{ "EXPIRETIME", "nope" }, .{ .int = -2 });

    // A TTL in the past deletes the key immediately.
    try h.expect(&.{ "SET", "past", "v" }, .ok);
    try h.expect(&.{ "EXPIREAT", "past", "1" }, .{ .int = 1 });
    try h.expect(&.{ "EXISTS", "past" }, .{ .int = 0 });
    try h.expect(&.{ "SET", "neg", "v" }, .ok);
    try h.expect(&.{ "EXPIRE", "neg", "-1" }, .{ .int = 1 });
    try h.expect(&.{ "GET", "neg" }, .nil);

    // Lazy expiry: the key disappears once its PX elapses.
    try h.expect(&.{ "SET", "short", "v", "PX", "100" }, .ok);
    try h.expect(&.{ "GET", "short" }, .{ .bulk = "v" });
    zedis.sys.sleepMs(250);
    try h.expect(&.{ "GET", "short" }, .nil);
    try h.expect(&.{ "TTL", "short" }, .{ .int = -2 });

    // Active expiry: keys that are never touched are evicted by the cron.
    try h.expect(&.{"FLUSHALL"}, .ok);
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        var buf: [32]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "vol:{d}", .{i}) catch unreachable;
        try h.expect(&.{ "SET", key, "v", "PX", "50" }, .ok);
    }
    try h.expect(&.{ "SET", "keeper", "v" }, .ok);
    var waited: usize = 0;
    while (waited < 3000) : (waited += 100) {
        zedis.sys.sleepMs(100);
        const v = try h.call(&.{"DBSIZE"});
        if (v == .int and v.int == 1) break;
    }
    try h.expect(&.{"DBSIZE"}, .{ .int = 1 });
}

pub fn scan(h: *Harness) !void {
    var i: usize = 0;
    while (i < 300) : (i += 1) {
        var buf: [32]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "{s}:{d}", .{ if (i % 3 == 0) "even" else "odd", i }) catch unreachable;
        try h.expect(&.{ "SET", key, "v" }, .ok);
    }
    try h.expect(&.{ "RPUSH", "even:list", "x" }, .{ .int = 1 });
    var seen = std.StringHashMap(void).init(h.gpa);
    defer {
        var it = seen.keyIterator();
        while (it.next()) |k| h.gpa.free(k.*);
        seen.deinit();
    }
    var cursor_buf: [32]u8 = undefined;
    var cursor: []const u8 = "0";
    var rounds: usize = 0;
    while (true) : (rounds += 1) {
        const v = try h.call(&.{ "SCAN", cursor, "MATCH", "even:*", "COUNT", "25", "TYPE", "string" });
        const items = v.items() orelse {
            h.fail(&.{"SCAN"}, "unexpected reply {s}", .{h.render(v)});
            return;
        };
        cursor = std.fmt.bufPrint(&cursor_buf, "{s}", .{items[0].str().?}) catch unreachable;
        for (items[1].items().?) |k| {
            const s = k.str().?;
            if (!seen.contains(s)) try seen.put(try h.gpa.dupe(u8, s), {});
        }
        if (std.mem.eql(u8, cursor, "0") or rounds > 1000) break;
    }
    h.assert(seen.count() == 100, "SCAN MATCH TYPE returned {d} distinct keys, expected 100", .{seen.count()});
    h.assert(!seen.contains("even:list"), "SCAN TYPE string returned a list key", .{});
    try h.expect(&.{ "SCAN", "abc" }, .{ .err = "ERR invalid cursor" });
    try h.expect(&.{ "SCAN", "0", "COUNT", "0" }, .{ .err = "ERR syntax error" });
    // Redis 7.2 treats an unknown TYPE as a filter that matches nothing.
    const unknown = try h.call(&.{ "SCAN", "0", "TYPE", "nosuchtype", "COUNT", "1000" });
    const no_keys = if (unknown.items()) |items| items.len == 2 and items[1].items().?.len == 0 else false;
    h.assert(no_keys, "SCAN TYPE nosuchtype should match nothing, got {s}", .{h.render(unknown)});
}
