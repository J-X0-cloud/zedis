//! String commands.

const std = @import("std");
const num = @import("../num.zig");
const ctx_mod = @import("ctx.zig");
const Ctx = ctx_mod.Ctx;
const Error = ctx_mod.Error;
const Value = ctx_mod.Value;
const msg = ctx_mod.msg;

/// proto-max-bulk-len: the largest string a command may create.
pub const max_string_len = 512 * 1024 * 1024;

const StringLookup = union(enum) {
    missing,
    wrong_type,
    found: []u8,
};

fn readString(ctx: *Ctx, key: []const u8) StringLookup {
    return switch (ctx.lookup(key, .string, false)) {
        .missing => .missing,
        .wrong_type => .wrong_type,
        .found => |v| .{ .found = v.string },
    };
}

/// Stores a copy of `bytes` under `key`, replacing any value.
fn storeString(ctx: *Ctx, key: []const u8, bytes: []const u8, keep_ttl: bool) Error!void {
    var v = try Value.initString(ctx.gpa, bytes);
    errdefer v.deinit(ctx.gpa);
    try ctx.db().set(key, v, .{ .keep_ttl = keep_ttl });
    ctx.modified(key);
}

pub fn get(ctx: *Ctx) Error!void {
    switch (readString(ctx, ctx.args[1])) {
        .missing => try ctx.w.nullBulk(),
        .wrong_type => try ctx.wrongType(),
        .found => |s| try ctx.w.bulk(s),
    }
}

const Expiry = union(enum) {
    none,
    keep,
    persist,
    /// Absolute deadline in ms.
    at: i64,
};

/// Parses EX/PX/EXAT/PXAT values into an absolute ms deadline, writing
/// "invalid expire time" for non-positive or overflowing values.
fn parseExpiry(ctx: *Ctx, unit: []const u8, arg: []const u8, cmd_name: []const u8) Error!?i64 {
    const v = (try ctx.int(arg)) orelse return null;
    const absolute = Ctx.is(unit, "exat") or Ctx.is(unit, "pxat");
    const seconds = Ctx.is(unit, "ex") or Ctx.is(unit, "exat");
    if (v <= 0) {
        try ctx.w.errFmt("ERR invalid expire time in '{s}' command", .{cmd_name});
        return null;
    }
    var ms = v;
    if (seconds) ms = std.math.mul(i64, v, 1000) catch {
        try ctx.w.errFmt("ERR invalid expire time in '{s}' command", .{cmd_name});
        return null;
    };
    if (!absolute) ms = std.math.add(i64, ms, ctx.now()) catch {
        try ctx.w.errFmt("ERR invalid expire time in '{s}' command", .{cmd_name});
        return null;
    };
    return ms;
}

/// SET key value [NX|XX] [GET] [EX s|PX ms|EXAT ts|PXAT ts|KEEPTTL]
pub fn set(ctx: *Ctx) Error!void {
    const key = ctx.args[1];
    const val = ctx.args[2];
    var nx = false;
    var xx = false;
    var want_get = false;
    var expiry: Expiry = .none;
    var i: usize = 3;
    while (i < ctx.args.len) : (i += 1) {
        const a = ctx.args[i];
        if (Ctx.is(a, "nx") and !xx) {
            nx = true;
        } else if (Ctx.is(a, "xx") and !nx) {
            xx = true;
        } else if (Ctx.is(a, "get")) {
            want_get = true;
        } else if (Ctx.is(a, "keepttl") and expiry == .none) {
            expiry = .keep;
        } else if ((Ctx.is(a, "ex") or Ctx.is(a, "px") or Ctx.is(a, "exat") or Ctx.is(a, "pxat")) and expiry == .none and i + 1 < ctx.args.len) {
            const when = (try parseExpiry(ctx, a, ctx.args[i + 1], "set")) orelse return;
            expiry = .{ .at = when };
            i += 1;
        } else {
            return ctx.syntaxError();
        }
    }

    const d = ctx.db();
    const existing = d.lookupWrite(key);
    if (want_get) {
        if (existing) |v| if (v.kind() != .string) return ctx.wrongType();
    }
    // Reply with the old value before it is replaced.
    if (want_get) {
        if (existing) |v| try ctx.w.bulk(v.string) else try ctx.w.nullBulk();
    }
    if ((nx and existing != null) or (xx and existing == null)) {
        if (!want_get) try ctx.w.nullBulk();
        ctx.noPropagation();
        return;
    }
    try storeString(ctx, key, val, expiry == .keep);
    switch (expiry) {
        .at => |when| {
            try d.setExpire(key, when);
            var tbuf: [24]u8 = undefined;
            try ctx.propagate(&.{ "SET", key, val, "PXAT", num.formatI64(&tbuf, when) });
        },
        .keep => try ctx.propagate(&.{ "SET", key, val, "KEEPTTL" }),
        else => try ctx.propagate(&.{ "SET", key, val }),
    }
    if (!want_get) try ctx.w.ok();
}

pub fn setnx(ctx: *Ctx) Error!void {
    const d = ctx.db();
    if (d.exists(ctx.args[1])) return ctx.w.int(0);
    try storeString(ctx, ctx.args[1], ctx.args[2], false);
    try ctx.w.int(1);
}

fn setWithTtl(ctx: *Ctx, unit: []const u8, name: []const u8) Error!void {
    const key = ctx.args[1];
    const when = (try parseExpiry(ctx, unit, ctx.args[2], name)) orelse return;
    try storeString(ctx, key, ctx.args[3], false);
    try ctx.db().setExpire(key, when);
    var tbuf: [24]u8 = undefined;
    try ctx.propagate(&.{ "SET", key, ctx.args[3], "PXAT", num.formatI64(&tbuf, when) });
    try ctx.w.ok();
}

pub fn setex(ctx: *Ctx) Error!void {
    try setWithTtl(ctx, "ex", "setex");
}

pub fn psetex(ctx: *Ctx) Error!void {
    try setWithTtl(ctx, "px", "psetex");
}

pub fn getset(ctx: *Ctx) Error!void {
    const key = ctx.args[1];
    switch (readString(ctx, key)) {
        .wrong_type => return ctx.wrongType(),
        .missing => try ctx.w.nullBulk(),
        .found => |s| try ctx.w.bulk(s),
    }
    try storeString(ctx, key, ctx.args[2], false);
    try ctx.propagate(&.{ "SET", key, ctx.args[2] });
}

pub fn getdel(ctx: *Ctx) Error!void {
    const key = ctx.args[1];
    switch (readString(ctx, key)) {
        .wrong_type => return ctx.wrongType(),
        .missing => return ctx.w.nullBulk(),
        .found => |s| try ctx.w.bulk(s),
    }
    _ = ctx.db().delete(key);
    ctx.modified(key);
    try ctx.propagate(&.{ "DEL", key });
}

/// GETEX key [EX s|PX ms|EXAT ts|PXAT ts|PERSIST]
pub fn getex(ctx: *Ctx) Error!void {
    const key = ctx.args[1];
    var expiry: Expiry = .none;
    var i: usize = 2;
    while (i < ctx.args.len) : (i += 1) {
        const a = ctx.args[i];
        if (Ctx.is(a, "persist") and expiry == .none) {
            expiry = .persist;
        } else if ((Ctx.is(a, "ex") or Ctx.is(a, "px") or Ctx.is(a, "exat") or Ctx.is(a, "pxat")) and expiry == .none and i + 1 < ctx.args.len) {
            const when = (try parseExpiry(ctx, a, ctx.args[i + 1], "getex")) orelse return;
            expiry = .{ .at = when };
            i += 1;
        } else {
            return ctx.syntaxError();
        }
    }
    switch (readString(ctx, key)) {
        .wrong_type => return ctx.wrongType(),
        .missing => return ctx.w.nullBulk(),
        .found => |s| try ctx.w.bulk(s),
    }
    const d = ctx.db();
    switch (expiry) {
        .at => |when| {
            try d.setExpire(key, when);
            ctx.modified(key);
            var tbuf: [24]u8 = undefined;
            try ctx.propagate(&.{ "PEXPIREAT", key, num.formatI64(&tbuf, when) });
        },
        .persist => {
            if (d.persist(key)) {
                ctx.modified(key);
                try ctx.propagate(&.{ "PERSIST", key });
            }
        },
        else => {},
    }
}

pub fn mget(ctx: *Ctx) Error!void {
    try ctx.w.array(ctx.args.len - 1);
    for (ctx.args[1..]) |key| {
        switch (readString(ctx, key)) {
            .found => |s| try ctx.w.bulk(s),
            else => try ctx.w.nullBulk(),
        }
    }
}

pub fn mset(ctx: *Ctx) Error!void {
    if (ctx.args.len % 2 != 1) return ctx.wrongArity();
    var i: usize = 1;
    while (i < ctx.args.len) : (i += 2) try storeString(ctx, ctx.args[i], ctx.args[i + 1], false);
    try ctx.w.ok();
}

pub fn msetnx(ctx: *Ctx) Error!void {
    if (ctx.args.len % 2 != 1) return ctx.wrongArity();
    var i: usize = 1;
    while (i < ctx.args.len) : (i += 2) {
        if (ctx.db().exists(ctx.args[i])) return ctx.w.int(0);
    }
    i = 1;
    while (i < ctx.args.len) : (i += 2) try storeString(ctx, ctx.args[i], ctx.args[i + 1], false);
    try ctx.w.int(1);
}

pub fn append(ctx: *Ctx) Error!void {
    const key = ctx.args[1];
    const d = ctx.db();
    const v = d.lookupWrite(key) orelse {
        try storeString(ctx, key, ctx.args[2], false);
        return ctx.w.int(@intCast(ctx.args[2].len));
    };
    if (v.kind() != .string) return ctx.wrongType();
    const new_len = v.string.len + ctx.args[2].len;
    if (new_len > max_string_len) return ctx.w.err("ERR string exceeds maximum allowed size (proto-max-bulk-len)");
    const grown = try ctx.gpa.realloc(v.string, new_len);
    @memcpy(grown[grown.len - ctx.args[2].len ..], ctx.args[2]);
    v.string = grown;
    ctx.modified(key);
    try ctx.w.int(@intCast(new_len));
}

pub fn strlen(ctx: *Ctx) Error!void {
    switch (readString(ctx, ctx.args[1])) {
        .wrong_type => try ctx.wrongType(),
        .missing => try ctx.w.int(0),
        .found => |s| try ctx.w.int(@intCast(s.len)),
    }
}

fn incrGeneric(ctx: *Ctx, delta: i64) Error!void {
    const key = ctx.args[1];
    var current: i64 = 0;
    const d = ctx.db();
    const existing = d.lookupWrite(key);
    if (existing) |v| {
        if (v.kind() != .string) return ctx.wrongType();
        current = num.parseI64(v.string) orelse return ctx.w.err(msg.not_integer);
    }
    const result = std.math.add(i64, current, delta) catch return ctx.w.err(msg.overflow);
    var buf: [24]u8 = undefined;
    const s = num.formatI64(&buf, result);
    if (existing) |v| {
        // Reuse the allocation when it is large enough.
        if (v.string.len == s.len) {
            @memcpy(v.string, s);
        } else {
            const ns = try ctx.gpa.dupe(u8, s);
            ctx.gpa.free(v.string);
            v.string = ns;
        }
        ctx.modified(key);
    } else {
        try storeString(ctx, key, s, false);
    }
    try ctx.w.int(result);
}

pub fn incr(ctx: *Ctx) Error!void {
    try incrGeneric(ctx, 1);
}

pub fn decr(ctx: *Ctx) Error!void {
    try incrGeneric(ctx, -1);
}

pub fn incrby(ctx: *Ctx) Error!void {
    const delta = (try ctx.int(ctx.args[2])) orelse return;
    try incrGeneric(ctx, delta);
}

pub fn decrby(ctx: *Ctx) Error!void {
    const delta = (try ctx.int(ctx.args[2])) orelse return;
    if (delta == std.math.minInt(i64)) return ctx.w.err("ERR decrement would overflow");
    try incrGeneric(ctx, -delta);
}

pub fn incrbyfloat(ctx: *Ctx) Error!void {
    const key = ctx.args[1];
    const incr_by = num.parseF80(ctx.args[2]) orelse return ctx.w.err(msg.not_float);
    var current: f80 = 0;
    const d = ctx.db();
    if (d.lookupWrite(key)) |v| {
        if (v.kind() != .string) return ctx.wrongType();
        current = num.parseF80(v.string) orelse return ctx.w.err(msg.not_float);
    }
    const result = current + incr_by;
    if (std.math.isNan(result) or std.math.isInf(result)) return ctx.w.err("ERR increment would produce NaN or Infinity");
    var buf: [num.max_human_chars]u8 = undefined;
    const s = num.formatHuman(&buf, result);
    try storeString(ctx, key, s, true);
    try ctx.propagate(&.{ "SET", key, s, "KEEPTTL" });
    try ctx.w.bulk(s);
}

pub fn getrange(ctx: *Ctx) Error!void {
    var start = (try ctx.int(ctx.args[2])) orelse return;
    var end = (try ctx.int(ctx.args[3])) orelse return;
    const s = switch (readString(ctx, ctx.args[1])) {
        .wrong_type => return ctx.wrongType(),
        .missing => return ctx.w.bulk(""),
        .found => |s| s,
    };
    if (start < 0 and end < 0 and start > end) return ctx.w.bulk("");
    const len: i64 = @intCast(s.len);
    if (start < 0) start = len + start;
    if (end < 0) end = len + end;
    if (start < 0) start = 0;
    if (end < 0) end = 0;
    if (end >= len) end = len - 1;
    if (start > end or len == 0) return ctx.w.bulk("");
    try ctx.w.bulk(s[@intCast(start)..@intCast(end + 1)]);
}

pub fn setrange(ctx: *Ctx) Error!void {
    const key = ctx.args[1];
    const offset = (try ctx.int(ctx.args[2])) orelse return;
    if (offset < 0) return ctx.w.err("ERR offset is out of range");
    const payload = ctx.args[3];
    const off: usize = @intCast(offset);
    const d = ctx.db();
    const existing = d.lookupWrite(key);
    if (existing) |v| if (v.kind() != .string) return ctx.wrongType();
    if (payload.len == 0) {
        const cur_len = if (existing) |v| v.string.len else 0;
        return ctx.w.int(@intCast(cur_len));
    }
    if (off + payload.len > max_string_len) return ctx.w.err("ERR string exceeds maximum allowed size (proto-max-bulk-len)");
    const v = existing orelse blk: {
        break :blk try d.add(key, .{ .string = try ctx.gpa.alloc(u8, 0) });
    };
    const needed = off + payload.len;
    if (v.string.len < needed) {
        const old_len = v.string.len;
        v.string = try ctx.gpa.realloc(v.string, needed);
        @memset(v.string[old_len..], 0);
    }
    @memcpy(v.string[off..][0..payload.len], payload);
    ctx.modified(key);
    try ctx.w.int(@intCast(v.string.len));
}

// ---------------------------------------------------------------- bits --

pub fn setbit(ctx: *Ctx) Error!void {
    const key = ctx.args[1];
    const offset = num.parseI64(ctx.args[2]) orelse return ctx.w.err("ERR bit offset is not an integer or out of range");
    if (offset < 0 or offset >= @as(i64, max_string_len) * 8) return ctx.w.err("ERR bit offset is not an integer or out of range");
    const bit = ctx.args[3];
    if (bit.len != 1 or (bit[0] != '0' and bit[0] != '1')) return ctx.w.err("ERR bit is not an integer or out of range");
    const d = ctx.db();
    const v = d.lookupWrite(key) orelse try d.add(key, .{ .string = try ctx.gpa.alloc(u8, 0) });
    if (v.kind() != .string) return ctx.wrongType();
    const byte: usize = @intCast(@divTrunc(offset, 8));
    if (v.string.len <= byte) {
        const old_len = v.string.len;
        v.string = try ctx.gpa.realloc(v.string, byte + 1);
        @memset(v.string[old_len..], 0);
    }
    const shift: u3 = @intCast(7 - @mod(offset, 8));
    const mask: u8 = @as(u8, 1) << shift;
    const old: u1 = @intCast((v.string[byte] & mask) >> shift);
    if (bit[0] == '1') v.string[byte] |= mask else v.string[byte] &= ~mask;
    ctx.modified(key);
    try ctx.w.int(old);
}

pub fn getbit(ctx: *Ctx) Error!void {
    const offset = num.parseI64(ctx.args[2]) orelse return ctx.w.err("ERR bit offset is not an integer or out of range");
    if (offset < 0 or offset >= @as(i64, max_string_len) * 8) return ctx.w.err("ERR bit offset is not an integer or out of range");
    const s = switch (readString(ctx, ctx.args[1])) {
        .wrong_type => return ctx.wrongType(),
        .missing => return ctx.w.int(0),
        .found => |s| s,
    };
    const byte: usize = @intCast(@divTrunc(offset, 8));
    if (byte >= s.len) return ctx.w.int(0);
    const shift: u3 = @intCast(7 - @mod(offset, 8));
    try ctx.w.int((s[byte] >> shift) & 1);
}

/// BITCOUNT key [start end [BYTE|BIT]]
pub fn bitcount(ctx: *Ctx) Error!void {
    if (ctx.args.len != 2 and ctx.args.len != 4 and ctx.args.len != 5) return ctx.syntaxError();
    var start: i64 = 0;
    var end: i64 = -1;
    var bit_mode = false;
    if (ctx.args.len >= 4) {
        start = (try ctx.int(ctx.args[2])) orelse return;
        end = (try ctx.int(ctx.args[3])) orelse return;
        if (ctx.args.len == 5) {
            if (Ctx.is(ctx.args[4], "bit")) {
                bit_mode = true;
            } else if (!Ctx.is(ctx.args[4], "byte")) {
                return ctx.syntaxError();
            }
        }
    }
    const s = switch (readString(ctx, ctx.args[1])) {
        .wrong_type => return ctx.wrongType(),
        .missing => return ctx.w.int(0),
        .found => |s| s,
    };
    // Redis rejects an inverted pair of negative indexes before clamping,
    // so BITCOUNT key -1 -3 is 0 even on a one-byte string.
    if (start < 0 and end < 0 and start > end) return ctx.w.int(0);
    const total: i64 = if (bit_mode) @as(i64, @intCast(s.len)) * 8 else @intCast(s.len);
    if (start < 0) start = @max(0, total + start);
    if (end < 0) end = @max(0, total + end);
    if (end >= total) end = total - 1;
    if (start > end or total == 0) return ctx.w.int(0);
    var count: u64 = 0;
    if (bit_mode) {
        var b = start;
        while (b <= end) : (b += 1) {
            const byte = s[@intCast(@divTrunc(b, 8))];
            const shift: u3 = @intCast(7 - @mod(b, 8));
            count += (byte >> shift) & 1;
        }
    } else {
        for (s[@intCast(start)..@intCast(end + 1)]) |byte| count += @popCount(byte);
    }
    try ctx.w.int(@intCast(count));
}
