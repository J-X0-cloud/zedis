//! Hash commands.

const std = @import("std");
const num = @import("../num.zig");
const glob = @import("../glob.zig");
const value_mod = @import("../value.zig");
const ctx_mod = @import("ctx.zig");
const keys_cmds = @import("keys.zig");
const Db = @import("../db.zig").Db;
const Ctx = ctx_mod.Ctx;
const Error = ctx_mod.Error;
const msg = ctx_mod.msg;
const Hash = value_mod.Hash;

fn hashFor(ctx: *Ctx, key: []const u8, for_write: bool) union(enum) { missing, wrong_type, found: *Hash } {
    return switch (ctx.lookup(key, .hash, for_write)) {
        .missing => .missing,
        .wrong_type => .wrong_type,
        .found => |v| .{ .found = &v.hash },
    };
}

fn hashForWrite(ctx: *Ctx, key: []const u8) Error!?*Hash {
    return switch (hashFor(ctx, key, true)) {
        .wrong_type => {
            try ctx.wrongType();
            return null;
        },
        .found => |h| h,
        .missing => &(try ctx.db().add(key, .{ .hash = .empty })).hash,
    };
}

fn dropIfEmpty(ctx: *Ctx, key: []const u8, h: *Hash) void {
    if (h.count() == 0) _ = ctx.db().delete(key);
}

fn hsetGeneric(ctx: *Ctx, reply_count: bool) Error!void {
    if (ctx.args.len % 2 != 0) return ctx.wrongArity();
    const key = ctx.args[1];
    const h = (try hashForWrite(ctx, key)) orelse return;
    var created: i64 = 0;
    var i: usize = 2;
    while (i < ctx.args.len) : (i += 2) {
        if (try value_mod.hashSet(ctx.gpa, h, ctx.args[i], ctx.args[i + 1])) created += 1;
    }
    ctx.modified(key);
    if (reply_count) try ctx.w.int(created) else try ctx.w.ok();
}

pub fn hset(ctx: *Ctx) Error!void {
    try hsetGeneric(ctx, true);
}

pub fn hmset(ctx: *Ctx) Error!void {
    try hsetGeneric(ctx, false);
}

pub fn hsetnx(ctx: *Ctx) Error!void {
    const key = ctx.args[1];
    switch (hashFor(ctx, key, true)) {
        .wrong_type => return ctx.wrongType(),
        .found => |h| if (h.contains(ctx.args[2])) return ctx.w.int(0),
        .missing => {},
    }
    const h = (try hashForWrite(ctx, key)).?;
    _ = try value_mod.hashSet(ctx.gpa, h, ctx.args[2], ctx.args[3]);
    ctx.modified(key);
    try ctx.w.int(1);
}

pub fn hget(ctx: *Ctx) Error!void {
    switch (hashFor(ctx, ctx.args[1], false)) {
        .wrong_type => try ctx.wrongType(),
        .missing => try ctx.w.nullBulk(),
        .found => |h| if (h.get(ctx.args[2])) |v| try ctx.w.bulk(v) else try ctx.w.nullBulk(),
    }
}

pub fn hmget(ctx: *Ctx) Error!void {
    const h: ?*Hash = switch (hashFor(ctx, ctx.args[1], false)) {
        .wrong_type => return ctx.wrongType(),
        .missing => null,
        .found => |h| h,
    };
    try ctx.w.array(ctx.args.len - 2);
    for (ctx.args[2..]) |f| {
        if (h) |hh| if (hh.get(f)) |v| {
            try ctx.w.bulk(v);
            continue;
        };
        try ctx.w.nullBulk();
    }
}

pub fn hdel(ctx: *Ctx) Error!void {
    const key = ctx.args[1];
    const h = switch (hashFor(ctx, key, true)) {
        .wrong_type => return ctx.wrongType(),
        .missing => return ctx.w.int(0),
        .found => |h| h,
    };
    var removed: i64 = 0;
    for (ctx.args[2..]) |f| {
        if (value_mod.hashDelete(ctx.gpa, h, f)) removed += 1;
    }
    if (removed > 0) ctx.modified(key);
    dropIfEmpty(ctx, key, h);
    try ctx.w.int(removed);
}

pub fn hlen(ctx: *Ctx) Error!void {
    switch (hashFor(ctx, ctx.args[1], false)) {
        .wrong_type => try ctx.wrongType(),
        .missing => try ctx.w.int(0),
        .found => |h| try ctx.w.int(@intCast(h.count())),
    }
}

pub fn hstrlen(ctx: *Ctx) Error!void {
    switch (hashFor(ctx, ctx.args[1], false)) {
        .wrong_type => try ctx.wrongType(),
        .missing => try ctx.w.int(0),
        .found => |h| try ctx.w.int(if (h.get(ctx.args[2])) |v| @intCast(v.len) else 0),
    }
}

pub fn hexists(ctx: *Ctx) Error!void {
    switch (hashFor(ctx, ctx.args[1], false)) {
        .wrong_type => try ctx.wrongType(),
        .missing => try ctx.w.int(0),
        .found => |h| try ctx.w.int(@intFromBool(h.contains(ctx.args[2]))),
    }
}

const Part = enum { keys, values, both };

fn hgetallGeneric(ctx: *Ctx, part: Part) Error!void {
    const h = switch (hashFor(ctx, ctx.args[1], false)) {
        .wrong_type => return ctx.wrongType(),
        .missing => return if (part == .both) ctx.w.map(0) else ctx.w.array(0),
        .found => |h| h,
    };
    switch (part) {
        .both => {
            try ctx.w.map(h.count());
            for (h.keys(), h.values()) |k, v| {
                try ctx.w.bulk(k);
                try ctx.w.bulk(v);
            }
        },
        .keys => {
            try ctx.w.array(h.count());
            for (h.keys()) |k| try ctx.w.bulk(k);
        },
        .values => {
            try ctx.w.array(h.count());
            for (h.values()) |v| try ctx.w.bulk(v);
        },
    }
}

pub fn hgetall(ctx: *Ctx) Error!void {
    try hgetallGeneric(ctx, .both);
}

pub fn hkeys(ctx: *Ctx) Error!void {
    try hgetallGeneric(ctx, .keys);
}

pub fn hvals(ctx: *Ctx) Error!void {
    try hgetallGeneric(ctx, .values);
}

pub fn hincrby(ctx: *Ctx) Error!void {
    const key = ctx.args[1];
    const delta = (try ctx.int(ctx.args[3])) orelse return;
    const h = (try hashForWrite(ctx, key)) orelse return;
    var current: i64 = 0;
    if (h.get(ctx.args[2])) |v| {
        current = num.parseI64(v) orelse {
            dropIfEmpty(ctx, key, h);
            return ctx.w.err("ERR hash value is not an integer");
        };
    }
    const result = std.math.add(i64, current, delta) catch {
        dropIfEmpty(ctx, key, h);
        return ctx.w.err(msg.overflow);
    };
    var buf: [24]u8 = undefined;
    _ = try value_mod.hashSet(ctx.gpa, h, ctx.args[2], num.formatI64(&buf, result));
    ctx.modified(key);
    try ctx.w.int(result);
}

pub fn hincrbyfloat(ctx: *Ctx) Error!void {
    const key = ctx.args[1];
    const delta = num.parseF80(ctx.args[3]) orelse return ctx.w.err(msg.not_float);
    const h = (try hashForWrite(ctx, key)) orelse return;
    var current: f80 = 0;
    if (h.get(ctx.args[2])) |v| {
        current = num.parseF80(v) orelse {
            dropIfEmpty(ctx, key, h);
            return ctx.w.err("ERR hash value is not a float");
        };
    }
    const result = current + delta;
    if (std.math.isNan(result) or std.math.isInf(result)) {
        dropIfEmpty(ctx, key, h);
        return ctx.w.err("ERR increment would produce NaN or Infinity");
    }
    var buf: [num.max_human_chars]u8 = undefined;
    const s = num.formatHuman(&buf, result);
    _ = try value_mod.hashSet(ctx.gpa, h, ctx.args[2], s);
    ctx.modified(key);
    try ctx.propagate(&.{ "HSET", key, ctx.args[2], s });
    try ctx.w.bulk(s);
}

/// HRANDFIELD key [count [WITHVALUES]]
pub fn hrandfield(ctx: *Ctx) Error!void {
    if (ctx.args.len > 4) return ctx.syntaxError();
    var count: ?i64 = null;
    var with_values = false;
    if (ctx.args.len >= 3) {
        count = (try ctx.int(ctx.args[2])) orelse return;
        if (ctx.args.len == 4) {
            if (!Ctx.is(ctx.args[3], "withvalues")) return ctx.syntaxError();
            with_values = true;
        }
    }
    const h = switch (hashFor(ctx, ctx.args[1], false)) {
        .wrong_type => return ctx.wrongType(),
        .missing => return if (count != null) ctx.w.array(0) else ctx.w.nullBulk(),
        .found => |h| h,
    };
    var rng = std.Random.DefaultPrng.init(ctx.server.randomSeed());
    const r = rng.random();
    const n = h.count();
    const c = count orelse {
        const idx = r.uintLessThan(usize, n);
        return ctx.w.bulk(h.keys()[idx]);
    };
    var picks: std.ArrayList(usize) = .empty;
    defer picks.deinit(ctx.gpa);
    try samplePositions(ctx.gpa, r, n, c, &picks);
    if (with_values and ctx.client.proto >= 3) {
        try ctx.w.array(picks.items.len);
        for (picks.items) |p| {
            try ctx.w.array(2);
            try ctx.w.bulk(h.keys()[p]);
            try ctx.w.bulk(h.values()[p]);
        }
    } else {
        try ctx.w.array(if (with_values) picks.items.len * 2 else picks.items.len);
        for (picks.items) |p| {
            try ctx.w.bulk(h.keys()[p]);
            if (with_values) try ctx.w.bulk(h.values()[p]);
        }
    }
}

/// Chooses positions for HRANDFIELD/SRANDMEMBER/ZRANDMEMBER. A positive
/// count yields distinct positions (at most `n`), chosen with a partial
/// Fisher-Yates shuffle; a negative count allows repetitions.
pub fn samplePositions(gpa: std.mem.Allocator, r: std.Random, n: usize, count: i64, out: *std.ArrayList(usize)) Error!void {
    if (count == 0 or n == 0) return;
    if (count < 0) {
        const want: usize = @intCast(@min(@as(u64, @abs(count)), 10_000_000));
        try out.ensureTotalCapacity(gpa, want);
        var i: usize = 0;
        while (i < want) : (i += 1) out.appendAssumeCapacity(r.uintLessThan(usize, n));
        return;
    }
    const want: usize = @intCast(@min(@as(u64, @intCast(count)), n));
    if (want == n) {
        try out.ensureTotalCapacity(gpa, n);
        var i: usize = 0;
        while (i < n) : (i += 1) out.appendAssumeCapacity(i);
        return;
    }
    // Sparse Fisher-Yates: only the swapped slots are materialized.
    var swaps = std.AutoHashMap(usize, usize).init(gpa);
    defer swaps.deinit();
    try out.ensureTotalCapacity(gpa, want);
    var i: usize = 0;
    while (i < want) : (i += 1) {
        const j = i + r.uintLessThan(usize, n - i);
        const vi = swaps.get(i) orelse i;
        const vj = swaps.get(j) orelse j;
        try swaps.put(j, vi);
        out.appendAssumeCapacity(vj);
    }
}

/// Shared cursor walk for HSCAN, SSCAN and ZSCAN over an array hash map.
pub fn scanArrayMap(total: usize, cursor: u64, count: usize, positions: *std.ArrayList(usize), gpa: std.mem.Allocator) Error!u64 {
    const Visitor = struct {
        list: *std.ArrayList(usize),
        gpa: std.mem.Allocator,
        failed: bool = false,
        pub fn visit(v: *@This(), idx: usize) void {
            v.list.append(v.gpa, idx) catch {
                v.failed = true;
            };
        }
    };
    var visitor: Visitor = .{ .list = positions, .gpa = gpa };
    // Small collections are returned in one go, as Redis does for its
    // compact encodings.
    const effective = if (total <= 128) total else count;
    const next = Db.scanIndices(total, cursor, effective, &visitor);
    if (visitor.failed) return error.OutOfMemory;
    return next;
}

pub fn hscan(ctx: *Ctx) Error!void {
    const cursor = (try keys_cmds.parseCursor(ctx, ctx.args[2])) orelse return;
    const opts = (try keys_cmds.parseScanOptions(ctx, 3, false)) orelse return;
    const h = switch (hashFor(ctx, ctx.args[1], false)) {
        .wrong_type => return ctx.wrongType(),
        .missing => {
            try ctx.w.array(2);
            try ctx.w.bulk("0");
            return ctx.w.array(0);
        },
        .found => |h| h,
    };
    var positions: std.ArrayList(usize) = .empty;
    defer positions.deinit(ctx.gpa);
    const next = try scanArrayMap(h.count(), cursor, opts.count, &positions, ctx.gpa);
    var matched: std.ArrayList(usize) = .empty;
    defer matched.deinit(ctx.gpa);
    for (positions.items) |p| {
        if (opts.pattern) |pat| if (!glob.match(pat, h.keys()[p])) continue;
        try matched.append(ctx.gpa, p);
    }
    try ctx.w.array(2);
    try ctx.w.bulkInt(@intCast(next));
    try ctx.w.array(if (opts.novalues) matched.items.len else matched.items.len * 2);
    for (matched.items) |p| {
        try ctx.w.bulk(h.keys()[p]);
        if (!opts.novalues) try ctx.w.bulk(h.values()[p]);
    }
}
