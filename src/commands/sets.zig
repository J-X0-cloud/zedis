//! Set commands, including the algebra (SINTER/SUNION/SDIFF and STORE).

const std = @import("std");
const glob = @import("../glob.zig");
const value_mod = @import("../value.zig");
const ctx_mod = @import("ctx.zig");
const keys_cmds = @import("keys.zig");
const hashes = @import("hashes.zig");
const Ctx = ctx_mod.Ctx;
const Error = ctx_mod.Error;
const msg = ctx_mod.msg;
const Set = value_mod.Set;

fn setFor(ctx: *Ctx, key: []const u8, for_write: bool) union(enum) { missing, wrong_type, found: *Set } {
    return switch (ctx.lookup(key, .set, for_write)) {
        .missing => .missing,
        .wrong_type => .wrong_type,
        .found => |v| .{ .found = &v.set },
    };
}

fn dropIfEmpty(ctx: *Ctx, key: []const u8, s: *Set) void {
    if (s.count() == 0) _ = ctx.db().delete(key);
}

pub fn sadd(ctx: *Ctx) Error!void {
    const key = ctx.args[1];
    const s = switch (setFor(ctx, key, true)) {
        .wrong_type => return ctx.wrongType(),
        .found => |s| s,
        .missing => &(try ctx.db().add(key, .{ .set = .empty })).set,
    };
    var added: i64 = 0;
    for (ctx.args[2..]) |m| {
        if (try value_mod.setAdd(ctx.gpa, s, m)) added += 1;
    }
    if (added > 0) ctx.modified(key);
    try ctx.w.int(added);
}

pub fn srem(ctx: *Ctx) Error!void {
    const key = ctx.args[1];
    const s = switch (setFor(ctx, key, true)) {
        .wrong_type => return ctx.wrongType(),
        .missing => return ctx.w.int(0),
        .found => |s| s,
    };
    var removed: i64 = 0;
    for (ctx.args[2..]) |m| {
        if (value_mod.setRemove(ctx.gpa, s, m)) removed += 1;
    }
    if (removed > 0) ctx.modified(key);
    dropIfEmpty(ctx, key, s);
    try ctx.w.int(removed);
}

pub fn sismember(ctx: *Ctx) Error!void {
    switch (setFor(ctx, ctx.args[1], false)) {
        .wrong_type => try ctx.wrongType(),
        .missing => try ctx.w.int(0),
        .found => |s| try ctx.w.int(@intFromBool(s.contains(ctx.args[2]))),
    }
}

pub fn smismember(ctx: *Ctx) Error!void {
    const s: ?*Set = switch (setFor(ctx, ctx.args[1], false)) {
        .wrong_type => return ctx.wrongType(),
        .missing => null,
        .found => |s| s,
    };
    try ctx.w.array(ctx.args.len - 2);
    for (ctx.args[2..]) |m| try ctx.w.int(if (s) |ss| @intFromBool(ss.contains(m)) else 0);
}

pub fn scard(ctx: *Ctx) Error!void {
    switch (setFor(ctx, ctx.args[1], false)) {
        .wrong_type => try ctx.wrongType(),
        .missing => try ctx.w.int(0),
        .found => |s| try ctx.w.int(@intCast(s.count())),
    }
}

pub fn smembers(ctx: *Ctx) Error!void {
    switch (setFor(ctx, ctx.args[1], false)) {
        .wrong_type => try ctx.wrongType(),
        .missing => try ctx.w.set(0),
        .found => |s| {
            try ctx.w.set(s.count());
            for (s.keys()) |m| try ctx.w.bulk(m);
        },
    }
}

/// SPOP key [count]. Propagated as SREM so replay is deterministic.
pub fn spop(ctx: *Ctx) Error!void {
    const key = ctx.args[1];
    if (ctx.args.len > 3) return ctx.syntaxError();
    var count: ?usize = null;
    if (ctx.args.len == 3) {
        const v = (try ctx.int(ctx.args[2])) orelse return;
        if (v < 0) return ctx.w.err(msg.positive);
        count = @intCast(v);
    }
    const s = switch (setFor(ctx, key, true)) {
        .wrong_type => return ctx.wrongType(),
        .missing => return if (count != null) ctx.w.set(0) else ctx.w.nullBulk(),
        .found => |s| s,
    };
    var rng = std.Random.DefaultPrng.init(ctx.server.randomSeed());
    const r = rng.random();
    const want = count orelse 1;
    const take = @min(want, s.count());
    var popped: std.ArrayList([]const u8) = .empty;
    defer {
        for (popped.items) |m| ctx.gpa.free(m);
        popped.deinit(ctx.gpa);
    }
    try popped.ensureTotalCapacity(ctx.gpa, take);
    var i: usize = 0;
    while (i < take) : (i += 1) {
        const idx = r.uintLessThan(usize, s.count());
        const member = s.keys()[idx];
        s.swapRemoveAt(idx);
        popped.appendAssumeCapacity(member);
    }
    if (count == null) {
        try ctx.w.bulk(popped.items[0]);
    } else {
        try ctx.w.set(popped.items.len);
        for (popped.items) |m| try ctx.w.bulk(m);
    }
    if (take > 0) {
        ctx.modified(key);
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(ctx.gpa);
        try args.appendSlice(ctx.gpa, &.{ "SREM", key });
        for (popped.items) |m| try args.append(ctx.gpa, m);
        try ctx.propagate(args.items);
    } else {
        ctx.noPropagation();
    }
    dropIfEmpty(ctx, key, s);
}

pub fn srandmember(ctx: *Ctx) Error!void {
    if (ctx.args.len > 3) return ctx.syntaxError();
    var count: ?i64 = null;
    if (ctx.args.len == 3) count = (try ctx.int(ctx.args[2])) orelse return;
    const s = switch (setFor(ctx, ctx.args[1], false)) {
        .wrong_type => return ctx.wrongType(),
        .missing => return if (count != null) ctx.w.array(0) else ctx.w.nullBulk(),
        .found => |s| s,
    };
    var rng = std.Random.DefaultPrng.init(ctx.server.randomSeed());
    const r = rng.random();
    const c = count orelse return ctx.w.bulk(s.keys()[r.uintLessThan(usize, s.count())]);
    var picks: std.ArrayList(usize) = .empty;
    defer picks.deinit(ctx.gpa);
    try hashes.samplePositions(ctx.gpa, r, s.count(), c, &picks);
    try ctx.w.array(picks.items.len);
    for (picks.items) |p| try ctx.w.bulk(s.keys()[p]);
}

pub fn smove(ctx: *Ctx) Error!void {
    const src_key = ctx.args[1];
    const dst_key = ctx.args[2];
    const member = ctx.args[3];
    const src = switch (setFor(ctx, src_key, true)) {
        .wrong_type => return ctx.wrongType(),
        .missing => return ctx.w.int(0),
        .found => |s| s,
    };
    switch (setFor(ctx, dst_key, true)) {
        .wrong_type => return ctx.wrongType(),
        else => {},
    }
    if (!src.contains(member)) return ctx.w.int(0);
    if (std.mem.eql(u8, src_key, dst_key)) return ctx.w.int(1);
    _ = value_mod.setRemove(ctx.gpa, src, member);
    dropIfEmpty(ctx, src_key, src);
    const dst = switch (setFor(ctx, dst_key, true)) {
        .found => |s| s,
        else => &(try ctx.db().add(dst_key, .{ .set = .empty })).set,
    };
    _ = try value_mod.setAdd(ctx.gpa, dst, member);
    ctx.modified(src_key);
    ctx.modified(dst_key);
    try ctx.w.int(1);
}

const Op = enum { inter, @"union", diff };

/// Computes the set algebra result into `out` (member slices borrowed
/// from the inputs). Returns false after replying WRONGTYPE.
fn compute(ctx: *Ctx, op: Op, keys: []const []const u8, out: *std.StringArrayHashMapUnmanaged(void)) Error!bool {
    var sets: std.ArrayList(?*Set) = .empty;
    defer sets.deinit(ctx.gpa);
    for (keys) |k| {
        switch (setFor(ctx, k, false)) {
            .wrong_type => {
                try ctx.wrongType();
                return false;
            },
            .missing => try sets.append(ctx.gpa, null),
            .found => |s| try sets.append(ctx.gpa, s),
        }
    }
    switch (op) {
        .inter => {
            // Any empty input makes the intersection empty.
            for (sets.items) |s| if (s == null) return true;
            // Iterate the smallest set and probe the others.
            var smallest: usize = 0;
            for (sets.items, 0..) |s, i| {
                if (s.?.count() < sets.items[smallest].?.count()) smallest = i;
            }
            outer: for (sets.items[smallest].?.keys()) |m| {
                for (sets.items, 0..) |s, i| {
                    if (i == smallest) continue;
                    if (!s.?.contains(m)) continue :outer;
                }
                try out.put(ctx.gpa, m, {});
            }
        },
        .@"union" => {
            for (sets.items) |s| {
                const ss = s orelse continue;
                for (ss.keys()) |m| try out.put(ctx.gpa, m, {});
            }
        },
        .diff => {
            const first = sets.items[0] orelse return true;
            outer: for (first.keys()) |m| {
                for (sets.items[1..]) |s| {
                    if (s) |ss| if (ss.contains(m)) continue :outer;
                }
                try out.put(ctx.gpa, m, {});
            }
        },
    }
    return true;
}

fn algebra(ctx: *Ctx, op: Op) Error!void {
    var out: std.StringArrayHashMapUnmanaged(void) = .empty;
    defer out.deinit(ctx.gpa);
    if (!try compute(ctx, op, ctx.args[1..], &out)) return;
    try ctx.w.set(out.count());
    for (out.keys()) |m| try ctx.w.bulk(m);
}

fn algebraStore(ctx: *Ctx, op: Op) Error!void {
    const dest = ctx.args[1];
    var out: std.StringArrayHashMapUnmanaged(void) = .empty;
    defer out.deinit(ctx.gpa);
    if (!try compute(ctx, op, ctx.args[2..], &out)) return;
    // Build the result before touching the destination, which may also
    // be one of the inputs.
    var result: ctx_mod.Value = .{ .set = .empty };
    errdefer result.deinit(ctx.gpa);
    try result.set.ensureTotalCapacity(ctx.gpa, out.count());
    for (out.keys()) |m| result.set.putAssumeCapacityNoClobber(try ctx.gpa.dupe(u8, m), {});
    const d = ctx.db();
    const n = result.set.count();
    if (n == 0) {
        result.deinit(ctx.gpa);
        if (d.delete(dest)) ctx.modified(dest);
        return ctx.w.int(0);
    }
    try d.set(dest, result, .{});
    ctx.modified(dest);
    try ctx.w.int(@intCast(n));
}

pub fn sinter(ctx: *Ctx) Error!void {
    try algebra(ctx, .inter);
}

pub fn sunion(ctx: *Ctx) Error!void {
    try algebra(ctx, .@"union");
}

pub fn sdiff(ctx: *Ctx) Error!void {
    try algebra(ctx, .diff);
}

pub fn sinterstore(ctx: *Ctx) Error!void {
    try algebraStore(ctx, .inter);
}

pub fn sunionstore(ctx: *Ctx) Error!void {
    try algebraStore(ctx, .@"union");
}

pub fn sdiffstore(ctx: *Ctx) Error!void {
    try algebraStore(ctx, .diff);
}

/// SINTERCARD numkeys key [key ...] [LIMIT limit]
pub fn sintercard(ctx: *Ctx) Error!void {
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
    var out: std.StringArrayHashMapUnmanaged(void) = .empty;
    defer out.deinit(ctx.gpa);
    if (!try compute(ctx, .inter, ctx.args[2 .. 2 + nk], &out)) return;
    const n = out.count();
    try ctx.w.int(@intCast(if (limit > 0) @min(limit, n) else n));
}

pub fn sscan(ctx: *Ctx) Error!void {
    const cursor = (try keys_cmds.parseCursor(ctx, ctx.args[2])) orelse return;
    const opts = (try keys_cmds.parseScanOptions(ctx, 3, false)) orelse return;
    const s = switch (setFor(ctx, ctx.args[1], false)) {
        .wrong_type => return ctx.wrongType(),
        .missing => {
            try ctx.w.array(2);
            try ctx.w.bulk("0");
            return ctx.w.array(0);
        },
        .found => |s| s,
    };
    var positions: std.ArrayList(usize) = .empty;
    defer positions.deinit(ctx.gpa);
    const next = try hashes.scanArrayMap(s.count(), cursor, opts.count, &positions, ctx.gpa);
    var matched: std.ArrayList([]const u8) = .empty;
    defer matched.deinit(ctx.gpa);
    for (positions.items) |p| {
        const m = s.keys()[p];
        if (opts.pattern) |pat| if (!glob.match(pat, m)) continue;
        try matched.append(ctx.gpa, m);
    }
    try ctx.w.array(2);
    try ctx.w.bulkInt(@intCast(next));
    try ctx.w.array(matched.items.len);
    for (matched.items) |m| try ctx.w.bulk(m);
}
