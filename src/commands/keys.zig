//! Generic keyspace commands: deletion, TTLs, iteration and renaming.

const std = @import("std");
const num = @import("../num.zig");
const glob = @import("../glob.zig");
const ctx_mod = @import("ctx.zig");
const Ctx = ctx_mod.Ctx;
const Error = ctx_mod.Error;
const Kind = ctx_mod.Kind;
const msg = ctx_mod.msg;

pub fn del(ctx: *Ctx) Error!void {
    var n: i64 = 0;
    const d = ctx.db();
    for (ctx.args[1..]) |key| {
        _ = d.expireIfNeeded(key);
        if (d.delete(key)) {
            ctx.modified(key);
            n += 1;
        }
    }
    try ctx.w.int(n);
}

pub fn exists(ctx: *Ctx) Error!void {
    var n: i64 = 0;
    for (ctx.args[1..]) |key| {
        if (ctx.db().exists(key)) n += 1;
    }
    try ctx.w.int(n);
}

pub fn touch(ctx: *Ctx) Error!void {
    try exists(ctx);
}

pub fn @"type"(ctx: *Ctx) Error!void {
    const v = ctx.db().lookupRead(ctx.args[1]) orelse return ctx.w.simple("none");
    try ctx.w.simple(v.kind().name());
}

const ExpireUnit = enum { seconds, millis };

/// Shared implementation of EXPIRE, PEXPIRE, EXPIREAT and PEXPIREAT with
/// the NX/XX/GT/LT conditions added in Redis 7.
fn expireGeneric(ctx: *Ctx, unit: ExpireUnit, absolute: bool) Error!void {
    const key = ctx.args[1];
    var nx = false;
    var xx = false;
    var gt = false;
    var lt = false;
    for (ctx.args[3..]) |a| {
        if (Ctx.is(a, "nx")) nx = true else if (Ctx.is(a, "xx")) xx = true else if (Ctx.is(a, "gt")) gt = true else if (Ctx.is(a, "lt")) lt = true else {
            return ctx.w.errFmt("ERR Unsupported option {s}", .{a});
        }
    }
    if (nx and (xx or gt or lt)) return ctx.w.err("ERR NX and XX, GT or LT options at the same time are not compatible");
    if (gt and lt) return ctx.w.err("ERR GT and LT options at the same time are not compatible");

    const raw = (try ctx.int(ctx.args[2])) orelse return;
    var when = raw;
    var lower_buf: [16]u8 = undefined;
    const cmd_name = std.ascii.lowerString(&lower_buf, ctx.args[0][0..@min(ctx.args[0].len, 16)]);
    if (unit == .seconds) when = std.math.mul(i64, raw, 1000) catch {
        return ctx.w.errFmt("ERR invalid expire time in '{s}' command", .{cmd_name});
    };
    if (!absolute) when = std.math.add(i64, when, ctx.now()) catch {
        return ctx.w.errFmt("ERR invalid expire time in '{s}' command", .{cmd_name});
    };

    const d = ctx.db();
    if (!d.exists(key)) return ctx.w.int(0);
    const current = d.getExpire(key);
    if (nx and current != null) return ctx.w.int(0);
    if (xx and current == null) return ctx.w.int(0);
    if (gt) {
        // A key without TTL has an infinite TTL, so GT can never succeed.
        const cur = current orelse return ctx.w.int(0);
        if (when <= cur) return ctx.w.int(0);
    }
    if (lt) {
        if (current) |cur| if (when >= cur) return ctx.w.int(0);
    }

    if (when <= ctx.now() and !ctx.server.loading) {
        // A TTL in the past deletes the key right away.
        _ = d.delete(key);
        ctx.modified(key);
        try ctx.propagate(&.{ "DEL", key });
        return ctx.w.int(1);
    }
    try d.setExpire(key, when);
    ctx.modified(key);
    var tbuf: [24]u8 = undefined;
    try ctx.propagate(&.{ "PEXPIREAT", key, num.formatI64(&tbuf, when) });
    try ctx.w.int(1);
}

pub fn expire(ctx: *Ctx) Error!void {
    try expireGeneric(ctx, .seconds, false);
}

pub fn pexpire(ctx: *Ctx) Error!void {
    try expireGeneric(ctx, .millis, false);
}

pub fn expireat(ctx: *Ctx) Error!void {
    try expireGeneric(ctx, .seconds, true);
}

pub fn pexpireat(ctx: *Ctx) Error!void {
    try expireGeneric(ctx, .millis, true);
}

const TtlMode = enum { ttl_seconds, ttl_millis, abs_seconds, abs_millis };

fn ttlGeneric(ctx: *Ctx, mode: TtlMode) Error!void {
    const d = ctx.db();
    if (d.lookupRead(ctx.args[1]) == null) return ctx.w.int(-2);
    const when = d.getExpire(ctx.args[1]) orelse return ctx.w.int(-1);
    switch (mode) {
        .ttl_millis => try ctx.w.int(@max(0, when - ctx.now())),
        // Round to the nearest second like Redis.
        .ttl_seconds => try ctx.w.int(@divTrunc(@max(0, when - ctx.now()) + 500, 1000)),
        .abs_millis => try ctx.w.int(when),
        .abs_seconds => try ctx.w.int(@divTrunc(when, 1000)),
    }
}

pub fn ttl(ctx: *Ctx) Error!void {
    try ttlGeneric(ctx, .ttl_seconds);
}

pub fn pttl(ctx: *Ctx) Error!void {
    try ttlGeneric(ctx, .ttl_millis);
}

pub fn expiretime(ctx: *Ctx) Error!void {
    try ttlGeneric(ctx, .abs_seconds);
}

pub fn pexpiretime(ctx: *Ctx) Error!void {
    try ttlGeneric(ctx, .abs_millis);
}

pub fn persist(ctx: *Ctx) Error!void {
    const d = ctx.db();
    if (!d.exists(ctx.args[1])) return ctx.w.int(0);
    if (!d.persist(ctx.args[1])) return ctx.w.int(0);
    ctx.modified(ctx.args[1]);
    try ctx.w.int(1);
}

pub fn keys(ctx: *Ctx) Error!void {
    const d = ctx.db();
    const pattern = ctx.args[1];
    const match_all = std.mem.eql(u8, pattern, "*");
    var matches: std.ArrayList([]const u8) = .empty;
    defer matches.deinit(ctx.gpa);
    for (d.dict.keys()) |k| {
        if (!match_all and !glob.match(pattern, k)) continue;
        if (d.getExpire(k)) |when| if (when <= ctx.now()) continue;
        try matches.append(ctx.gpa, k);
    }
    try ctx.w.array(matches.items.len);
    for (matches.items) |k| try ctx.w.bulk(k);
}

pub const ScanOptions = struct {
    count: usize = 10,
    pattern: ?[]const u8 = null,
    type_filter: ?Kind = null,
    /// TYPE named something that is not a type: Redis 7.2 then simply
    /// matches nothing instead of failing.
    unknown_type: bool = false,
    novalues: bool = false,
};

/// Parses `[MATCH pattern] [COUNT n] [TYPE t]` starting at `start`.
/// Writes an error and returns null on failure.
pub fn parseScanOptions(ctx: *Ctx, start: usize, allow_type: bool) Error!?ScanOptions {
    var opts: ScanOptions = .{};
    var i = start;
    while (i < ctx.args.len) : (i += 1) {
        const a = ctx.args[i];
        const has_value = i + 1 < ctx.args.len;
        if (Ctx.is(a, "count") and has_value) {
            const v = (try ctx.int(ctx.args[i + 1])) orelse return null;
            if (v < 1) {
                try ctx.syntaxError();
                return null;
            }
            opts.count = @intCast(v);
            i += 1;
        } else if (Ctx.is(a, "match") and has_value) {
            opts.pattern = if (std.mem.eql(u8, ctx.args[i + 1], "*")) null else ctx.args[i + 1];
            i += 1;
        } else if (allow_type and Ctx.is(a, "type") and has_value) {
            var lower: [16]u8 = undefined;
            const t = ctx.args[i + 1];
            const name = std.ascii.lowerString(&lower, t[0..@min(t.len, 16)]);
            opts.type_filter = std.meta.stringToEnum(Kind, name);
            opts.unknown_type = opts.type_filter == null;
            i += 1;
        } else if (!allow_type and Ctx.is(a, "novalues")) {
            opts.novalues = true;
        } else {
            try ctx.syntaxError();
            return null;
        }
    }
    return opts;
}

pub fn parseCursor(ctx: *Ctx, s: []const u8) Error!?u64 {
    return std.fmt.parseInt(u64, s, 10) catch {
        try ctx.w.err("ERR invalid cursor");
        return null;
    };
}

pub fn scan(ctx: *Ctx) Error!void {
    const cursor = (try parseCursor(ctx, ctx.args[1])) orelse return;
    const opts = (try parseScanOptions(ctx, 2, true)) orelse return;
    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(ctx.gpa);
    const next = try ctx.db().scan(ctx.gpa, cursor, opts.count, opts.pattern, opts.type_filter, &out);
    if (opts.unknown_type) out.clearRetainingCapacity();
    try ctx.w.array(2);
    try ctx.w.bulkInt(@intCast(next));
    try ctx.w.array(out.items.len);
    for (out.items) |k| try ctx.w.bulk(k);
}

pub fn randomkey(ctx: *Ctx) Error!void {
    const k = ctx.db().randomKey() orelse return ctx.w.nullBulk();
    try ctx.w.bulk(k);
}

fn renameGeneric(ctx: *Ctx, nx: bool) Error!void {
    const src = ctx.args[1];
    const dst = ctx.args[2];
    const d = ctx.db();
    if (!d.exists(src)) return ctx.w.err(msg.no_such_key);
    if (std.mem.eql(u8, src, dst)) {
        return if (nx) ctx.w.int(0) else ctx.w.ok();
    }
    if (nx and d.exists(dst)) return ctx.w.int(0);
    const ttl_ms = d.getExpire(src);
    var v = d.take(src).?;
    errdefer v.deinit(ctx.gpa);
    _ = d.delete(dst);
    _ = try d.add(dst, v);
    if (ttl_ms) |when| try d.setExpire(dst, when);
    ctx.modified(src);
    ctx.modified(dst);
    if (nx) try ctx.w.int(1) else try ctx.w.ok();
}

pub fn rename(ctx: *Ctx) Error!void {
    try renameGeneric(ctx, false);
}

pub fn renamenx(ctx: *Ctx) Error!void {
    try renameGeneric(ctx, true);
}

fn parseDbIndex(ctx: *Ctx, s: []const u8) Error!?usize {
    const idx = num.parseI64(s) orelse {
        try ctx.w.err(msg.not_integer);
        return null;
    };
    if (idx < 0 or idx >= ctx.server.dbs.len) {
        try ctx.w.err("ERR DB index is out of range");
        return null;
    }
    return @intCast(idx);
}

pub fn move(ctx: *Ctx) Error!void {
    const key = ctx.args[1];
    const target = (try parseDbIndex(ctx, ctx.args[2])) orelse return;
    if (target == ctx.client.db) return ctx.w.err("ERR source and destination objects are the same");
    const src = ctx.db();
    if (!src.exists(key)) return ctx.w.int(0);
    const dst = &ctx.server.dbs[target];
    if (dst.exists(key)) return ctx.w.int(0);
    const ttl_ms = src.getExpire(key);
    var v = src.take(key).?;
    errdefer v.deinit(ctx.gpa);
    _ = try dst.add(key, v);
    if (ttl_ms) |when| try dst.setExpire(key, when);
    ctx.modified(key);
    ctx.modifiedIn(target, key);
    try ctx.w.int(1);
}

/// COPY source destination [DB index] [REPLACE]
pub fn copy(ctx: *Ctx) Error!void {
    const src_key = ctx.args[1];
    const dst_key = ctx.args[2];
    var target = ctx.client.db;
    var replace = false;
    var i: usize = 3;
    while (i < ctx.args.len) : (i += 1) {
        if (Ctx.is(ctx.args[i], "replace")) {
            replace = true;
        } else if (Ctx.is(ctx.args[i], "db") and i + 1 < ctx.args.len) {
            target = (try parseDbIndex(ctx, ctx.args[i + 1])) orelse return;
            i += 1;
        } else return ctx.syntaxError();
    }
    if (target == ctx.client.db and std.mem.eql(u8, src_key, dst_key)) {
        return ctx.w.err("ERR source and destination objects are the same");
    }
    const src = ctx.db();
    const v = src.lookupRead(src_key) orelse return ctx.w.int(0);
    const dst = &ctx.server.dbs[target];
    const dst_exists = dst.exists(dst_key);
    if (dst_exists and !replace) return ctx.w.int(0);
    // Clone and read the TTL before touching the destination: deleting a key
    // swap-removes it from the dictionary, which can move the source entry
    // and invalidate `v`.
    const when = src.getExpire(src_key);
    var copy_v = try v.clone(ctx.gpa, ctx.server.randomSeed());
    errdefer copy_v.deinit(ctx.gpa);
    if (dst_exists) _ = dst.delete(dst_key);
    _ = try dst.add(dst_key, copy_v);
    if (when) |w| try dst.setExpire(dst_key, w);
    ctx.modifiedIn(target, dst_key);
    try ctx.w.int(1);
}

/// OBJECT ENCODING|FREQ|IDLETIME|REFCOUNT|HELP key
pub fn object(ctx: *Ctx) Error!void {
    const sub = ctx.args[1];
    if (Ctx.is(sub, "help")) {
        const lines = [_][]const u8{
            "OBJECT <subcommand> [<arg> [value] [opt] ...]. Subcommands are:",
            "ENCODING <key>",
            "    Return the kind of internal representation used in order to store the value",
            "    associated with a <key>.",
            "REFCOUNT <key>",
            "    Return the number of references of the value associated with the specified",
            "    <key>.",
            "HELP",
            "    Print this help.",
        };
        try ctx.w.array(lines.len);
        for (lines) |l| try ctx.w.simple(l);
        return;
    }
    if (ctx.args.len != 3) return ctx.w.errFmt("ERR unknown subcommand or wrong number of arguments for '{s}'. Try OBJECT HELP.", .{sub});
    const v = ctx.db().lookupRead(ctx.args[2]) orelse return ctx.w.nullBulk();
    if (Ctx.is(sub, "encoding")) {
        const enc: []const u8 = switch (v.*) {
            .string => |s| if (num.parseI64(s) != null) "int" else if (s.len <= 44) "embstr" else "raw",
            .list => "quicklist",
            .hash => "hashtable",
            .set => "hashtable",
            .zset => "skiplist",
        };
        try ctx.w.bulk(enc);
    } else if (Ctx.is(sub, "refcount")) {
        try ctx.w.int(1);
    } else {
        try ctx.w.errFmt("ERR unknown subcommand or wrong number of arguments for '{s}'. Try OBJECT HELP.", .{sub});
    }
}
