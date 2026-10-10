//! List commands, including the blocking variants.

const std = @import("std");
const num = @import("../num.zig");
const ctx_mod = @import("ctx.zig");
const client_mod = @import("../server/client.zig");
const List = @import("../ds/list.zig").List;
const Ctx = ctx_mod.Ctx;
const Error = ctx_mod.Error;
const msg = ctx_mod.msg;
const End = client_mod.End;

fn listFor(ctx: *Ctx, key: []const u8, for_write: bool) union(enum) { missing, wrong_type, found: *List } {
    return switch (ctx.lookup(key, .list, for_write)) {
        .missing => .missing,
        .wrong_type => .wrong_type,
        .found => |v| .{ .found = &v.list },
    };
}

/// Removes the key if its list became empty.
fn dropIfEmpty(ctx: *Ctx, key: []const u8, l: *List) void {
    if (l.len == 0) _ = ctx.db().delete(key);
}

fn pushGeneric(ctx: *Ctx, end: End, only_if_exists: bool) Error!void {
    const key = ctx.args[1];
    const d = ctx.db();
    const l = switch (listFor(ctx, key, true)) {
        .wrong_type => return ctx.wrongType(),
        .found => |l| l,
        .missing => blk: {
            if (only_if_exists) return ctx.w.int(0);
            const v = try d.add(key, .{ .list = .empty });
            break :blk &v.list;
        },
    };
    for (ctx.args[2..]) |item| {
        if (end == .left) try l.pushFront(ctx.gpa, item) else try l.pushBack(ctx.gpa, item);
    }
    ctx.modified(key);
    try ctx.signalReady(key);
    try ctx.w.int(@intCast(l.len));
}

pub fn lpush(ctx: *Ctx) Error!void {
    try pushGeneric(ctx, .left, false);
}

pub fn rpush(ctx: *Ctx) Error!void {
    try pushGeneric(ctx, .right, false);
}

pub fn lpushx(ctx: *Ctx) Error!void {
    try pushGeneric(ctx, .left, true);
}

pub fn rpushx(ctx: *Ctx) Error!void {
    try pushGeneric(ctx, .right, true);
}

fn popGeneric(ctx: *Ctx, end: End) Error!void {
    const key = ctx.args[1];
    if (ctx.args.len > 3) return ctx.syntaxError();
    var count: ?usize = null;
    if (ctx.args.len == 3) {
        const v = (try ctx.int(ctx.args[2])) orelse return;
        if (v < 0) return ctx.w.err(msg.positive);
        count = @intCast(v);
    }
    const l = switch (listFor(ctx, key, true)) {
        .wrong_type => return ctx.wrongType(),
        .missing => return if (count != null) ctx.w.nullArray() else ctx.w.nullBulk(),
        .found => |l| l,
    };
    if (count) |n| {
        const take = @min(n, l.len);
        try ctx.w.array(take);
        var i: usize = 0;
        while (i < take) : (i += 1) {
            const item = (if (end == .left) l.popFront(ctx.gpa) else l.popBack(ctx.gpa)).?;
            defer ctx.gpa.free(item);
            try ctx.w.bulk(item);
        }
        if (take > 0) ctx.modified(key);
    } else {
        const item = (if (end == .left) l.popFront(ctx.gpa) else l.popBack(ctx.gpa)).?;
        defer ctx.gpa.free(item);
        try ctx.w.bulk(item);
        ctx.modified(key);
    }
    dropIfEmpty(ctx, key, l);
}

pub fn lpop(ctx: *Ctx) Error!void {
    try popGeneric(ctx, .left);
}

pub fn rpop(ctx: *Ctx) Error!void {
    try popGeneric(ctx, .right);
}

pub fn llen(ctx: *Ctx) Error!void {
    switch (listFor(ctx, ctx.args[1], false)) {
        .wrong_type => try ctx.wrongType(),
        .missing => try ctx.w.int(0),
        .found => |l| try ctx.w.int(@intCast(l.len)),
    }
}

pub fn lindex(ctx: *Ctx) Error!void {
    const index = (try ctx.int(ctx.args[2])) orelse return;
    const l = switch (listFor(ctx, ctx.args[1], false)) {
        .wrong_type => return ctx.wrongType(),
        .missing => return ctx.w.nullBulk(),
        .found => |l| l,
    };
    const i = l.resolveIndex(index) orelse return ctx.w.nullBulk();
    try ctx.w.bulk(l.get(i));
}

pub fn lset(ctx: *Ctx) Error!void {
    const index = (try ctx.int(ctx.args[2])) orelse return;
    const l = switch (listFor(ctx, ctx.args[1], true)) {
        .wrong_type => return ctx.wrongType(),
        .missing => return ctx.w.err(msg.no_such_key),
        .found => |l| l,
    };
    const i = l.resolveIndex(index) orelse return ctx.w.err(msg.out_of_range);
    try l.set(ctx.gpa, i, ctx.args[3]);
    ctx.modified(ctx.args[1]);
    try ctx.w.ok();
}

pub fn lrange(ctx: *Ctx) Error!void {
    const start = (try ctx.int(ctx.args[2])) orelse return;
    const end = (try ctx.int(ctx.args[3])) orelse return;
    const l = switch (listFor(ctx, ctx.args[1], false)) {
        .wrong_type => return ctx.wrongType(),
        .missing => return ctx.w.array(0),
        .found => |l| l,
    };
    const r = num.normalizeRange(start, end, l.len) orelse return ctx.w.array(0);
    try ctx.w.array(r.end - r.start + 1);
    var i = r.start;
    while (i <= r.end) : (i += 1) try ctx.w.bulk(l.get(i));
}

pub fn ltrim(ctx: *Ctx) Error!void {
    const key = ctx.args[1];
    const start = (try ctx.int(ctx.args[2])) orelse return;
    const end = (try ctx.int(ctx.args[3])) orelse return;
    const l = switch (listFor(ctx, key, true)) {
        .wrong_type => return ctx.wrongType(),
        .missing => return ctx.w.ok(),
        .found => |l| l,
    };
    if (num.normalizeRange(start, end, l.len)) |r| {
        l.retainRange(ctx.gpa, r.start, r.end);
    } else {
        l.clear(ctx.gpa);
    }
    ctx.modified(key);
    dropIfEmpty(ctx, key, l);
    try ctx.w.ok();
}

pub fn lrem(ctx: *Ctx) Error!void {
    const key = ctx.args[1];
    const count = (try ctx.int(ctx.args[2])) orelse return;
    const l = switch (listFor(ctx, key, true)) {
        .wrong_type => return ctx.wrongType(),
        .missing => return ctx.w.int(0),
        .found => |l| l,
    };
    const removed = l.removeMatching(ctx.gpa, ctx.args[3], count);
    if (removed > 0) ctx.modified(key);
    dropIfEmpty(ctx, key, l);
    try ctx.w.int(@intCast(removed));
}

pub fn linsert(ctx: *Ctx) Error!void {
    const key = ctx.args[1];
    const after = if (Ctx.is(ctx.args[2], "after")) true else if (Ctx.is(ctx.args[2], "before")) false else return ctx.syntaxError();
    const l = switch (listFor(ctx, key, true)) {
        .wrong_type => return ctx.wrongType(),
        .missing => return ctx.w.int(0),
        .found => |l| l,
    };
    var i: usize = 0;
    while (i < l.len) : (i += 1) {
        if (std.mem.eql(u8, l.get(i), ctx.args[3])) break;
    } else return ctx.w.int(-1);
    try l.insertAt(ctx.gpa, if (after) i + 1 else i, ctx.args[4]);
    ctx.modified(key);
    try ctx.signalReady(key);
    try ctx.w.int(@intCast(l.len));
}

/// LPOS key element [RANK rank] [COUNT num-matches] [MAXLEN len]
pub fn lpos(ctx: *Ctx) Error!void {
    var rank: i64 = 1;
    var count: ?i64 = null;
    var maxlen: i64 = 0;
    var i: usize = 3;
    while (i < ctx.args.len) : (i += 2) {
        if (i + 1 >= ctx.args.len) return ctx.syntaxError();
        const opt = ctx.args[i];
        const v = (try ctx.int(ctx.args[i + 1])) orelse return;
        if (Ctx.is(opt, "rank")) {
            if (v == 0) return ctx.w.err("ERR RANK can't be zero: use 1 to start from the first match, 2 from the second ... or use negative to start from the end of the list");
            if (v == std.math.minInt(i64)) return ctx.w.err("ERR value is out of range, value must between -9223372036854775807 and 9223372036854775807");
            rank = v;
        } else if (Ctx.is(opt, "count")) {
            if (v < 0) return ctx.w.err("ERR COUNT can't be negative");
            count = v;
        } else if (Ctx.is(opt, "maxlen")) {
            if (v < 0) return ctx.w.err("ERR MAXLEN can't be negative");
            maxlen = v;
        } else return ctx.syntaxError();
    }
    const l = switch (listFor(ctx, ctx.args[1], false)) {
        .wrong_type => return ctx.wrongType(),
        .missing => return if (count != null) ctx.w.array(0) else ctx.w.nullBulk(),
        .found => |l| l,
    };
    const want: usize = if (count) |c| (if (c == 0) std.math.maxInt(usize) else @intCast(c)) else 1;
    var skip: u64 = @abs(rank) - 1;
    var found: std.ArrayList(i64) = .empty;
    defer found.deinit(ctx.gpa);
    var scanned: usize = 0;
    const limit: usize = if (maxlen == 0) l.len else @min(l.len, @as(usize, @intCast(maxlen)));
    while (scanned < limit and found.items.len < want) : (scanned += 1) {
        const idx = if (rank > 0) scanned else l.len - 1 - scanned;
        if (!std.mem.eql(u8, l.get(idx), ctx.args[2])) continue;
        if (skip > 0) {
            skip -= 1;
            continue;
        }
        try found.append(ctx.gpa, @intCast(idx));
    }
    if (count == null) {
        if (found.items.len == 0) return ctx.w.nullBulk();
        return ctx.w.int(found.items[0]);
    }
    try ctx.w.array(found.items.len);
    for (found.items) |p| try ctx.w.int(p);
}

fn parseEnd(s: []const u8) ?End {
    if (Ctx.is(s, "left")) return .left;
    if (Ctx.is(s, "right")) return .right;
    return null;
}

/// Moves one element between lists. Returns false (after replying) when
/// the source is missing so callers can decide whether to block.
fn moveGeneric(ctx: *Ctx, src_key: []const u8, dst_key: []const u8, from: End, to: End) Error!bool {
    const d = ctx.db();
    const src = switch (listFor(ctx, src_key, true)) {
        .wrong_type => {
            try ctx.wrongType();
            return true;
        },
        .missing => return false,
        .found => |l| l,
    };
    if (d.lookupWrite(dst_key)) |dv| {
        if (dv.kind() != .list) {
            try ctx.wrongType();
            return true;
        }
    }
    const item = (if (from == .left) src.popFront(ctx.gpa) else src.popBack(ctx.gpa)).?;
    defer ctx.gpa.free(item);
    dropIfEmpty(ctx, src_key, src);
    const dst = switch (listFor(ctx, dst_key, true)) {
        .found => |l| l,
        else => &(try d.add(dst_key, .{ .list = .empty })).list,
    };
    if (to == .left) try dst.pushFront(ctx.gpa, item) else try dst.pushBack(ctx.gpa, item);
    ctx.modified(src_key);
    ctx.modified(dst_key);
    try ctx.signalReady(dst_key);
    try ctx.w.bulk(item);
    try ctx.propagate(&.{ "LMOVE", src_key, dst_key, if (from == .left) "LEFT" else "RIGHT", if (to == .left) "LEFT" else "RIGHT" });
    return true;
}

pub fn lmove(ctx: *Ctx) Error!void {
    const from = parseEnd(ctx.args[3]) orelse return ctx.syntaxError();
    const to = parseEnd(ctx.args[4]) orelse return ctx.syntaxError();
    if (!try moveGeneric(ctx, ctx.args[1], ctx.args[2], from, to)) try ctx.w.nullBulk();
}

pub fn rpoplpush(ctx: *Ctx) Error!void {
    if (!try moveGeneric(ctx, ctx.args[1], ctx.args[2], .right, .left)) try ctx.w.nullBulk();
}

fn blockingPop(ctx: *Ctx, end: End) Error!void {
    const keys = ctx.args[1 .. ctx.args.len - 1];
    const deadline = (try ctx.timeoutDeadline(ctx.args[ctx.args.len - 1])) orelse return;
    for (keys) |key| {
        switch (listFor(ctx, key, true)) {
            .wrong_type => return ctx.wrongType(),
            .missing => continue,
            .found => |l| {
                const item = (if (end == .left) l.popFront(ctx.gpa) else l.popBack(ctx.gpa)).?;
                defer ctx.gpa.free(item);
                try ctx.w.array(2);
                try ctx.w.bulk(key);
                try ctx.w.bulk(item);
                ctx.modified(key);
                try ctx.propagate(&.{ if (end == .left) "LPOP" else "RPOP", key });
                dropIfEmpty(ctx, key, l);
                return;
            },
        }
    }
    // Inside MULTI a blocking pop behaves like its non-blocking variant.
    if (ctx.client.in_exec or ctx.client.isFake()) return ctx.w.nullArray();
    try ctx.server.blockClient(ctx.client, keys, deadline, .{ .pop = end });
}

pub fn blpop(ctx: *Ctx) Error!void {
    try blockingPop(ctx, .left);
}

pub fn brpop(ctx: *Ctx) Error!void {
    try blockingPop(ctx, .right);
}

fn blockingMove(ctx: *Ctx, src: []const u8, dst: []const u8, from: End, to: End, timeout_arg: []const u8) Error!void {
    const deadline = (try ctx.timeoutDeadline(timeout_arg)) orelse return;
    if (try moveGeneric(ctx, src, dst, from, to)) return;
    if (ctx.client.in_exec or ctx.client.isFake()) return ctx.w.nullBulk();
    const dest_copy = try ctx.gpa.dupe(u8, dst);
    errdefer ctx.gpa.free(dest_copy);
    try ctx.server.blockClient(ctx.client, &.{src}, deadline, .{ .move = .{ .from = from, .to = to, .dest = dest_copy } });
}

pub fn blmove(ctx: *Ctx) Error!void {
    const from = parseEnd(ctx.args[3]) orelse return ctx.syntaxError();
    const to = parseEnd(ctx.args[4]) orelse return ctx.syntaxError();
    try blockingMove(ctx, ctx.args[1], ctx.args[2], from, to, ctx.args[5]);
}

pub fn brpoplpush(ctx: *Ctx) Error!void {
    try blockingMove(ctx, ctx.args[1], ctx.args[2], .right, .left, ctx.args[3]);
}
