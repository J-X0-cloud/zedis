//! Connection and server administration commands.

const std = @import("std");
const sys = @import("../sys.zig");
const num = @import("../num.zig");
const ctx_mod = @import("ctx.zig");
const table = @import("table.zig");
const Ctx = ctx_mod.Ctx;
const Error = ctx_mod.Error;
const msg = ctx_mod.msg;

pub const version = "7.2.0";
pub const zedis_version = "0.1.0";

pub fn ping(ctx: *Ctx) Error!void {
    if (ctx.args.len > 2) return ctx.wrongArity();
    if (ctx.client.inPubSubContext()) {
        // Subscribed RESP2 clients get a ["pong", message] array.
        try ctx.w.array(2);
        try ctx.w.bulk("pong");
        try ctx.w.bulk(if (ctx.args.len == 2) ctx.args[1] else "");
        return;
    }
    if (ctx.args.len == 2) return ctx.w.bulk(ctx.args[1]);
    try ctx.w.simple("PONG");
}

pub fn echo(ctx: *Ctx) Error!void {
    try ctx.w.bulk(ctx.args[1]);
}

pub fn quit(ctx: *Ctx) Error!void {
    try ctx.w.ok();
    ctx.client.close_after_reply = true;
}

pub fn select(ctx: *Ctx) Error!void {
    const idx = num.parseI64(ctx.args[1]) orelse return ctx.w.err(msg.not_integer);
    if (idx < 0 or idx >= ctx.server.dbs.len) return ctx.w.err("ERR DB index is out of range");
    ctx.client.db = @intCast(idx);
    try ctx.w.ok();
}

pub fn dbsize(ctx: *Ctx) Error!void {
    try ctx.w.int(@intCast(ctx.db().size()));
}

fn parseFlushMode(ctx: *Ctx) Error!bool {
    if (ctx.args.len == 1) return true;
    if (ctx.args.len == 2 and (Ctx.is(ctx.args[1], "sync") or Ctx.is(ctx.args[1], "async"))) return true;
    try ctx.syntaxError();
    return false;
}

pub fn flushdb(ctx: *Ctx) Error!void {
    if (!try parseFlushMode(ctx)) return;
    ctx.db().clear();
    ctx.server.touchAllWatchedKeys(ctx.client.db);
    ctx.server.dirty += 1;
    try ctx.propagate(&.{"FLUSHDB"});
    try ctx.w.ok();
}

pub fn flushall(ctx: *Ctx) Error!void {
    if (!try parseFlushMode(ctx)) return;
    for (ctx.server.dbs) |*d| d.clear();
    ctx.server.touchAllWatchedKeys(null);
    ctx.server.dirty += 1;
    try ctx.propagate(&.{"FLUSHALL"});
    try ctx.w.ok();
}

pub fn swapdb(ctx: *Ctx) Error!void {
    const a = num.parseI64(ctx.args[1]) orelse return ctx.w.err("ERR invalid first DB index");
    const b = num.parseI64(ctx.args[2]) orelse return ctx.w.err("ERR invalid second DB index");
    const n: i64 = @intCast(ctx.server.dbs.len);
    if (a < 0 or a >= n or b < 0 or b >= n) return ctx.w.err("ERR DB index is out of range");
    const ia: usize = @intCast(a);
    const ib: usize = @intCast(b);
    if (ia != ib) {
        const dbs = ctx.server.dbs;
        std.mem.swap(@TypeOf(dbs[0].dict), &dbs[ia].dict, &dbs[ib].dict);
        std.mem.swap(@TypeOf(dbs[0].expires), &dbs[ia].expires, &dbs[ib].expires);
        ctx.server.touchAllWatchedKeys(ia);
        ctx.server.touchAllWatchedKeys(ib);
        ctx.server.dirty += 1;
    }
    try ctx.w.ok();
}

pub fn time(ctx: *Ctx) Error!void {
    const us = sys.nowUs();
    try ctx.w.array(2);
    try ctx.w.bulkInt(@divTrunc(us, 1_000_000));
    try ctx.w.bulkInt(@mod(us, 1_000_000));
}

pub fn lastsave(ctx: *Ctx) Error!void {
    try ctx.w.int(@divTrunc(ctx.server.start_ms, 1000));
}

/// AUTH [username] password
pub fn auth(ctx: *Ctx) Error!void {
    if (ctx.args.len > 3) return ctx.syntaxError();
    const pass = ctx.args[ctx.args.len - 1];
    const required = ctx.server.config.requirepass;
    if (required.len == 0) {
        return ctx.w.err("ERR AUTH <password> called without any password configured for the default user. Are you sure your configuration is correct?");
    }
    if (ctx.args.len == 3 and !std.mem.eql(u8, ctx.args[1], "default")) {
        return ctx.w.err("WRONGPASS invalid username-password pair or user is disabled.");
    }
    if (!constantTimeEql(pass, required)) {
        return ctx.w.err("WRONGPASS invalid username-password pair or user is disabled.");
    }
    ctx.client.authenticated = true;
    try ctx.w.ok();
}

fn constantTimeEql(a: []const u8, b: []const u8) bool {
    var diff: u8 = if (a.len == b.len) 0 else 1;
    const n = @max(a.len, b.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const x = if (i < a.len) a[i] else 0;
        const y = if (i < b.len) b[i] else 0;
        diff |= x ^ y;
    }
    return diff == 0;
}

/// HELLO [protover [AUTH username password] [SETNAME clientname]]
pub fn hello(ctx: *Ctx) Error!void {
    var proto: u8 = ctx.client.proto;
    var i: usize = 1;
    if (ctx.args.len >= 2) {
        const v = num.parseI64(ctx.args[1]) orelse return ctx.w.err("ERR Protocol version is not an integer or out of range");
        if (v < 2 or v > 3) return ctx.w.err("NOPROTO unsupported protocol version");
        proto = @intCast(v);
        i = 2;
    }
    var new_name: ?[]const u8 = null;
    while (i < ctx.args.len) : (i += 1) {
        if (Ctx.is(ctx.args[i], "auth") and i + 2 < ctx.args.len) {
            const user = ctx.args[i + 1];
            const pass = ctx.args[i + 2];
            const required = ctx.server.config.requirepass;
            const user_ok = std.mem.eql(u8, user, "default");
            // With no password configured the default user accepts any password.
            const pass_ok = required.len == 0 or constantTimeEql(pass, required);
            if (!user_ok or !pass_ok) return ctx.w.err("WRONGPASS invalid username-password pair or user is disabled.");
            ctx.client.authenticated = true;
            i += 2;
        } else if (Ctx.is(ctx.args[i], "setname") and i + 1 < ctx.args.len) {
            new_name = ctx.args[i + 1];
            i += 1;
        } else {
            return ctx.w.errFmt("ERR Syntax error in HELLO option '{s}'", .{ctx.args[i]});
        }
    }
    if (!ctx.client.authenticated) return ctx.w.err("NOAUTH HELLO must be called with the client already authenticated, otherwise the HELLO <proto> AUTH <user> <pass> option can be used to authenticate the client and select the RESP protocol version at the same time");
    if (new_name) |n| {
        if (!validClientName(n)) return ctx.w.err("ERR Client names cannot contain spaces, newlines or special characters.");
        try setClientName(ctx, n);
    }
    ctx.client.proto = proto;
    ctx.w.proto = proto;
    try ctx.w.map(7);
    try ctx.w.bulk("server");
    try ctx.w.bulk("redis");
    try ctx.w.bulk("version");
    try ctx.w.bulk(version);
    try ctx.w.bulk("proto");
    try ctx.w.int(proto);
    try ctx.w.bulk("id");
    try ctx.w.int(@intCast(ctx.client.id));
    try ctx.w.bulk("mode");
    try ctx.w.bulk("standalone");
    try ctx.w.bulk("role");
    try ctx.w.bulk("master");
    try ctx.w.bulk("modules");
    try ctx.w.array(0);
}

pub fn reset(ctx: *Ctx) Error!void {
    const c = ctx.client;
    c.discardQueue();
    ctx.server.unwatchAll(c);
    ctx.server.unsubscribeAll(c, false);
    ctx.server.punsubscribeAll(c, false);
    c.db = 0;
    c.proto = 2;
    ctx.w.proto = 2;
    if (c.name) |n| ctx.gpa.free(n);
    c.name = null;
    c.authenticated = ctx.server.config.requirepass.len == 0;
    try ctx.w.simple("RESET");
}

fn validClientName(name: []const u8) bool {
    for (name) |ch| if (ch < '!' or ch > '~') return false;
    return true;
}

fn setClientName(ctx: *Ctx, name: []const u8) Error!void {
    if (ctx.client.name) |n| ctx.gpa.free(n);
    ctx.client.name = if (name.len == 0) null else try ctx.gpa.dupe(u8, name);
}

pub fn client(ctx: *Ctx) Error!void {
    const sub = ctx.args[1];
    if (Ctx.is(sub, "id") and ctx.args.len == 2) {
        try ctx.w.int(@intCast(ctx.client.id));
    } else if (Ctx.is(sub, "setname") and ctx.args.len == 3) {
        if (!validClientName(ctx.args[2])) return ctx.w.err("ERR Client names cannot contain spaces, newlines or special characters.");
        try setClientName(ctx, ctx.args[2]);
        try ctx.w.ok();
    } else if (Ctx.is(sub, "getname") and ctx.args.len == 2) {
        if (ctx.client.name) |n| try ctx.w.bulk(n) else try ctx.w.nullBulk();
    } else if (Ctx.is(sub, "list")) {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(ctx.gpa);
        for (ctx.server.clients.values()) |c| try c.describe(&buf, ctx.now());
        try ctx.w.verbatim(buf.items);
    } else if (Ctx.is(sub, "info") and ctx.args.len == 2) {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(ctx.gpa);
        try ctx.client.describe(&buf, ctx.now());
        try ctx.w.verbatim(buf.items);
    } else if (Ctx.is(sub, "kill") and ctx.args.len == 4 and Ctx.is(ctx.args[2], "id")) {
        const id = std.fmt.parseInt(u64, ctx.args[3], 10) catch return ctx.w.err("ERR client-id should be greater than 0");
        const target = ctx.server.clients.get(id) orelse return ctx.w.int(0);
        target.close_asap = true;
        try ctx.w.int(1);
    } else if (Ctx.is(sub, "setinfo") and ctx.args.len == 4) {
        try ctx.w.ok();
    } else if (Ctx.is(sub, "help")) {
        const lines = [_][]const u8{
            "CLIENT <subcommand> [<arg> [value] [opt] ...]. Subcommands are:",
            "GETNAME",
            "SETNAME <name>",
            "ID",
            "INFO",
            "LIST",
            "KILL ID <client-id>",
            "HELP",
        };
        try ctx.w.array(lines.len);
        for (lines) |l| try ctx.w.simple(l);
    } else {
        try ctx.w.errFmt("ERR unknown subcommand or wrong number of arguments for '{s}'. Try CLIENT HELP.", .{sub});
    }
}

pub fn config(ctx: *Ctx) Error!void {
    const sub = ctx.args[1];
    const cfg = &ctx.server.config;
    if (Ctx.is(sub, "get") and ctx.args.len >= 3) {
        const Collector = struct {
            ctx: *Ctx,
            items: std.ArrayList([2][]const u8) = .empty,
            storage: std.ArrayList([]u8) = .empty,
            pub fn emit(self: *@This(), name: []const u8, value: []const u8) Error!void {
                for (self.items.items) |it| if (std.mem.eql(u8, it[0], name)) return;
                const v = try self.ctx.gpa.dupe(u8, value);
                try self.storage.append(self.ctx.gpa, v);
                try self.items.append(self.ctx.gpa, .{ name, v });
            }
        };
        var col: Collector = .{ .ctx = ctx };
        defer {
            for (col.storage.items) |s| ctx.gpa.free(s);
            col.storage.deinit(ctx.gpa);
            col.items.deinit(ctx.gpa);
        }
        for (ctx.args[2..]) |pattern| try cfg.matching(pattern, &col);
        try ctx.w.map(col.items.items.len);
        for (col.items.items) |it| {
            try ctx.w.bulk(it[0]);
            try ctx.w.bulk(it[1]);
        }
    } else if (Ctx.is(sub, "set") and ctx.args.len >= 4 and ctx.args.len % 2 == 0) {
        var i: usize = 2;
        while (i < ctx.args.len) : (i += 2) {
            const name = ctx.args[i];
            const value = ctx.args[i + 1];
            const was_aof = cfg.appendonly;
            cfg.set(ctx.gpa, name, value, false) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.UnknownOption => return ctx.w.errFmt("ERR Unknown option or number of arguments for CONFIG SET - '{s}'", .{name}),
                error.Immutable => return ctx.w.errFmt("ERR CONFIG SET failed (possibly related to argument '{s}') - can't set immutable config", .{name}),
                error.InvalidValue => return ctx.w.errFmt("ERR CONFIG SET failed (possibly related to argument '{s}') - argument couldn't be parsed into an integer", .{name}),
            };
            if (Ctx.is(name, "appendonly") and was_aof != cfg.appendonly) {
                if (cfg.appendonly) {
                    ctx.server.enableAof() catch {
                        cfg.appendonly = false;
                        return ctx.w.err("ERR CONFIG SET failed (possibly related to argument 'appendonly') - Unable to turn on AOF. Check server logs.");
                    };
                } else {
                    ctx.server.disableAof();
                }
            }
            if (Ctx.is(name, "loglevel")) ctx.server.log.min = @fromBackingInt(@intCast(@backingInt(cfg.loglevel)));
        }
        try ctx.w.ok();
    } else if (Ctx.is(sub, "resetstat") and ctx.args.len == 2) {
        ctx.server.stats = .{};
        ctx.server.db_stats = .{};
        ctx.server.command_calls = @splat(0);
        try ctx.w.ok();
    } else if (Ctx.is(sub, "rewrite") and ctx.args.len == 2) {
        try ctx.w.err("ERR The server is running without a config file");
    } else if (Ctx.is(sub, "help")) {
        const lines = [_][]const u8{
            "CONFIG <subcommand> [<arg> [value] [opt] ...]. Subcommands are:",
            "GET <pattern>",
            "SET <directive> <value>",
            "RESETSTAT",
            "HELP",
        };
        try ctx.w.array(lines.len);
        for (lines) |l| try ctx.w.simple(l);
    } else {
        try ctx.w.errFmt("ERR unknown subcommand or wrong number of arguments for '{s}'. Try CONFIG HELP.", .{sub});
    }
}

pub fn bgrewriteaof(ctx: *Ctx) Error!void {
    const server = ctx.server;
    if (server.aof.rewriteInProgress()) {
        return ctx.w.err("ERR Background append only file rewriting already in progress");
    }
    if (!server.aof.enabled) {
        // Like Redis without AOF on: produce a file once, synchronously.
        server.aof.rewriteSync(server.dbs, ctx.now()) catch return ctx.w.err("ERR Background append only file rewriting failed");
        server.aof.close();
        return ctx.w.simple("Background append only file rewriting started");
    }
    server.startAofRewrite() catch return ctx.w.err("ERR Background append only file rewriting failed");
    try ctx.w.simple("Background append only file rewriting started");
}

pub fn shutdown(ctx: *Ctx) Error!void {
    for (ctx.args[1..]) |a| {
        if (!(Ctx.is(a, "nosave") or Ctx.is(a, "save") or Ctx.is(a, "now") or Ctx.is(a, "force"))) return ctx.syntaxError();
    }
    ctx.server.log.log(.warning, "User requested shutdown...", .{});
    ctx.server.running = false;
    ctx.client.close_asap = true;
}

/// DEBUG SLEEP <seconds> | SET-ACTIVE-EXPIRE <0|1> | JMAP
pub fn debug(ctx: *Ctx) Error!void {
    const sub = ctx.args[1];
    if (Ctx.is(sub, "sleep") and ctx.args.len == 3) {
        const secs = num.parseF64(ctx.args[2]) orelse return ctx.w.err(msg.not_float);
        sys.sleepMs(@intFromFloat(@max(0, secs) * 1000));
        try ctx.w.ok();
    } else if (Ctx.is(sub, "set-active-expire") and ctx.args.len == 3) {
        ctx.server.active_expire_enabled = !std.mem.eql(u8, ctx.args[2], "0");
        try ctx.w.ok();
    } else if (Ctx.is(sub, "reload") or Ctx.is(sub, "loadaof")) {
        // Re-read the dataset from the AOF to prove it round-trips.
        const server = ctx.server;
        if (!server.aof.enabled) return ctx.w.err("ERR AOF is not enabled");
        _ = server.aof.flush(.always);
        for (server.dbs) |*d| d.clear();
        server.loadAof() catch return ctx.w.err("ERR Error trying to load the AOF");
        try ctx.w.ok();
    } else {
        try ctx.w.errFmt("ERR unknown subcommand or wrong number of arguments for '{s}'. Try DEBUG HELP.", .{sub});
    }
}

pub fn command(ctx: *Ctx) Error!void {
    if (ctx.args.len == 1) {
        try ctx.w.array(table.all.len);
        for (&table.all) |*cmd| try writeCommandInfo(ctx, cmd);
        return;
    }
    const sub = ctx.args[1];
    if (Ctx.is(sub, "count")) {
        try ctx.w.int(@intCast(table.all.len));
    } else if (Ctx.is(sub, "info")) {
        try ctx.w.array(ctx.args.len - 2);
        for (ctx.args[2..]) |name| {
            if (table.lookup(name)) |cmd| try writeCommandInfo(ctx, cmd) else try ctx.w.nullArray();
        }
    } else if (Ctx.is(sub, "docs")) {
        // Clients such as redis-cli only use this for hints.
        try ctx.w.map(0);
    } else if (Ctx.is(sub, "list")) {
        try ctx.w.array(table.all.len);
        for (&table.all) |*cmd| try ctx.w.bulk(cmd.name);
    } else {
        try ctx.w.errFmt("ERR unknown subcommand or wrong number of arguments for '{s}'. Try COMMAND HELP.", .{sub});
    }
}

fn writeCommandInfo(ctx: *Ctx, cmd: *const ctx_mod.Command) Error!void {
    try ctx.w.array(6);
    try ctx.w.bulk(cmd.name);
    try ctx.w.int(cmd.arity);
    var flags: [6][]const u8 = undefined;
    var nf: usize = 0;
    if (cmd.flags.write) {
        flags[nf] = "write";
        nf += 1;
    }
    if (cmd.flags.readonly) {
        flags[nf] = "readonly";
        nf += 1;
    }
    if (cmd.flags.admin) {
        flags[nf] = "admin";
        nf += 1;
    }
    if (cmd.flags.pubsub) {
        flags[nf] = "pubsub";
        nf += 1;
    }
    if (cmd.flags.fast) {
        flags[nf] = "fast";
        nf += 1;
    }
    if (cmd.flags.blocking) {
        flags[nf] = "blocking";
        nf += 1;
    }
    try ctx.w.set(nf);
    for (flags[0..nf]) |f| try ctx.w.simple(f);
    try ctx.w.int(cmd.first_key);
    try ctx.w.int(cmd.last_key);
    try ctx.w.int(cmd.key_step);
}

pub fn info(ctx: *Ctx) Error!void {
    const server = ctx.server;
    var section: []const u8 = "default";
    if (ctx.args.len >= 2) section = ctx.args[1];
    const all = Ctx.is(section, "all") or Ctx.is(section, "everything");
    const default = Ctx.is(section, "default") or all;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(ctx.gpa);
    const gpa = ctx.gpa;
    const now = ctx.now();

    if (default or Ctx.is(section, "server")) {
        try out.print(gpa, "# Server\r\nredis_version:{s}\r\nzedis_version:{s}\r\nredis_mode:standalone\r\nos:Linux\r\narch_bits:64\r\nmultiplexing_api:epoll\r\nprocess_id:{d}\r\nrun_id:{s}\r\ntcp_port:{d}\r\nuptime_in_seconds:{d}\r\nuptime_in_days:{d}\r\nhz:{d}\r\n\r\n", .{
            version,
            zedis_version,
            sys.getPid(),
            &server.run_id,
            server.port,
            @divTrunc(now - server.start_ms, 1000),
            @divTrunc(now - server.start_ms, 86_400_000),
            server.config.hz,
        });
    }
    if (default or Ctx.is(section, "clients")) {
        var pubsub_clients: usize = 0;
        for (server.clients.values()) |c| {
            if (c.subscriptionCount() > 0) pubsub_clients += 1;
        }
        try out.print(gpa, "# Clients\r\nconnected_clients:{d}\r\nblocked_clients:{d}\r\npubsub_clients:{d}\r\nmaxclients:{d}\r\n\r\n", .{
            server.clients.count(),
            server.blocked_clients,
            pubsub_clients,
            server.config.maxclients,
        });
    }
    if (default or Ctx.is(section, "memory")) {
        const used = server.usedMemory();
        try out.print(gpa, "# Memory\r\nused_memory:{d}\r\nused_memory_peak:{d}\r\n\r\n", .{ used, server.peakMemory() });
    }
    if (default or Ctx.is(section, "persistence")) {
        const aof = &server.aof;
        try out.print(gpa, "# Persistence\r\nloading:0\r\naof_enabled:{d}\r\naof_rewrite_in_progress:{d}\r\naof_rewrite_scheduled:{d}\r\naof_last_rewrite_time_sec:{d}\r\naof_last_bgrewrite_status:{s}\r\naof_last_write_status:{s}\r\naof_rewrites:{d}\r\naof_current_size:{d}\r\naof_base_size:{d}\r\naof_buffer_length:{d}\r\n\r\n", .{
            @intFromBool(aof.enabled),
            @intFromBool(aof.rewriteInProgress()),
            @intFromBool(aof.rewrite_scheduled),
            if (aof.last_rewrite_ms < 0) @as(i64, -1) else @divTrunc(aof.last_rewrite_ms, 1000),
            @tagName(aof.last_rewrite_status),
            if (aof.last_write_ok) "ok" else "err",
            aof.rewrites,
            aof.current_size,
            aof.base_size,
            aof.buf.items.len,
        });
    }
    if (default or Ctx.is(section, "stats")) {
        const s = server.stats;
        const ds = server.db_stats;
        try out.print(gpa, "# Stats\r\ntotal_connections_received:{d}\r\ntotal_commands_processed:{d}\r\ntotal_net_input_bytes:{d}\r\ntotal_net_output_bytes:{d}\r\nrejected_connections:{d}\r\nexpired_keys:{d}\r\nkeyspace_hits:{d}\r\nkeyspace_misses:{d}\r\npubsub_channels:{d}\r\npubsub_patterns:{d}\r\n\r\n", .{
            s.total_connections,
            s.total_commands,
            s.net_input_bytes,
            s.net_output_bytes,
            s.rejected_connections,
            ds.expired_keys,
            ds.keyspace_hits,
            ds.keyspace_misses,
            server.channels.count(),
            server.patterns.count(),
        });
    }
    if (all or Ctx.is(section, "commandstats")) {
        try out.appendSlice(gpa, "# Commandstats\r\n");
        for (server.command_calls, 0..) |calls, i| {
            if (calls == 0) continue;
            try out.print(gpa, "cmdstat_{s}:calls={d}\r\n", .{ table.all[i].name, calls });
        }
        try out.appendSlice(gpa, "\r\n");
    }
    if (default or Ctx.is(section, "keyspace")) {
        try out.appendSlice(gpa, "# Keyspace\r\n");
        for (server.dbs, 0..) |*d, i| {
            if (d.size() == 0) continue;
            try out.print(gpa, "db{d}:keys={d},expires={d},avg_ttl=0\r\n", .{ i, d.size(), d.expiresCount() });
        }
        try out.appendSlice(gpa, "\r\n");
    }
    // Drop the trailing blank line like Redis does.
    if (std.mem.endsWith(u8, out.items, "\r\n\r\n")) out.items.len -= 2;
    try ctx.w.verbatim(out.items);
}
