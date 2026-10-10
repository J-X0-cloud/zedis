//! Publish/subscribe commands.

const std = @import("std");
const glob = @import("../glob.zig");
const ctx_mod = @import("ctx.zig");
const Ctx = ctx_mod.Ctx;
const Error = ctx_mod.Error;

fn disallowInMulti(ctx: *Ctx, name: []const u8) Error!bool {
    if (ctx.client.in_exec) {
        try ctx.w.errFmt("ERR {s} isn't allowed for a client in MULTI/EXEC context", .{name});
        return true;
    }
    return false;
}

pub fn subscribe(ctx: *Ctx) Error!void {
    if (try disallowInMulti(ctx, "SUBSCRIBE")) return;
    for (ctx.args[1..]) |ch| try ctx.server.subscribe(ctx.client, ch);
}

pub fn psubscribe(ctx: *Ctx) Error!void {
    if (try disallowInMulti(ctx, "PSUBSCRIBE")) return;
    for (ctx.args[1..]) |p| try ctx.server.psubscribe(ctx.client, p);
}

pub fn unsubscribe(ctx: *Ctx) Error!void {
    if (ctx.args.len == 1) {
        ctx.server.unsubscribeAll(ctx.client, true);
        return;
    }
    for (ctx.args[1..]) |ch| try ctx.server.unsubscribe(ctx.client, ch, true);
}

pub fn punsubscribe(ctx: *Ctx) Error!void {
    if (ctx.args.len == 1) {
        ctx.server.punsubscribeAll(ctx.client, true);
        return;
    }
    for (ctx.args[1..]) |p| try ctx.server.punsubscribe(ctx.client, p, true);
}

pub fn publish(ctx: *Ctx) Error!void {
    const n = try ctx.server.publish(ctx.args[1], ctx.args[2]);
    try ctx.w.int(@intCast(n));
}

/// PUBSUB CHANNELS [pattern] | NUMSUB [channel ...] | NUMPAT
pub fn pubsub(ctx: *Ctx) Error!void {
    const sub = ctx.args[1];
    const server = ctx.server;
    if (Ctx.is(sub, "channels") and ctx.args.len <= 3) {
        const pattern: ?[]const u8 = if (ctx.args.len == 3) ctx.args[2] else null;
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(ctx.gpa);
        for (server.channels.keys()) |ch| {
            if (pattern) |p| if (!glob.match(p, ch)) continue;
            try names.append(ctx.gpa, ch);
        }
        try ctx.w.array(names.items.len);
        for (names.items) |n| try ctx.w.bulk(n);
    } else if (Ctx.is(sub, "numsub")) {
        try ctx.w.map(ctx.args.len - 2);
        for (ctx.args[2..]) |ch| {
            try ctx.w.bulk(ch);
            const n = if (server.channels.get(ch)) |l| l.items.len else 0;
            try ctx.w.int(@intCast(n));
        }
    } else if (Ctx.is(sub, "numpat") and ctx.args.len == 2) {
        try ctx.w.int(@intCast(server.patterns.count()));
    } else {
        try ctx.w.errFmt("ERR unknown subcommand or wrong number of arguments for '{s}'. Try PUBSUB HELP.", .{sub});
    }
}
