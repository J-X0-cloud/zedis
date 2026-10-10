//! The command table. Arity follows Redis' convention: a positive number is
//! the exact argument count including the command name, a negative number
//! is the minimum.

const std = @import("std");
const ctx_mod = @import("ctx.zig");
const strings = @import("strings.zig");
const keys = @import("keys.zig");
const lists = @import("lists.zig");
const hashes = @import("hashes.zig");
const sets = @import("sets.zig");
const zsets = @import("zsets.zig");
const pubsub = @import("pubsub.zig");
const tx = @import("tx.zig");
const server_cmds = @import("server_cmds.zig");

pub const Command = ctx_mod.Command;
const Flags = ctx_mod.Flags;

const W: Flags = .{ .write = true };
const WF: Flags = .{ .write = true, .fast = true };
const R: Flags = .{ .readonly = true };
const RF: Flags = .{ .readonly = true, .fast = true };
const WB: Flags = .{ .write = true, .blocking = true };
const A: Flags = .{ .admin = true };
const PS: Flags = .{ .pubsub = true, .pubsub_ok = true };
const MC: Flags = .{ .multi_control = true, .fast = true };

fn cmd(name: []const u8, handler: *const fn (*ctx_mod.Ctx) ctx_mod.Error!void, arity: i32, flags: Flags, first: i32, last: i32, step: i32) Command {
    return .{ .name = name, .handler = handler, .arity = arity, .flags = flags, .first_key = first, .last_key = last, .key_step = step };
}

pub const all = [_]Command{
    // strings
    cmd("get", strings.get, 2, RF, 1, 1, 1),
    cmd("set", strings.set, -3, W, 1, 1, 1),
    cmd("setnx", strings.setnx, 3, WF, 1, 1, 1),
    cmd("setex", strings.setex, 4, W, 1, 1, 1),
    cmd("psetex", strings.psetex, 4, W, 1, 1, 1),
    cmd("getset", strings.getset, 3, WF, 1, 1, 1),
    cmd("getdel", strings.getdel, 2, WF, 1, 1, 1),
    cmd("getex", strings.getex, -2, WF, 1, 1, 1),
    cmd("mget", strings.mget, -2, RF, 1, -1, 1),
    cmd("mset", strings.mset, -3, W, 1, -1, 2),
    cmd("msetnx", strings.msetnx, -3, W, 1, -1, 2),
    cmd("append", strings.append, 3, WF, 1, 1, 1),
    cmd("strlen", strings.strlen, 2, RF, 1, 1, 1),
    cmd("incr", strings.incr, 2, WF, 1, 1, 1),
    cmd("decr", strings.decr, 2, WF, 1, 1, 1),
    cmd("incrby", strings.incrby, 3, WF, 1, 1, 1),
    cmd("decrby", strings.decrby, 3, WF, 1, 1, 1),
    cmd("incrbyfloat", strings.incrbyfloat, 3, WF, 1, 1, 1),
    cmd("getrange", strings.getrange, 4, R, 1, 1, 1),
    cmd("substr", strings.getrange, 4, R, 1, 1, 1),
    cmd("setrange", strings.setrange, 4, W, 1, 1, 1),
    cmd("setbit", strings.setbit, 4, W, 1, 1, 1),
    cmd("getbit", strings.getbit, 3, RF, 1, 1, 1),
    cmd("bitcount", strings.bitcount, -2, R, 1, 1, 1),

    // keyspace
    cmd("del", keys.del, -2, W, 1, -1, 1),
    cmd("unlink", keys.del, -2, WF, 1, -1, 1),
    cmd("exists", keys.exists, -2, RF, 1, -1, 1),
    cmd("touch", keys.touch, -2, RF, 1, -1, 1),
    cmd("type", keys.@"type", 2, RF, 1, 1, 1),
    cmd("expire", keys.expire, -3, WF, 1, 1, 1),
    cmd("pexpire", keys.pexpire, -3, WF, 1, 1, 1),
    cmd("expireat", keys.expireat, -3, WF, 1, 1, 1),
    cmd("pexpireat", keys.pexpireat, -3, WF, 1, 1, 1),
    cmd("ttl", keys.ttl, 2, RF, 1, 1, 1),
    cmd("pttl", keys.pttl, 2, RF, 1, 1, 1),
    cmd("expiretime", keys.expiretime, 2, RF, 1, 1, 1),
    cmd("pexpiretime", keys.pexpiretime, 2, RF, 1, 1, 1),
    cmd("persist", keys.persist, 2, WF, 1, 1, 1),
    cmd("keys", keys.keys, 2, R, 0, 0, 0),
    cmd("scan", keys.scan, -2, R, 0, 0, 0),
    cmd("randomkey", keys.randomkey, 1, R, 0, 0, 0),
    cmd("rename", keys.rename, 3, W, 1, 2, 1),
    cmd("renamenx", keys.renamenx, 3, WF, 1, 2, 1),
    cmd("move", keys.move, 3, WF, 1, 1, 1),
    cmd("copy", keys.copy, -3, W, 1, 2, 1),
    cmd("object", keys.object, -2, R, 2, 2, 1),

    // lists
    cmd("lpush", lists.lpush, -3, WF, 1, 1, 1),
    cmd("rpush", lists.rpush, -3, WF, 1, 1, 1),
    cmd("lpushx", lists.lpushx, -3, WF, 1, 1, 1),
    cmd("rpushx", lists.rpushx, -3, WF, 1, 1, 1),
    cmd("lpop", lists.lpop, -2, WF, 1, 1, 1),
    cmd("rpop", lists.rpop, -2, WF, 1, 1, 1),
    cmd("llen", lists.llen, 2, RF, 1, 1, 1),
    cmd("lindex", lists.lindex, 3, R, 1, 1, 1),
    cmd("lset", lists.lset, 4, W, 1, 1, 1),
    cmd("lrange", lists.lrange, 4, R, 1, 1, 1),
    cmd("ltrim", lists.ltrim, 4, W, 1, 1, 1),
    cmd("lrem", lists.lrem, 4, W, 1, 1, 1),
    cmd("linsert", lists.linsert, 5, W, 1, 1, 1),
    cmd("lpos", lists.lpos, -3, R, 1, 1, 1),
    cmd("lmove", lists.lmove, 5, W, 1, 2, 1),
    cmd("rpoplpush", lists.rpoplpush, 3, W, 1, 2, 1),
    cmd("blpop", lists.blpop, -3, WB, 1, -2, 1),
    cmd("brpop", lists.brpop, -3, WB, 1, -2, 1),
    cmd("blmove", lists.blmove, 6, WB, 1, 2, 1),
    cmd("brpoplpush", lists.brpoplpush, 4, WB, 1, 2, 1),

    // hashes
    cmd("hset", hashes.hset, -4, WF, 1, 1, 1),
    cmd("hmset", hashes.hmset, -4, WF, 1, 1, 1),
    cmd("hsetnx", hashes.hsetnx, 4, WF, 1, 1, 1),
    cmd("hget", hashes.hget, 3, RF, 1, 1, 1),
    cmd("hmget", hashes.hmget, -3, RF, 1, 1, 1),
    cmd("hdel", hashes.hdel, -3, WF, 1, 1, 1),
    cmd("hlen", hashes.hlen, 2, RF, 1, 1, 1),
    cmd("hstrlen", hashes.hstrlen, 3, RF, 1, 1, 1),
    cmd("hexists", hashes.hexists, 3, RF, 1, 1, 1),
    cmd("hgetall", hashes.hgetall, 2, R, 1, 1, 1),
    cmd("hkeys", hashes.hkeys, 2, R, 1, 1, 1),
    cmd("hvals", hashes.hvals, 2, R, 1, 1, 1),
    cmd("hincrby", hashes.hincrby, 4, WF, 1, 1, 1),
    cmd("hincrbyfloat", hashes.hincrbyfloat, 4, WF, 1, 1, 1),
    cmd("hrandfield", hashes.hrandfield, -2, R, 1, 1, 1),
    cmd("hscan", hashes.hscan, -3, R, 1, 1, 1),

    // sets
    cmd("sadd", sets.sadd, -3, WF, 1, 1, 1),
    cmd("srem", sets.srem, -3, WF, 1, 1, 1),
    cmd("sismember", sets.sismember, 3, RF, 1, 1, 1),
    cmd("smismember", sets.smismember, -3, RF, 1, 1, 1),
    cmd("scard", sets.scard, 2, RF, 1, 1, 1),
    cmd("smembers", sets.smembers, 2, R, 1, 1, 1),
    cmd("spop", sets.spop, -2, WF, 1, 1, 1),
    cmd("srandmember", sets.srandmember, -2, R, 1, 1, 1),
    cmd("smove", sets.smove, 4, WF, 1, 2, 1),
    cmd("sinter", sets.sinter, -2, R, 1, -1, 1),
    cmd("sunion", sets.sunion, -2, R, 1, -1, 1),
    cmd("sdiff", sets.sdiff, -2, R, 1, -1, 1),
    cmd("sinterstore", sets.sinterstore, -3, W, 1, -1, 1),
    cmd("sunionstore", sets.sunionstore, -3, W, 1, -1, 1),
    cmd("sdiffstore", sets.sdiffstore, -3, W, 1, -1, 1),
    cmd("sintercard", sets.sintercard, -3, R, 0, 0, 0),
    cmd("sscan", sets.sscan, -3, R, 1, 1, 1),

    // sorted sets
    cmd("zadd", zsets.zadd, -4, WF, 1, 1, 1),
    cmd("zincrby", zsets.zincrby, 4, WF, 1, 1, 1),
    cmd("zrem", zsets.zrem, -3, WF, 1, 1, 1),
    cmd("zscore", zsets.zscore, 3, RF, 1, 1, 1),
    cmd("zmscore", zsets.zmscore, -3, RF, 1, 1, 1),
    cmd("zcard", zsets.zcard, 2, RF, 1, 1, 1),
    cmd("zcount", zsets.zcount, 4, RF, 1, 1, 1),
    cmd("zlexcount", zsets.zlexcount, 4, RF, 1, 1, 1),
    cmd("zrank", zsets.zrank, -3, RF, 1, 1, 1),
    cmd("zrevrank", zsets.zrevrank, -3, RF, 1, 1, 1),
    cmd("zrange", zsets.zrange, -4, R, 1, 1, 1),
    cmd("zrevrange", zsets.zrevrange, -4, R, 1, 1, 1),
    cmd("zrangebyscore", zsets.zrangebyscore, -4, R, 1, 1, 1),
    cmd("zrevrangebyscore", zsets.zrevrangebyscore, -4, R, 1, 1, 1),
    cmd("zrangebylex", zsets.zrangebylex, -4, R, 1, 1, 1),
    cmd("zrevrangebylex", zsets.zrevrangebylex, -4, R, 1, 1, 1),
    cmd("zrangestore", zsets.zrangestore, -5, W, 1, 2, 1),
    cmd("zremrangebyrank", zsets.zremrangebyrank, 4, W, 1, 1, 1),
    cmd("zremrangebyscore", zsets.zremrangebyscore, 4, W, 1, 1, 1),
    cmd("zremrangebylex", zsets.zremrangebylex, 4, W, 1, 1, 1),
    cmd("zpopmin", zsets.zpopmin, -2, WF, 1, 1, 1),
    cmd("zpopmax", zsets.zpopmax, -2, WF, 1, 1, 1),
    cmd("bzpopmin", zsets.bzpopmin, -3, WB, 1, -2, 1),
    cmd("bzpopmax", zsets.bzpopmax, -3, WB, 1, -2, 1),
    cmd("zunion", zsets.zunion, -3, R, 0, 0, 0),
    cmd("zinter", zsets.zinter, -3, R, 0, 0, 0),
    cmd("zdiff", zsets.zdiff, -3, R, 0, 0, 0),
    cmd("zunionstore", zsets.zunionstore, -4, W, 1, 1, 1),
    cmd("zinterstore", zsets.zinterstore, -4, W, 1, 1, 1),
    cmd("zdiffstore", zsets.zdiffstore, -4, W, 1, 1, 1),
    cmd("zintercard", zsets.zintercard, -3, R, 0, 0, 0),
    cmd("zrandmember", zsets.zrandmember, -2, R, 1, 1, 1),
    cmd("zscan", zsets.zscan, -3, R, 1, 1, 1),

    // pub/sub
    cmd("subscribe", pubsub.subscribe, -2, PS, 0, 0, 0),
    cmd("unsubscribe", pubsub.unsubscribe, -1, PS, 0, 0, 0),
    cmd("psubscribe", pubsub.psubscribe, -2, PS, 0, 0, 0),
    cmd("punsubscribe", pubsub.punsubscribe, -1, PS, 0, 0, 0),
    cmd("publish", pubsub.publish, 3, .{ .pubsub = true, .fast = true }, 0, 0, 0),
    cmd("pubsub", pubsub.pubsub, -2, .{ .pubsub = true }, 0, 0, 0),

    // transactions
    cmd("multi", tx.multi, 1, MC, 0, 0, 0),
    cmd("exec", tx.exec, 1, .{ .multi_control = true }, 0, 0, 0),
    cmd("discard", tx.discard, 1, MC, 0, 0, 0),
    cmd("watch", tx.watch, -2, MC, 1, -1, 1),
    cmd("unwatch", tx.unwatch, 1, RF, 0, 0, 0),

    // connection and server
    cmd("ping", server_cmds.ping, -1, .{ .fast = true, .pubsub_ok = true }, 0, 0, 0),
    cmd("echo", server_cmds.echo, 2, RF, 0, 0, 0),
    cmd("quit", server_cmds.quit, -1, .{ .no_auth = true, .pubsub_ok = true, .multi_control = true }, 0, 0, 0),
    cmd("reset", server_cmds.reset, 1, .{ .no_auth = true, .pubsub_ok = true, .multi_control = true }, 0, 0, 0),
    cmd("auth", server_cmds.auth, -2, .{ .no_auth = true, .fast = true }, 0, 0, 0),
    cmd("hello", server_cmds.hello, -1, .{ .no_auth = true, .fast = true }, 0, 0, 0),
    cmd("select", server_cmds.select, 2, .{ .fast = true }, 0, 0, 0),
    cmd("swapdb", server_cmds.swapdb, 3, WF, 0, 0, 0),
    cmd("dbsize", server_cmds.dbsize, 1, RF, 0, 0, 0),
    cmd("flushdb", server_cmds.flushdb, -1, W, 0, 0, 0),
    cmd("flushall", server_cmds.flushall, -1, W, 0, 0, 0),
    cmd("time", server_cmds.time, 1, .{ .fast = true }, 0, 0, 0),
    cmd("lastsave", server_cmds.lastsave, 1, .{ .fast = true }, 0, 0, 0),
    cmd("info", server_cmds.info, -1, .{}, 0, 0, 0),
    cmd("client", server_cmds.client, -2, .{}, 0, 0, 0),
    cmd("config", server_cmds.config, -2, A, 0, 0, 0),
    cmd("command", server_cmds.command, -1, .{}, 0, 0, 0),
    cmd("bgrewriteaof", server_cmds.bgrewriteaof, 1, A, 0, 0, 0),
    cmd("shutdown", server_cmds.shutdown, -1, A, 0, 0, 0),
    cmd("debug", server_cmds.debug, -2, A, 0, 0, 0),
};

const index = blk: {
    @setEvalBranchQuota(100_000);
    var entries: [all.len]struct { []const u8, usize } = undefined;
    for (all, 0..) |c, i| entries[i] = .{ c.name, i };
    break :blk std.StaticStringMap(usize).initComptime(entries);
};

/// Finds a command by name, case-insensitively.
pub fn lookup(name: []const u8) ?*const Command {
    var buf: [32]u8 = undefined;
    if (name.len > buf.len) return null;
    const lower = std.ascii.lowerString(&buf, name);
    const i = index.get(lower) orelse return null;
    return &all[i];
}

test "every command name is unique and lowercase" {
    for (all, 0..) |a, i| {
        for (a.name) |ch| try std.testing.expect(!std.ascii.isUpper(ch));
        for (all[i + 1 ..]) |b| try std.testing.expect(!std.mem.eql(u8, a.name, b.name));
    }
}

test "lookup is case-insensitive" {
    try std.testing.expectEqualStrings("get", lookup("GET").?.name);
    try std.testing.expectEqualStrings("zrangebyscore", lookup("ZRangeByScore").?.name);
    try std.testing.expect(lookup("nope") == null);
    try std.testing.expect(lookup("this-command-name-is-far-too-long-to-exist") == null);
}

test "arity checks" {
    const get = lookup("get").?;
    try std.testing.expect(get.arityOk(2));
    try std.testing.expect(!get.arityOk(3));
    const set = lookup("set").?;
    try std.testing.expect(set.arityOk(3));
    try std.testing.expect(set.arityOk(9));
    try std.testing.expect(!set.arityOk(2));
}
