//! MULTI/EXEC/DISCARD/WATCH/UNWATCH.
//!
//! Commands issued after MULTI are validated (name, arity, auth) and
//! queued. A validation failure marks the transaction so EXEC aborts with
//! EXECABORT. WATCH registers keys; any modification to a watched key,
//! including expiry or FLUSHDB, makes the next EXEC return a null reply.

const std = @import("std");
const ctx_mod = @import("ctx.zig");
const table = @import("table.zig");
const Ctx = ctx_mod.Ctx;
const Error = ctx_mod.Error;

pub fn multi(ctx: *Ctx) Error!void {
    if (ctx.client.in_multi) return ctx.w.err("ERR MULTI calls can not be nested");
    ctx.client.in_multi = true;
    ctx.client.multi_error = false;
    try ctx.w.ok();
}

pub fn discard(ctx: *Ctx) Error!void {
    if (!ctx.client.in_multi) return ctx.w.err("ERR DISCARD without MULTI");
    ctx.client.discardQueue();
    ctx.server.unwatchAll(ctx.client);
    try ctx.w.ok();
}

pub fn exec(ctx: *Ctx) Error!void {
    const c = ctx.client;
    const server = ctx.server;
    if (!c.in_multi) return ctx.w.err("ERR EXEC without MULTI");
    if (c.multi_error) {
        c.discardQueue();
        server.unwatchAll(c);
        return ctx.w.err("EXECABORT Transaction discarded because of previous errors.");
    }
    if (c.dirty_cas) {
        c.discardQueue();
        server.unwatchAll(c);
        return ctx.w.nullArray();
    }
    server.unwatchAll(c);

    // Take ownership of the queue so commands can safely touch the client.
    var queue = c.queue;
    c.queue = .empty;
    c.in_multi = false;
    defer {
        for (queue.items) |*q| q.deinit(ctx.gpa);
        queue.deinit(ctx.gpa);
    }

    try ctx.w.array(queue.items.len);
    c.in_exec = true;
    server.exec_depth += 1;
    server.exec_multi_emitted = false;
    defer {
        c.in_exec = false;
        server.exec_depth -= 1;
    }
    for (queue.items) |q| {
        const args: []const []const u8 = @ptrCast(q.args);
        const cmd = table.lookup(args[0]).?;
        try server.call(c, cmd, args);
        // A queued SELECT or HELLO changes the writer's settings.
        ctx.w.proto = c.proto;
    }
    if (server.exec_multi_emitted) try server.propagate(c.db, &.{"EXEC"});
    // EXEC itself never propagates; the wrapped commands already did.
    ctx.noPropagation();
}

pub fn watch(ctx: *Ctx) Error!void {
    if (ctx.client.in_multi) return ctx.w.err("ERR WATCH inside MULTI is not allowed");
    for (ctx.args[1..]) |key| try ctx.server.watchKey(ctx.client, key);
    try ctx.w.ok();
}

pub fn unwatch(ctx: *Ctx) Error!void {
    ctx.server.unwatchAll(ctx.client);
    try ctx.w.ok();
}
