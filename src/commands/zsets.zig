//! Sorted set commands.

const std = @import("std");
const num = @import("../num.zig");
const glob = @import("../glob.zig");
const zset_mod = @import("../ds/zset.zig");
const ctx_mod = @import("ctx.zig");
const keys_cmds = @import("keys.zig");
const hashes = @import("hashes.zig");
const Ctx = ctx_mod.Ctx;
const Error = ctx_mod.Error;
const Value = ctx_mod.Value;
const msg = ctx_mod.msg;
const ZSet = zset_mod.ZSet;
const Node = zset_mod.Node;
const ScoreRange = zset_mod.ScoreRange;
const LexRange = zset_mod.LexRange;
const LexBound = zset_mod.LexBound;

fn zsetFor(ctx: *Ctx, key: []const u8, for_write: bool) union(enum) { missing, wrong_type, found: *ZSet } {
    return switch (ctx.lookup(key, .zset, for_write)) {
        .missing => .missing,
        .wrong_type => .wrong_type,
        .found => |v| .{ .found = v.zset },
    };
}

fn dropIfEmpty(ctx: *Ctx, key: []const u8, z: *ZSet) void {
    if (z.len() == 0) _ = ctx.db().delete(key);
}

/// Writes a member/score pair as part of a WITHSCORES reply: flattened in
/// RESP2, a nested two-element array in RESP3.
fn writePair(ctx: *Ctx, member: []const u8, score: f64) Error!void {
    if (ctx.client.proto >= 3) try ctx.w.array(2);
    try ctx.w.bulk(member);
    try ctx.w.double(score);
}

fn pairsHeader(ctx: *Ctx, n: usize, with_scores: bool) Error!void {
    if (with_scores and ctx.client.proto < 3) try ctx.w.array(n * 2) else try ctx.w.array(n);
}

// ------------------------------------------------------------------ ZADD --

fn zaddGeneric(ctx: *Ctx, incr_only: bool) Error!void {
    const key = ctx.args[1];
    var flags: ZSet.AddFlags = .{ .incr = incr_only };
    var ch = false;
    var i: usize = 2;
    if (!incr_only) {
        while (i < ctx.args.len) : (i += 1) {
            const a = ctx.args[i];
            if (Ctx.is(a, "nx")) flags.nx = true else if (Ctx.is(a, "xx")) flags.xx = true else if (Ctx.is(a, "gt")) flags.gt = true else if (Ctx.is(a, "lt")) flags.lt = true else if (Ctx.is(a, "ch")) ch = true else if (Ctx.is(a, "incr")) flags.incr = true else break;
        }
    }
    const rest = ctx.args[i..];
    if (rest.len == 0 or rest.len % 2 != 0) return ctx.syntaxError();
    if (flags.nx and flags.xx) return ctx.w.err("ERR XX and NX options at the same time are not compatible");
    if ((flags.gt and flags.nx) or (flags.lt and flags.nx) or (flags.gt and flags.lt)) {
        return ctx.w.err("ERR GT, LT, and/or NX options at the same time are not compatible");
    }
    if (flags.incr and rest.len > 2) return ctx.w.err("ERR INCR option supports a single increment-element pair");

    // Validate every score before mutating anything.
    const scores = try ctx.gpa.alloc(f64, rest.len / 2);
    defer ctx.gpa.free(scores);
    for (scores, 0..) |*s, j| {
        s.* = num.parseF64(rest[j * 2]) orelse return ctx.w.err(msg.not_float);
    }

    const d = ctx.db();
    const z = switch (zsetFor(ctx, key, true)) {
        .wrong_type => return ctx.wrongType(),
        .found => |z| z,
        .missing => blk: {
            if (flags.xx) {
                // Nothing can be updated in a missing key.
                if (flags.incr) return ctx.w.nullBulk();
                return ctx.w.int(0);
            }
            const v = try d.add(key, try Value.initZSet(ctx.gpa, d.nextSeed()));
            break :blk v.zset;
        },
    };
    var added: i64 = 0;
    var changed: i64 = 0;
    var last_score: f64 = 0;
    var skipped = false;
    for (scores, 0..) |s, j| {
        const member = rest[j * 2 + 1];
        switch (try z.add(ctx.gpa, member, s, flags, &last_score)) {
            .added => added += 1,
            .updated => changed += 1,
            .unchanged => {},
            .skipped => skipped = true,
            .nan => {
                dropIfEmpty(ctx, key, z);
                return ctx.w.err(msg.nan);
            },
        }
    }
    if (added + changed > 0) {
        ctx.modified(key);
        try ctx.signalReady(key);
    }
    if (flags.incr) {
        if (skipped) {
            dropIfEmpty(ctx, key, z);
            return ctx.w.nullBulk();
        }
        // Propagate the resulting score, not the increment.
        if (added + changed > 0) {
            var sbuf: [num.max_double_chars]u8 = undefined;
            try ctx.propagate(&.{ "ZADD", key, num.formatDouble(&sbuf, last_score), rest[1] });
        }
        return ctx.w.double(last_score);
    }
    dropIfEmpty(ctx, key, z);
    try ctx.w.int(if (ch) added + changed else added);
}

pub fn zadd(ctx: *Ctx) Error!void {
    try zaddGeneric(ctx, false);
}

pub fn zincrby(ctx: *Ctx) Error!void {
    try zaddGeneric(ctx, true);
}

pub fn zrem(ctx: *Ctx) Error!void {
    const key = ctx.args[1];
    const z = switch (zsetFor(ctx, key, true)) {
        .wrong_type => return ctx.wrongType(),
        .missing => return ctx.w.int(0),
        .found => |z| z,
    };
    var removed: i64 = 0;
    for (ctx.args[2..]) |m| {
        if (z.remove(ctx.gpa, m)) removed += 1;
    }
    if (removed > 0) ctx.modified(key);
    dropIfEmpty(ctx, key, z);
    try ctx.w.int(removed);
}

pub fn zscore(ctx: *Ctx) Error!void {
    switch (zsetFor(ctx, ctx.args[1], false)) {
        .wrong_type => try ctx.wrongType(),
        .missing => try ctx.w.nullBulk(),
        .found => |z| if (z.score(ctx.args[2])) |s| try ctx.w.double(s) else try ctx.w.nullBulk(),
    }
}

pub fn zmscore(ctx: *Ctx) Error!void {
    const z: ?*ZSet = switch (zsetFor(ctx, ctx.args[1], false)) {
        .wrong_type => return ctx.wrongType(),
        .missing => null,
        .found => |z| z,
    };
    try ctx.w.array(ctx.args.len - 2);
    for (ctx.args[2..]) |m| {
        if (z) |zz| if (zz.score(m)) |s| {
            try ctx.w.double(s);
            continue;
        };
        try ctx.w.nullBulk();
    }
}

pub fn zcard(ctx: *Ctx) Error!void {
    switch (zsetFor(ctx, ctx.args[1], false)) {
        .wrong_type => try ctx.wrongType(),
        .missing => try ctx.w.int(0),
        .found => |z| try ctx.w.int(@intCast(z.len())),
    }
}

fn parseScoreRange(ctx: *Ctx, min_s: []const u8, max_s: []const u8) Error!?ScoreRange {
    const min = zset_mod.parseScoreBound(min_s) orelse {
        try ctx.w.err(msg.min_max_float);
        return null;
    };
    const max = zset_mod.parseScoreBound(max_s) orelse {
        try ctx.w.err(msg.min_max_float);
        return null;
    };
    return .{ .min = min.value, .max = max.value, .min_ex = min.exclusive, .max_ex = max.exclusive };
}

fn parseLexRange(ctx: *Ctx, min_s: []const u8, max_s: []const u8) Error!?LexRange {
    const min = LexBound.parse(min_s) orelse {
        try ctx.w.err(msg.min_max_lex);
        return null;
    };
    const max = LexBound.parse(max_s) orelse {
        try ctx.w.err(msg.min_max_lex);
        return null;
    };
    return .{ .min = min, .max = max };
}

pub fn zcount(ctx: *Ctx) Error!void {
    const range = (try parseScoreRange(ctx, ctx.args[2], ctx.args[3])) orelse return;
    switch (zsetFor(ctx, ctx.args[1], false)) {
        .wrong_type => try ctx.wrongType(),
        .missing => try ctx.w.int(0),
        .found => |z| try ctx.w.int(@intCast(z.countInScoreRange(range))),
    }
}

pub fn zlexcount(ctx: *Ctx) Error!void {
    const range = (try parseLexRange(ctx, ctx.args[2], ctx.args[3])) orelse return;
    switch (zsetFor(ctx, ctx.args[1], false)) {
        .wrong_type => try ctx.wrongType(),
        .missing => try ctx.w.int(0),
        .found => |z| try ctx.w.int(@intCast(z.countInLexRange(range))),
    }
}

fn rankGeneric(ctx: *Ctx, reverse: bool) Error!void {
    if (ctx.args.len > 4) return ctx.syntaxError();
    var with_score = false;
    if (ctx.args.len == 4) {
        if (!Ctx.is(ctx.args[3], "withscore")) return ctx.syntaxError();
        with_score = true;
    }
    const z = switch (zsetFor(ctx, ctx.args[1], false)) {
        .wrong_type => return ctx.wrongType(),
        .missing => return if (with_score) ctx.w.nullArray() else ctx.w.nullBulk(),
        .found => |z| z,
    };
    const r = z.rank(ctx.args[2], reverse) orelse return if (with_score) ctx.w.nullArray() else ctx.w.nullBulk();
    if (with_score) {
        try ctx.w.array(2);
        try ctx.w.int(@intCast(r));
        try ctx.w.double(z.score(ctx.args[2]).?);
    } else {
        try ctx.w.int(@intCast(r));
    }
}

pub fn zrank(ctx: *Ctx) Error!void {
    try rankGeneric(ctx, false);
}

pub fn zrevrank(ctx: *Ctx) Error!void {
    try rankGeneric(ctx, true);
}

// ---------------------------------------------------------------- ranges --

const RangeKind = enum { rank, score, lex };

const RangeSpec = struct {
    kind: RangeKind = .rank,
    rev: bool = false,
    with_scores: bool = false,
    offset: i64 = 0,
    limit: i64 = -1,
    has_limit: bool = false,
    start: []const u8,
    stop: []const u8,
};

/// Collects the nodes selected by a range specification, in reply order.
/// Returns null after replying with an error.
fn collectRange(ctx: *Ctx, z: *ZSet, spec: RangeSpec, out: *std.ArrayList(*Node)) Error!?void {
    switch (spec.kind) {
        .rank => {
            const start = (try ctx.int(spec.start)) orelse return null;
            const stop = (try ctx.int(spec.stop)) orelse return null;
            const r = num.normalizeRange(start, stop, z.len()) orelse return;
            const count = r.end - r.start + 1;
            try out.ensureTotalCapacity(ctx.gpa, count);
            if (spec.rev) {
                var node = z.atRank(z.len() - 1 - r.start);
                var i: usize = 0;
                while (i < count) : (i += 1) {
                    const n = node.?;
                    out.appendAssumeCapacity(n);
                    node = n.backward;
                }
            } else {
                var node = z.atRank(r.start);
                var i: usize = 0;
                while (i < count) : (i += 1) {
                    const n = node.?;
                    out.appendAssumeCapacity(n);
                    node = n.next();
                }
            }
        },
        .score => {
            // In REV mode the arguments are given as max then min.
            const range = (if (spec.rev)
                try parseScoreRange(ctx, spec.stop, spec.start)
            else
                try parseScoreRange(ctx, spec.start, spec.stop)) orelse return null;
            if (spec.offset < 0) return;
            var node = if (spec.rev) z.list.lastInScoreRange(range) else z.list.firstInScoreRange(range);
            var skip: i64 = spec.offset;
            var remaining: i64 = spec.limit;
            while (node) |n| {
                if (spec.rev) {
                    if (!range.aboveMin(n.score)) break;
                } else if (!range.belowMax(n.score)) break;
                if (skip > 0) {
                    skip -= 1;
                } else {
                    if (remaining == 0) break;
                    try out.append(ctx.gpa, n);
                    if (remaining > 0) remaining -= 1;
                }
                node = if (spec.rev) n.backward else n.next();
            }
        },
        .lex => {
            const range = (if (spec.rev)
                try parseLexRange(ctx, spec.stop, spec.start)
            else
                try parseLexRange(ctx, spec.start, spec.stop)) orelse return null;
            if (spec.offset < 0) return;
            var node = if (spec.rev) z.list.lastInLexRange(range) else z.list.firstInLexRange(range);
            var skip: i64 = spec.offset;
            var remaining: i64 = spec.limit;
            while (node) |n| {
                if (spec.rev) {
                    if (!range.aboveMin(n.member)) break;
                } else if (!range.belowMax(n.member)) break;
                if (skip > 0) {
                    skip -= 1;
                } else {
                    if (remaining == 0) break;
                    try out.append(ctx.gpa, n);
                    if (remaining > 0) remaining -= 1;
                }
                node = if (spec.rev) n.backward else n.next();
            }
        },
    }
}

/// Validates range bounds even when the key is missing, so errors are
/// reported consistently.
fn validateBounds(ctx: *Ctx, spec: RangeSpec) Error!bool {
    switch (spec.kind) {
        .rank => {
            if ((try ctx.int(spec.start)) == null) return false;
            if ((try ctx.int(spec.stop)) == null) return false;
        },
        .score => if ((try parseScoreRange(ctx, spec.start, spec.stop)) == null) return false,
        .lex => if ((try parseLexRange(ctx, spec.start, spec.stop)) == null) return false,
    }
    return true;
}

fn replyRange(ctx: *Ctx, key: []const u8, spec: RangeSpec) Error!void {
    const z = switch (zsetFor(ctx, key, false)) {
        .wrong_type => return ctx.wrongType(),
        .missing => {
            if (!try validateBounds(ctx, spec)) return;
            return ctx.w.array(0);
        },
        .found => |z| z,
    };
    var nodes: std.ArrayList(*Node) = .empty;
    defer nodes.deinit(ctx.gpa);
    (try collectRange(ctx, z, spec, &nodes)) orelse return;
    try pairsHeader(ctx, nodes.items.len, spec.with_scores);
    for (nodes.items) |n| {
        if (spec.with_scores) try writePair(ctx, n.member, n.score) else try ctx.w.bulk(n.member);
    }
}

/// Parses trailing ZRANGE-family options starting at `from`.
fn parseRangeOptions(ctx: *Ctx, spec: *RangeSpec, from: usize, allow: struct { by: bool, rev: bool, scores: bool, limit: bool }) Error!bool {
    var i = from;
    while (i < ctx.args.len) : (i += 1) {
        const a = ctx.args[i];
        if (allow.scores and Ctx.is(a, "withscores")) {
            spec.with_scores = true;
        } else if (allow.limit and Ctx.is(a, "limit") and i + 2 < ctx.args.len) {
            spec.offset = (try ctx.int(ctx.args[i + 1])) orelse return false;
            spec.limit = (try ctx.int(ctx.args[i + 2])) orelse return false;
            spec.has_limit = true;
            i += 2;
        } else if (allow.by and Ctx.is(a, "byscore")) {
            spec.kind = .score;
        } else if (allow.by and Ctx.is(a, "bylex")) {
            spec.kind = .lex;
        } else if (allow.rev and Ctx.is(a, "rev")) {
            spec.rev = true;
        } else {
            try ctx.syntaxError();
            return false;
        }
    }
    if (spec.has_limit and spec.kind == .rank) {
        try ctx.w.err("ERR syntax error, LIMIT is only supported in combination with either BYSCORE or BYLEX");
        return false;
    }
    if (spec.with_scores and spec.kind == .lex) {
        try ctx.w.err("ERR syntax error, WITHSCORES not supported in combination with BYLEX");
        return false;
    }
    return true;
}

/// ZRANGE key start stop [BYSCORE|BYLEX] [REV] [LIMIT offset count] [WITHSCORES]
pub fn zrange(ctx: *Ctx) Error!void {
    var spec: RangeSpec = .{ .start = ctx.args[2], .stop = ctx.args[3] };
    if (!try parseRangeOptions(ctx, &spec, 4, .{ .by = true, .rev = true, .scores = true, .limit = true })) return;
    try replyRange(ctx, ctx.args[1], spec);
}

pub fn zrevrange(ctx: *Ctx) Error!void {
    var spec: RangeSpec = .{ .start = ctx.args[2], .stop = ctx.args[3], .rev = true };
    if (!try parseRangeOptions(ctx, &spec, 4, .{ .by = false, .rev = false, .scores = true, .limit = false })) return;
    try replyRange(ctx, ctx.args[1], spec);
}

pub fn zrangebyscore(ctx: *Ctx) Error!void {
    var spec: RangeSpec = .{ .start = ctx.args[2], .stop = ctx.args[3], .kind = .score };
    if (!try parseRangeOptions(ctx, &spec, 4, .{ .by = false, .rev = false, .scores = true, .limit = true })) return;
    try replyRange(ctx, ctx.args[1], spec);
}

pub fn zrevrangebyscore(ctx: *Ctx) Error!void {
    var spec: RangeSpec = .{ .start = ctx.args[2], .stop = ctx.args[3], .kind = .score, .rev = true };
    if (!try parseRangeOptions(ctx, &spec, 4, .{ .by = false, .rev = false, .scores = true, .limit = true })) return;
    try replyRange(ctx, ctx.args[1], spec);
}

pub fn zrangebylex(ctx: *Ctx) Error!void {
    var spec: RangeSpec = .{ .start = ctx.args[2], .stop = ctx.args[3], .kind = .lex };
    if (!try parseRangeOptions(ctx, &spec, 4, .{ .by = false, .rev = false, .scores = false, .limit = true })) return;
    try replyRange(ctx, ctx.args[1], spec);
}

pub fn zrevrangebylex(ctx: *Ctx) Error!void {
    var spec: RangeSpec = .{ .start = ctx.args[2], .stop = ctx.args[3], .kind = .lex, .rev = true };
    if (!try parseRangeOptions(ctx, &spec, 4, .{ .by = false, .rev = false, .scores = false, .limit = true })) return;
    try replyRange(ctx, ctx.args[1], spec);
}

/// ZRANGESTORE dst src min max [BYSCORE|BYLEX] [REV] [LIMIT offset count]
pub fn zrangestore(ctx: *Ctx) Error!void {
    const dst = ctx.args[1];
    var spec: RangeSpec = .{ .start = ctx.args[3], .stop = ctx.args[4] };
    if (!try parseRangeOptions(ctx, &spec, 5, .{ .by = true, .rev = true, .scores = false, .limit = true })) return;
    const d = ctx.db();
    var result = try Value.initZSet(ctx.gpa, d.nextSeed());
    defer result.deinit(ctx.gpa);
    switch (zsetFor(ctx, ctx.args[2], false)) {
        .wrong_type => return ctx.wrongType(),
        .missing => if (!try validateBounds(ctx, spec)) return,
        .found => |z| {
            var nodes: std.ArrayList(*Node) = .empty;
            defer nodes.deinit(ctx.gpa);
            (try collectRange(ctx, z, spec, &nodes)) orelse return;
            for (nodes.items) |n| _ = try result.zset.add(ctx.gpa, n.member, n.score, .{}, null);
        },
    }
    try storeResult(ctx, dst, &result);
}

/// Replaces `dst` with `result` (or deletes it when empty) and replies
/// with the resulting cardinality. Leaves `result` empty but valid.
fn storeResult(ctx: *Ctx, dst: []const u8, result: *Value) Error!void {
    const d = ctx.db();
    const n = result.zset.len();
    if (n == 0) {
        if (d.delete(dst)) ctx.modified(dst);
        return ctx.w.int(0);
    }
    const moved = result.*;
    result.* = try Value.initZSet(ctx.gpa, d.nextSeed());
    try d.set(dst, moved, .{});
    ctx.modified(dst);
    try ctx.w.int(@intCast(n));
}

// ------------------------------------------------------------- removal --

pub fn zremrangebyrank(ctx: *Ctx) Error!void {
    const key = ctx.args[1];
    const start = (try ctx.int(ctx.args[2])) orelse return;
    const stop = (try ctx.int(ctx.args[3])) orelse return;
    const z = switch (zsetFor(ctx, key, true)) {
        .wrong_type => return ctx.wrongType(),
        .missing => return ctx.w.int(0),
        .found => |z| z,
    };
    const r = num.normalizeRange(start, stop, z.len()) orelse return ctx.w.int(0);
    const removed = z.removeRankRange(ctx.gpa, r.start, r.end);
    if (removed > 0) ctx.modified(key);
    dropIfEmpty(ctx, key, z);
    try ctx.w.int(@intCast(removed));
}

pub fn zremrangebyscore(ctx: *Ctx) Error!void {
    const key = ctx.args[1];
    const range = (try parseScoreRange(ctx, ctx.args[2], ctx.args[3])) orelse return;
    const z = switch (zsetFor(ctx, key, true)) {
        .wrong_type => return ctx.wrongType(),
        .missing => return ctx.w.int(0),
        .found => |z| z,
    };
    const removed = z.removeScoreRange(ctx.gpa, range);
    if (removed > 0) ctx.modified(key);
    dropIfEmpty(ctx, key, z);
    try ctx.w.int(@intCast(removed));
}

pub fn zremrangebylex(ctx: *Ctx) Error!void {
    const key = ctx.args[1];
    const range = (try parseLexRange(ctx, ctx.args[2], ctx.args[3])) orelse return;
    const z = switch (zsetFor(ctx, key, true)) {
        .wrong_type => return ctx.wrongType(),
        .missing => return ctx.w.int(0),
        .found => |z| z,
    };
    const removed = z.removeLexRange(ctx.gpa, range);
    if (removed > 0) ctx.modified(key);
    dropIfEmpty(ctx, key, z);
    try ctx.w.int(@intCast(removed));
}

// ------------------------------------------------------------------ pops --

fn popGeneric(ctx: *Ctx, max: bool) Error!void {
    const key = ctx.args[1];
    if (ctx.args.len > 3) return ctx.syntaxError();
    var count: ?usize = null;
    if (ctx.args.len == 3) {
        const v = (try ctx.int(ctx.args[2])) orelse return;
        if (v < 0) return ctx.w.err(msg.positive);
        count = @intCast(v);
    }
    const z = switch (zsetFor(ctx, key, true)) {
        .wrong_type => return ctx.wrongType(),
        .missing => return ctx.w.array(0),
        .found => |z| z,
    };
    const take = @min(count orelse 1, z.len());
    if (count == null) {
        // Single pop: a flat [member, score] in both protocols.
        try ctx.w.array(2);
    } else {
        try pairsHeader(ctx, take, true);
    }
    var i: usize = 0;
    while (i < take) : (i += 1) {
        const p = (try z.popExtreme(ctx.gpa, max)).?;
        defer ctx.gpa.free(p.member);
        if (count == null) {
            try ctx.w.bulk(p.member);
            try ctx.w.double(p.score);
        } else {
            try writePair(ctx, p.member, p.score);
        }
    }
    if (take > 0) ctx.modified(key);
    dropIfEmpty(ctx, key, z);
}

pub fn zpopmin(ctx: *Ctx) Error!void {
    try popGeneric(ctx, false);
}

pub fn zpopmax(ctx: *Ctx) Error!void {
    try popGeneric(ctx, true);
}

fn blockingPop(ctx: *Ctx, max: bool) Error!void {
    const keys = ctx.args[1 .. ctx.args.len - 1];
    const deadline = (try ctx.timeoutDeadline(ctx.args[ctx.args.len - 1])) orelse return;
    for (keys) |key| {
        switch (zsetFor(ctx, key, true)) {
            .wrong_type => return ctx.wrongType(),
            .missing => continue,
            .found => |z| {
                const p = (try z.popExtreme(ctx.gpa, max)).?;
                defer ctx.gpa.free(p.member);
                try ctx.w.array(3);
                try ctx.w.bulk(key);
                try ctx.w.bulk(p.member);
                try ctx.w.double(p.score);
                ctx.modified(key);
                try ctx.propagate(&.{ if (max) "ZPOPMAX" else "ZPOPMIN", key });
                dropIfEmpty(ctx, key, z);
                return;
            },
        }
    }
    if (ctx.client.in_exec or ctx.client.isFake()) return ctx.w.nullArray();
    try ctx.server.blockClient(ctx.client, keys, deadline, .{ .zpop = if (max) .max else .min });
}

pub fn bzpopmin(ctx: *Ctx) Error!void {
    try blockingPop(ctx, false);
}

pub fn bzpopmax(ctx: *Ctx) Error!void {
    try blockingPop(ctx, true);
}

// ------------------------------------------------------- set operations --

const Aggregate = enum { sum, min, max };
const SetOp = enum { @"union", inter, diff };

fn aggregate(agg: Aggregate, a: f64, b: f64) f64 {
    return switch (agg) {
        .sum => blk: {
            const s = a + b;
            // inf + -inf is defined as 0 by Redis.
            break :blk if (std.math.isNan(s)) 0 else s;
        },
        .min => @min(a, b),
        .max => @max(a, b),
    };
}

/// One input to ZUNION/ZINTER/ZDIFF: a sorted set, a plain set (every
/// member scores 1) or nothing.
const Source = union(enum) {
    none,
    zset: *ZSet,
    set: *@import("../value.zig").Set,

    fn len(self: Source) usize {
        return switch (self) {
            .none => 0,
            .zset => |z| z.len(),
            .set => |s| s.count(),
        };
    }

    fn scoreOf(self: Source, member: []const u8) ?f64 {
        return switch (self) {
            .none => null,
            .zset => |z| z.score(member),
            .set => |s| if (s.contains(member)) 1.0 else null,
        };
    }
};

/// Parses `numkeys key... [WEIGHTS w...] [AGGREGATE a] [WITHSCORES]` and
/// computes the result into `result`. Returns false after an error reply.
fn computeSetOp(ctx: *Ctx, op: SetOp, args_from: usize, allow_withscores: bool, result: *ZSet, with_scores: *bool) Error!bool {
    var lower: [16]u8 = undefined;
    const name = std.ascii.lowerString(&lower, ctx.args[0][0..@min(ctx.args[0].len, 16)]);
    const numkeys = (try ctx.int(ctx.args[args_from])) orelse return false;
    if (numkeys < 1) {
        try ctx.w.errFmt("ERR at least 1 input key is needed for '{s}' command", .{name});
        return false;
    }
    const nk: usize = @intCast(numkeys);
    if (args_from + 1 + nk > ctx.args.len) {
        try ctx.syntaxError();
        return false;
    }
    const keys = ctx.args[args_from + 1 .. args_from + 1 + nk];
    const weights = try ctx.gpa.alloc(f64, nk);
    defer ctx.gpa.free(weights);
    @memset(weights, 1.0);
    var agg: Aggregate = .sum;
    var i = args_from + 1 + nk;
    while (i < ctx.args.len) : (i += 1) {
        const a = ctx.args[i];
        if (op != .diff and Ctx.is(a, "weights") and i + nk < ctx.args.len) {
            for (weights, 0..) |*w, j| {
                w.* = num.parseF64(ctx.args[i + 1 + j]) orelse {
                    try ctx.w.err("ERR weight value is not a float");
                    return false;
                };
            }
            i += nk;
        } else if (op != .diff and Ctx.is(a, "aggregate") and i + 1 < ctx.args.len) {
            const v = ctx.args[i + 1];
            agg = if (Ctx.is(v, "sum")) .sum else if (Ctx.is(v, "min")) .min else if (Ctx.is(v, "max")) .max else {
                try ctx.syntaxError();
                return false;
            };
            i += 1;
        } else if (allow_withscores and Ctx.is(a, "withscores")) {
            with_scores.* = true;
        } else {
            try ctx.syntaxError();
            return false;
        }
    }

    const sources = try ctx.gpa.alloc(Source, nk);
    defer ctx.gpa.free(sources);
    for (keys, 0..) |k, j| {
        const v = ctx.db().lookupRead(k);
        sources[j] = if (v) |vv| switch (vv.*) {
            .zset => |z| .{ .zset = z },
            .set => .{ .set = &vv.set },
            else => {
                try ctx.wrongType();
                return false;
            },
        } else .none;
    }

    switch (op) {
        .@"union" => {
            for (sources, 0..) |src, j| {
                try forEachMember(src, struct {
                    fn visit(c: anytype, member: []const u8, score: f64) Error!void {
                        const weighted = weightedScore(score, c.weight);
                        if (c.result.score(member)) |cur| {
                            const combined = aggregate(c.agg, cur, weighted);
                            _ = try c.result.add(c.gpa, member, combined, .{}, null);
                        } else {
                            _ = try c.result.add(c.gpa, member, weighted, .{}, null);
                        }
                    }
                }.visit, .{ .result = result, .weight = weights[j], .agg = agg, .gpa = ctx.gpa });
            }
        },
        .inter => {
            for (sources) |src| if (src == .none) return true;
            var smallest: usize = 0;
            for (sources, 0..) |src, j| {
                if (src.len() < sources[smallest].len()) smallest = j;
            }
            try forEachMember(sources[smallest], struct {
                fn visit(c: anytype, member: []const u8, score: f64) Error!void {
                    var acc = weightedScore(score, c.weights[c.smallest]);
                    for (c.sources, 0..) |other, j| {
                        if (j == c.smallest) continue;
                        const s = other.scoreOf(member) orelse return;
                        acc = aggregate(c.agg, acc, weightedScore(s, c.weights[j]));
                    }
                    _ = try c.result.add(c.gpa, member, acc, .{}, null);
                }
            }.visit, .{ .result = result, .weights = weights, .sources = sources, .smallest = smallest, .agg = agg, .gpa = ctx.gpa });
        },
        .diff => {
            try forEachMember(sources[0], struct {
                fn visit(c: anytype, member: []const u8, score: f64) Error!void {
                    for (c.sources[1..]) |other| if (other.scoreOf(member) != null) return;
                    _ = try c.result.add(c.gpa, member, score, .{}, null);
                }
            }.visit, .{ .result = result, .sources = sources, .gpa = ctx.gpa });
        },
    }
    return true;
}

fn weightedScore(score: f64, weight: f64) f64 {
    const v = score * weight;
    // 0 * inf is NaN; Redis treats it as 0.
    return if (std.math.isNan(v)) 0 else v;
}

fn forEachMember(src: Source, comptime visit: anytype, c: anytype) Error!void {
    switch (src) {
        .none => {},
        .zset => |z| {
            var node = z.list.first();
            while (node) |n| : (node = n.next()) try visit(c, n.member, n.score);
        },
        .set => |s| for (s.keys()) |m| try visit(c, m, 1.0),
    }
}

fn setOpReply(ctx: *Ctx, op: SetOp) Error!void {
    var result = try ZSet.init(ctx.gpa, ctx.server.randomSeed());
    defer result.deinit(ctx.gpa);
    var with_scores = false;
    if (!try computeSetOp(ctx, op, 1, true, &result, &with_scores)) return;
    try pairsHeader(ctx, result.len(), with_scores);
    var node = result.list.first();
    while (node) |n| : (node = n.next()) {
        if (with_scores) try writePair(ctx, n.member, n.score) else try ctx.w.bulk(n.member);
    }
}

fn setOpStore(ctx: *Ctx, op: SetOp) Error!void {
    const d = ctx.db();
    var result = try Value.initZSet(ctx.gpa, d.nextSeed());
    defer result.deinit(ctx.gpa);
    var with_scores = false;
    if (!try computeSetOp(ctx, op, 2, false, result.zset, &with_scores)) return;
    try storeResult(ctx, ctx.args[1], &result);
}

pub fn zunion(ctx: *Ctx) Error!void {
    try setOpReply(ctx, .@"union");
}

pub fn zinter(ctx: *Ctx) Error!void {
    try setOpReply(ctx, .inter);
}

pub fn zdiff(ctx: *Ctx) Error!void {
    try setOpReply(ctx, .diff);
}

pub fn zunionstore(ctx: *Ctx) Error!void {
    try setOpStore(ctx, .@"union");
}

pub fn zinterstore(ctx: *Ctx) Error!void {
    try setOpStore(ctx, .inter);
}

pub fn zdiffstore(ctx: *Ctx) Error!void {
    try setOpStore(ctx, .diff);
}

/// ZINTERCARD numkeys key [key ...] [LIMIT limit]
pub fn zintercard(ctx: *Ctx) Error!void {
    const numkeys = (try ctx.int(ctx.args[1])) orelse return;
    if (numkeys <= 0) return ctx.w.err("ERR numkeys should be greater than 0");
    const nk: usize = @intCast(numkeys);
    if (ctx.args.len < 2 + nk) return ctx.w.err("ERR Number of keys can't be greater than number of args");
    var limit: usize = 0;
    var i = 2 + nk;
    while (i < ctx.args.len) : (i += 2) {
        if (Ctx.is(ctx.args[i], "limit") and i + 1 < ctx.args.len) {
            const l = (try ctx.int(ctx.args[i + 1])) orelse return;
            if (l < 0) return ctx.w.err("ERR LIMIT can't be negative");
            limit = @intCast(l);
        } else return ctx.syntaxError();
    }
    const sources = try ctx.gpa.alloc(Source, nk);
    defer ctx.gpa.free(sources);
    for (ctx.args[2 .. 2 + nk], 0..) |k, j| {
        const v = ctx.db().lookupRead(k);
        sources[j] = if (v) |vv| switch (vv.*) {
            .zset => |z| .{ .zset = z },
            .set => .{ .set = &vv.set },
            else => return ctx.wrongType(),
        } else return ctx.w.int(0);
    }
    var smallest: usize = 0;
    for (sources, 0..) |src, j| {
        if (src.len() < sources[smallest].len()) smallest = j;
    }
    var count: usize = 0;
    const Counter = struct {
        fn visit(c: anytype, member: []const u8, _: f64) Error!void {
            if (c.limit.* > 0 and c.count.* >= c.limit.*) return;
            for (c.sources, 0..) |other, j| {
                if (j == c.smallest) continue;
                if (other.scoreOf(member) == null) return;
            }
            c.count.* += 1;
        }
    };
    try forEachMember(sources[smallest], Counter.visit, .{ .sources = sources, .smallest = smallest, .count = &count, .limit = &limit });
    try ctx.w.int(@intCast(count));
}

/// ZRANDMEMBER key [count [WITHSCORES]]
pub fn zrandmember(ctx: *Ctx) Error!void {
    if (ctx.args.len > 4) return ctx.syntaxError();
    var count: ?i64 = null;
    var with_scores = false;
    if (ctx.args.len >= 3) {
        count = (try ctx.int(ctx.args[2])) orelse return;
        if (ctx.args.len == 4) {
            if (!Ctx.is(ctx.args[3], "withscores")) return ctx.syntaxError();
            with_scores = true;
        }
    }
    const z = switch (zsetFor(ctx, ctx.args[1], false)) {
        .wrong_type => return ctx.wrongType(),
        .missing => return if (count != null) ctx.w.array(0) else ctx.w.nullBulk(),
        .found => |z| z,
    };
    var rng = std.Random.DefaultPrng.init(ctx.server.randomSeed());
    const r = rng.random();
    const members = z.dict.keys();
    const c = count orelse return ctx.w.bulk(members[r.uintLessThan(usize, members.len)]);
    var picks: std.ArrayList(usize) = .empty;
    defer picks.deinit(ctx.gpa);
    try hashes.samplePositions(ctx.gpa, r, members.len, c, &picks);
    try pairsHeader(ctx, picks.items.len, with_scores);
    for (picks.items) |p| {
        if (with_scores) try writePair(ctx, members[p], z.dict.values()[p]) else try ctx.w.bulk(members[p]);
    }
}

pub fn zscan(ctx: *Ctx) Error!void {
    const cursor = (try keys_cmds.parseCursor(ctx, ctx.args[2])) orelse return;
    const opts = (try keys_cmds.parseScanOptions(ctx, 3, false)) orelse return;
    const z = switch (zsetFor(ctx, ctx.args[1], false)) {
        .wrong_type => return ctx.wrongType(),
        .missing => {
            try ctx.w.array(2);
            try ctx.w.bulk("0");
            return ctx.w.array(0);
        },
        .found => |z| z,
    };
    var positions: std.ArrayList(usize) = .empty;
    defer positions.deinit(ctx.gpa);
    const next = try hashes.scanArrayMap(z.len(), cursor, opts.count, &positions, ctx.gpa);
    var matched: std.ArrayList(usize) = .empty;
    defer matched.deinit(ctx.gpa);
    for (positions.items) |p| {
        if (opts.pattern) |pat| if (!glob.match(pat, z.dict.keys()[p])) continue;
        try matched.append(ctx.gpa, p);
    }
    try ctx.w.array(2);
    try ctx.w.bulkInt(@intCast(next));
    try ctx.w.array(if (opts.novalues) matched.items.len else matched.items.len * 2);
    for (matched.items) |p| {
        try ctx.w.bulk(z.dict.keys()[p]);
        if (!opts.novalues) try ctx.w.double(z.dict.values()[p]);
    }
}
