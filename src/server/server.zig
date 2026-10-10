//! The server: a single-threaded epoll event loop that owns the keyspace,
//! all client connections, the pub/sub registry, WATCH bookkeeping,
//! blocked clients and the AOF.
//!
//! One loop iteration does the following:
//!   1. `beforeSleep`: resume clients that were unblocked, flush the AOF
//!      (and fsync under `appendfsync always`), then write pending replies.
//!   2. Wait in epoll_wait until a socket is ready or the next timer is due.
//!   3. Accept connections, read requests and execute them. Replies are
//!      only buffered here; nothing is sent before the AOF write in step 1.
//!   4. Run the cron at `hz` frequency: active expiry, blocked client
//!      timeouts, AOF fsync and rewrite supervision.

const std = @import("std");
const sys = @import("../sys.zig");
const resp = @import("../resp.zig");
const num = @import("../num.zig");
const glob = @import("../glob.zig");
const db_mod = @import("../db.zig");
const aof_mod = @import("../aof.zig");
const config_mod = @import("config.zig");
const client_mod = @import("client.zig");
const log_mod = @import("log.zig");
const ctx_mod = @import("../commands/ctx.zig");
const commands = @import("../commands/table.zig");
const Allocator = std.mem.Allocator;

pub const Db = db_mod.Db;
pub const Client = client_mod.Client;
pub const Config = config_mod.Config;
pub const Ctx = ctx_mod.Ctx;
pub const Command = ctx_mod.Command;

const token_listener: u64 = 0;
const token_waker: u64 = 1;
const first_client_id: u64 = 2;
const read_chunk = 16 * 1024;

pub const Stats = struct {
    total_connections: u64 = 0,
    rejected_connections: u64 = 0,
    total_commands: u64 = 0,
    net_input_bytes: u64 = 0,
    net_output_bytes: u64 = 0,
    expired_by_cron: u64 = 0,
    pubsub_messages: u64 = 0,
};

const ReadyKey = struct {
    db: usize,
    key: []u8,
};

const ClientList = std.ArrayList(*Client);

pub const Server = struct {
    gpa: Allocator,
    config: Config,
    log: log_mod.Logger = .{},

    dbs: []Db,
    db_stats: db_mod.Stats = .{},
    stats: Stats = .{},
    /// The command clock: wall time in ms, fixed for the duration of a
    /// command and for a whole MULTI/EXEC block.
    now_ms: i64,
    start_ms: i64,
    /// Count of modifications since startup; drives propagation.
    dirty: u64 = 0,
    rng: std.Random.DefaultPrng,
    run_id: [40]u8,

    listen_fd: sys.fd_t = -1,
    port: u16 = 0,
    epoll: sys.Epoll,
    waker: sys.Waker,
    running: bool = false,
    shutdown_requested: bool = false,

    clients: std.AutoArrayHashMapUnmanaged(u64, *Client) = .empty,
    next_client_id: u64 = first_client_id,
    pending_writes: ClientList = .empty,
    unblocked: ClientList = .empty,

    channels: std.StringArrayHashMapUnmanaged(ClientList) = .empty,
    patterns: std.StringArrayHashMapUnmanaged(ClientList) = .empty,

    watched_keys: []std.StringHashMapUnmanaged(ClientList),
    blocking_keys: []std.StringArrayHashMapUnmanaged(ClientList),
    ready_keys: std.ArrayList(ReadyKey) = .empty,
    blocked_clients: usize = 0,

    aof: aof_mod.Aof,
    loading: bool = false,
    /// Set while EXEC runs so its writes are wrapped in MULTI/EXEC.
    exec_depth: usize = 0,
    exec_multi_emitted: bool = false,

    last_cron_ms: i64 = 0,
    cron_loops: u64 = 0,
    active_expire_enabled: bool = true,
    /// Per-command call counters, indexed like `commands.all`.
    command_calls: [commands.all.len]u64 = @splat(0),
    /// Optional allocator wrapper used to report memory usage in INFO.
    tracker: ?*const @import("tracking_allocator.zig").TrackingAllocator = null,

    pub const InitError = sys.Error || Allocator.Error;

    pub fn init(gpa: Allocator, config: Config) InitError!*Server {
        const self = try gpa.create(Server);
        errdefer gpa.destroy(self);
        var seed_bytes: [8]u8 = undefined;
        sys.getRandom(&seed_bytes);
        const seed = std.mem.readInt(u64, &seed_bytes, .little) ^ @as(u64, @bitCast(sys.nowUs()));
        const now = sys.nowMs();
        self.* = .{
            .gpa = gpa,
            .config = config,
            .dbs = undefined,
            .now_ms = now,
            .start_ms = now,
            .rng = std.Random.DefaultPrng.init(seed),
            .run_id = undefined,
            .epoll = undefined,
            .waker = undefined,
            .watched_keys = undefined,
            .blocking_keys = undefined,
            .aof = aof_mod.Aof.init(gpa, config.dir, config.appendfilename),
        };
        self.log.min = @fromBackingInt(@intCast(@backingInt(config.loglevel)));
        const hex = "0123456789abcdef";
        for (&self.run_id) |*c| c.* = hex[self.rng.random().uintLessThan(usize, 16)];

        self.dbs = try gpa.alloc(Db, config.databases);
        errdefer gpa.free(self.dbs);
        for (self.dbs, 0..) |*d, i| {
            d.* = Db.init(gpa, i, &self.now_ms, &self.db_stats, seed);
            d.listener = .{ .ctx = self, .on_expired = onKeyExpired };
        }
        self.watched_keys = try gpa.alloc(std.StringHashMapUnmanaged(ClientList), config.databases);
        errdefer gpa.free(self.watched_keys);
        for (self.watched_keys) |*w| w.* = .empty;
        self.blocking_keys = try gpa.alloc(std.StringArrayHashMapUnmanaged(ClientList), config.databases);
        errdefer gpa.free(self.blocking_keys);
        for (self.blocking_keys) |*b| b.* = .empty;

        self.epoll = try sys.Epoll.init();
        errdefer self.epoll.deinit();
        self.waker = try sys.Waker.init();
        errdefer self.waker.deinit();
        try self.epoll.add(self.waker.fd, sys.Epoll.IN, token_waker);
        return self;
    }

    pub fn deinit(self: *Server) void {
        const gpa = self.gpa;
        while (self.clients.count() > 0) {
            self.freeClient(self.clients.values()[0]);
        }
        self.clients.deinit(gpa);
        self.pending_writes.deinit(gpa);
        self.unblocked.deinit(gpa);
        freeRegistry(gpa, &self.channels);
        freeRegistry(gpa, &self.patterns);
        for (self.watched_keys) |*w| {
            var it = w.iterator();
            while (it.next()) |e| {
                e.value_ptr.deinit(gpa);
                gpa.free(e.key_ptr.*);
            }
            w.deinit(gpa);
        }
        gpa.free(self.watched_keys);
        for (self.blocking_keys) |*b| freeRegistry(gpa, b);
        gpa.free(self.blocking_keys);
        for (self.ready_keys.items) |rk| gpa.free(rk.key);
        self.ready_keys.deinit(gpa);
        self.aof.deinit();
        for (self.dbs) |*d| d.deinit();
        gpa.free(self.dbs);
        self.config.deinit(gpa);
        if (self.listen_fd >= 0) sys.close(self.listen_fd);
        self.epoll.deinit();
        self.waker.deinit();
        gpa.destroy(self);
    }

    fn freeRegistry(gpa: Allocator, reg: *std.StringArrayHashMapUnmanaged(ClientList)) void {
        var it = reg.iterator();
        while (it.next()) |e| {
            e.value_ptr.deinit(gpa);
            gpa.free(e.key_ptr.*);
        }
        reg.deinit(gpa);
    }

    // ------------------------------------------------------------ startup --

    /// Loads the AOF if enabled, then binds the listening socket.
    pub fn start(self: *Server) !void {
        if (self.config.appendonly) {
            try self.loadAof();
            try self.aof.open();
        }
        const addr = try sys.Ipv4.parse(self.config.bind, self.config.port);
        self.listen_fd = try sys.listenTcp(addr, 511);
        self.port = try sys.localPort(self.listen_fd);
        try self.epoll.add(self.listen_fd, sys.Epoll.IN, token_listener);
        self.log.log(.notice, "Ready to accept connections tcp on {s}:{d}", .{ self.config.bind, self.port });
    }

    /// Replays the AOF through an internal client.
    pub fn loadAof(self: *Server) !void {
        var pbuf: [4096]u8 = undefined;
        const path = self.aof.pathInto(&pbuf);
        const data = (try sys.readFileAlloc(self.gpa, path)) orelse {
            self.log.log(.notice, "No AOF found at {s}, starting with an empty dataset", .{path});
            return;
        };
        defer self.gpa.free(data);
        const t0 = sys.monotonicNs();
        const result = try self.replay(data);
        switch (result.outcome) {
            .complete => {},
            .truncated, .open_multi => {
                if (!self.config.aof_load_truncated) {
                    self.log.log(.warning, "AOF {s} is truncated at offset {d}; refusing to start (aof-load-truncated no)", .{ path, result.valid_len });
                    return error.TruncatedAof;
                }
                self.log.log(.warning, "AOF {s} was truncated: discarding {d} trailing bytes{s}", .{
                    path,
                    data.len - result.valid_len,
                    if (result.outcome == .open_multi) " (incomplete MULTI/EXEC)" else "",
                });
                const fd = try sys.open(path, .append_create);
                defer sys.close(fd);
                try sys.ftruncate(fd, result.valid_len);
            },
            .bad_format => {
                self.log.log(.warning, "Bad file format reading the append only file {s} at offset {d}", .{ path, result.valid_len });
                return error.BadAofFormat;
            },
        }
        const elapsed_ms = (sys.monotonicNs() - t0) / 1_000_000;
        self.log.log(.notice, "DB loaded from append only file: {d} commands in {d} ms", .{ result.commands, elapsed_ms });
    }

    pub const ReplayResult = struct {
        outcome: enum { complete, truncated, open_multi, bad_format },
        /// Length of the prefix that was applied cleanly.
        valid_len: usize,
        commands: usize,
    };

    /// Executes a RESP command stream against the dataset without
    /// propagating it. Used for AOF loading.
    pub fn replay(self: *Server, data: []const u8) !ReplayResult {
        self.loading = true;
        defer self.loading = false;
        for (self.dbs) |*d| d.lazy_expire = false;
        defer for (self.dbs) |*d| {
            d.lazy_expire = true;
        };
        var fake = Client.init(self.gpa, 0, -1, .{ .addr = .{ 0, 0, 0, 0 }, .port = 0 }, self.now_ms);
        defer fake.deinit();
        fake.authenticated = true;
        var parser = resp.RequestParser.init(self.gpa);
        defer parser.deinit();
        var off: usize = 0;
        var count: usize = 0;
        var multi_start: usize = 0;
        while (off < data.len) {
            const req = parser.parse(data[off..]) catch {
                return .{ .outcome = .bad_format, .valid_len = off, .commands = count };
            } orelse {
                return .{ .outcome = .truncated, .valid_len = if (fake.in_multi) multi_start else off, .commands = count };
            };
            if (req.args.len > 0) {
                if (Ctx.is(req.args[0], "multi")) multi_start = off;
                self.now_ms = sys.nowMs();
                self.processCommand(&fake, req.args);
                count += 1;
                // Replies to the internal client are irrelevant.
                fake.out.clearRetainingCapacity();
            }
            off += req.consumed;
        }
        if (fake.in_multi) return .{ .outcome = .open_multi, .valid_len = multi_start, .commands = count };
        return .{ .outcome = .complete, .valid_len = off, .commands = count };
    }

    // --------------------------------------------------------- event loop --

    /// Runs until SHUTDOWN or `stop` is called.
    pub fn run(self: *Server) !void {
        self.running = true;
        var events: [256]sys.Epoll.Event = undefined;
        self.last_cron_ms = sys.nowMs();
        while (self.running) {
            self.beforeSleep();
            if (!self.running) break;
            const timeout = self.computeTimeout();
            const ready = try self.epoll.wait(&events, timeout);
            self.now_ms = sys.nowMs();
            for (ready) |ev| {
                switch (ev.data.u64) {
                    token_listener => self.acceptClients(),
                    token_waker => {
                        self.waker.drain();
                        if (self.shutdown_requested) self.running = false;
                    },
                    else => |id| {
                        const c = self.clients.get(id) orelse continue;
                        if (ev.events & (sys.Epoll.IN | sys.Epoll.HUP | sys.Epoll.ERR) != 0) self.readFromClient(c);
                        // Socket became writable: defer the write to beforeSleep so a
                        // reply produced in this same iteration can never overtake
                        // the AOF write for its command.
                        if (ev.events & sys.Epoll.OUT != 0 and !c.close_asap) self.queueWrite(c);
                    },
                }
            }
            self.now_ms = sys.nowMs();
            const period: i64 = @divTrunc(1000, @as(i64, self.config.hz));
            if (self.now_ms - self.last_cron_ms >= period) {
                self.last_cron_ms = self.now_ms;
                self.cron();
            }
            self.handleBlockedTimeouts();
        }
        self.beforeSleep();
        self.prepareShutdown();
    }

    /// Asks the loop to exit from another thread.
    pub fn stop(self: *Server) void {
        self.shutdown_requested = true;
        self.waker.wake();
    }

    fn computeTimeout(self: *Server) i32 {
        const period: i64 = @divTrunc(1000, @as(i64, self.config.hz));
        const now = sys.nowMs();
        var wait = @max(0, self.last_cron_ms + period - now);
        if (self.blocked_clients > 0) {
            for (self.clients.values()) |c| {
                const b = c.blocked orelse continue;
                if (b.deadline_ms == 0) continue;
                wait = @min(wait, @max(0, b.deadline_ms - now));
            }
        }
        if (self.unblocked.items.len > 0) wait = 0;
        return @intCast(wait);
    }

    fn prepareShutdown(self: *Server) void {
        if (self.aof.enabled) {
            _ = self.aof.flush(.always);
            if (self.aof.fd) |fd| sys.fsync(fd) catch {};
        }
        self.log.log(.notice, "Server is now ready to exit, bye bye...", .{});
    }

    fn beforeSleep(self: *Server) void {
        // Unblocked clients may have pipelined commands waiting.
        while (self.unblocked.items.len > 0) {
            const batch = self.unblocked.toOwnedSlice(self.gpa) catch break;
            defer self.gpa.free(batch);
            for (batch) |c| {
                c.resume_pending = false;
                if (!c.close_asap and c.blocked == null) self.processInput(c);
            }
        }
        // Persist before acknowledging.
        if (self.aof.enabled) {
            _ = self.aof.flush(self.config.appendfsync);
        }
        var i: usize = 0;
        while (i < self.pending_writes.items.len) : (i += 1) {
            const c = self.pending_writes.items[i];
            c.pending_write = false;
            if (!c.close_asap) self.writeToClient(c);
        }
        self.pending_writes.clearRetainingCapacity();
        // Reap clients scheduled for closing.
        var j: usize = 0;
        while (j < self.clients.count()) {
            const c = self.clients.values()[j];
            if (c.close_asap or (c.close_after_reply and c.pendingOutput() == 0)) {
                self.freeClient(c);
                continue;
            }
            j += 1;
        }
    }

    fn cron(self: *Server) void {
        self.cron_loops += 1;
        // Active expiry gets up to 25% of a cron period.
        if (self.active_expire_enabled) {
            const period_ns: u64 = 1_000_000_000 / @as(u64, self.config.hz);
            const deadline = sys.monotonicNs() + period_ns / 4;
            for (self.dbs) |*d| {
                self.stats.expired_by_cron += d.activeExpireCycle(20, deadline, &sys.monotonicNs);
            }
        }
        if (self.aof.enabled) {
            if (self.config.appendfsync == .everysec) self.aof.fsyncIfDue(self.now_ms);
            switch (self.aof.checkChild(self.now_ms)) {
                .succeeded => self.log.log(.notice, "Background AOF rewrite finished successfully", .{}),
                .failed => self.log.log(.warning, "Background AOF rewrite failed", .{}),
                .none, .running => {},
            }
            if (!self.aof.rewriteInProgress() and (self.aof.rewrite_scheduled or
                self.aof.shouldAutoRewrite(self.config.auto_aof_rewrite_percentage, self.config.auto_aof_rewrite_min_size)))
            {
                self.startAofRewrite() catch |err| self.log.log(.warning, "Can't start AOF rewrite: {s}", .{@errorName(err)});
            }
        }
    }

    pub fn startAofRewrite(self: *Server) !void {
        try self.aof.startBackgroundRewrite(self.dbs, self.now_ms);
        self.log.log(.notice, "Background append only file rewriting started by pid {d}", .{self.aof.child_pid.?});
    }

    /// Enables AOF at runtime: writes a snapshot so the file is complete.
    pub fn enableAof(self: *Server) !void {
        if (self.aof.enabled) return;
        try self.aof.rewriteSync(self.dbs, self.now_ms);
    }

    pub fn disableAof(self: *Server) void {
        if (!self.aof.enabled) return;
        if (self.aof.child_pid) |pid| {
            sys.killChild(pid);
            self.aof.child_pid = null;
        }
        self.aof.close();
    }

    // -------------------------------------------------------- networking --

    fn acceptClients(self: *Server) void {
        var n: usize = 0;
        while (n < 1000) : (n += 1) {
            const acc = sys.accept(self.listen_fd) catch |err| switch (err) {
                error.WouldBlock => return,
                error.TooManyOpenFiles => {
                    self.log.log(.warning, "Accepting client connection: too many open files", .{});
                    return;
                },
                else => return,
            };
            if (self.clients.count() >= self.config.maxclients) {
                _ = sys.send(acc.fd, "-ERR max number of clients reached\r\n") catch {};
                sys.close(acc.fd);
                self.stats.rejected_connections += 1;
                continue;
            }
            self.createClient(acc.fd, acc.addr) catch {
                sys.close(acc.fd);
                continue;
            };
        }
    }

    pub fn createClient(self: *Server, fd: sys.fd_t, addr: sys.Ipv4) !void {
        const c = try self.gpa.create(Client);
        errdefer self.gpa.destroy(c);
        const id = self.next_client_id;
        self.next_client_id += 1;
        c.* = Client.init(self.gpa, id, fd, addr, sys.nowMs());
        c.authenticated = self.config.requirepass.len == 0;
        try self.clients.put(self.gpa, id, c);
        errdefer _ = self.clients.swapRemove(id);
        try self.epoll.add(fd, sys.Epoll.IN, id);
        self.stats.total_connections += 1;
    }

    pub fn freeClient(self: *Server, c: *Client) void {
        if (c.blocked != null) self.unblockClient(c, false);
        self.unwatchAll(c);
        self.unsubscribeAll(c, false);
        self.punsubscribeAll(c, false);
        _ = self.clients.swapRemove(c.id);
        removeClient(&self.pending_writes, c);
        removeClient(&self.unblocked, c);
        if (c.fd >= 0) {
            self.epoll.remove(c.fd);
            sys.close(c.fd);
        }
        c.deinit();
        self.gpa.destroy(c);
    }

    fn removeClient(list: *ClientList, c: *Client) void {
        var i: usize = 0;
        while (i < list.items.len) {
            if (list.items[i] == c) {
                _ = list.orderedRemove(i);
            } else i += 1;
        }
    }

    fn readFromClient(self: *Server, c: *Client) void {
        if (c.close_asap) return;
        // Compact consumed input before growing the buffer.
        if (c.in_pos > 0) {
            const rest = c.in.items.len - c.in_pos;
            std.mem.copyForwards(u8, c.in.items[0..rest], c.in.items[c.in_pos..]);
            c.in.items.len = rest;
            c.in_pos = 0;
        }
        c.in.ensureUnusedCapacity(self.gpa, read_chunk) catch {
            c.close_asap = true;
            return;
        };
        const dest = c.in.unusedCapacitySlice();
        const n = sys.read(c.fd, dest) catch |err| switch (err) {
            error.WouldBlock => return,
            else => {
                c.close_asap = true;
                return;
            },
        };
        if (n == 0) {
            c.close_asap = true;
            return;
        }
        c.in.items.len += n;
        self.stats.net_input_bytes += n;
        c.last_interaction_ms = self.now_ms;
        if (c.in.items.len > self.config.client_query_buffer_limit) {
            self.log.log(.warning, "Closing client that reached max query buffer length (id={d})", .{c.id});
            c.close_asap = true;
            return;
        }
        if (c.blocked == null) self.processInput(c);
    }

    /// Parses and executes as many complete requests as are buffered.
    pub fn processInput(self: *Server, c: *Client) void {
        while (!c.close_asap and !c.close_after_reply and c.blocked == null and c.in_pos < c.in.items.len) {
            const req = c.parser.parse(c.in.items[c.in_pos..]) catch |err| switch (err) {
                error.ProtocolError => {
                    var w = c.writer();
                    w.errFmt("ERR {s}", .{c.parser.err_msg}) catch {};
                    c.close_after_reply = true;
                    self.queueWrite(c);
                    break;
                },
                error.OutOfMemory => {
                    c.close_asap = true;
                    break;
                },
            } orelse break;
            if (req.args.len > 0) self.processCommand(c, req.args);
            c.in_pos += req.consumed;
        }
        if (c.in_pos == c.in.items.len) {
            c.in.clearRetainingCapacity();
            c.in_pos = 0;
            if (c.in.capacity > 1024 * 1024) c.in.clearAndFree(self.gpa);
        }
    }

    pub fn queueWrite(self: *Server, c: *Client) void {
        if (c.isFake() or c.pending_write) return;
        self.pending_writes.append(self.gpa, c) catch {
            c.close_asap = true;
            return;
        };
        c.pending_write = true;
    }

    fn writeToClient(self: *Server, c: *Client) void {
        while (c.pendingOutput() > 0) {
            const n = sys.send(c.fd, c.out.items[c.out_sent..]) catch |err| switch (err) {
                error.WouldBlock => break,
                else => {
                    c.close_asap = true;
                    return;
                },
            };
            c.out_sent += n;
            self.stats.net_output_bytes += n;
        }
        if (c.pendingOutput() == 0) {
            c.out.clearRetainingCapacity();
            c.out_sent = 0;
            if (c.out.capacity > 1024 * 1024) c.out.clearAndFree(self.gpa);
            if (c.want_write) {
                self.epoll.modify(c.fd, sys.Epoll.IN, c.id) catch {};
                c.want_write = false;
            }
            if (c.close_after_reply) c.close_asap = true;
        } else if (!c.want_write) {
            self.epoll.modify(c.fd, sys.Epoll.IN | sys.Epoll.OUT, c.id) catch {
                c.close_asap = true;
                return;
            };
            c.want_write = true;
        }
    }

    // ------------------------------------------------- command execution --

    /// Validates and dispatches one request from a client.
    pub fn processCommand(self: *Server, c: *Client, args: []const []const u8) void {
        self.processCommandInner(c, args) catch {
            var w = c.writer();
            w.err("ERR out of memory") catch {};
        };
        self.handleReadyKeys();
        self.queueWrite(c);
    }

    fn processCommandInner(self: *Server, c: *Client, args: []const []const u8) Allocator.Error!void {
        var w = c.writer();
        c.last_interaction_ms = self.now_ms;
        const cmd = commands.lookup(args[0]) orelse {
            if (c.in_multi) c.multi_error = true;
            var buf: [256]u8 = undefined;
            var fw: std.Io.Writer = .fixed(&buf);
            fw.print("ERR unknown command '{s}', with args beginning with: ", .{truncate(args[0], 128)}) catch {};
            for (args[1..]) |a| fw.print("'{s}' ", .{truncate(a, 128)}) catch break;
            try w.err(fw.buffered());
            return;
        };
        if (!cmd.arityOk(args.len)) {
            if (c.in_multi) c.multi_error = true;
            try w.errFmt("ERR wrong number of arguments for '{s}' command", .{cmd.name});
            return;
        }
        if (!c.authenticated and !cmd.flags.no_auth) {
            if (c.in_multi) c.multi_error = true;
            try w.err("NOAUTH Authentication required.");
            return;
        }
        if (c.inPubSubContext() and !cmd.flags.pubsub_ok) {
            try w.errFmt("ERR Can't execute '{s}': only (P|S)SUBSCRIBE / (P|S)UNSUBSCRIBE / PING / QUIT / RESET are allowed in this context", .{cmd.name});
            return;
        }
        if (c.in_multi and !cmd.flags.multi_control) {
            try c.enqueue(args);
            try w.simple("QUEUED");
            return;
        }
        try self.call(c, cmd, args);
    }

    fn truncate(s: []const u8, n: usize) []const u8 {
        return if (s.len > n) s[0..n] else s;
    }

    /// Executes a command and handles propagation. Also used by EXEC.
    pub fn call(self: *Server, c: *Client, cmd: *const Command, args: []const []const u8) Allocator.Error!void {
        if (!c.in_exec and !self.loading) self.now_ms = sys.nowMs();
        const dirty_before = self.dirty;
        var ctx: Ctx = .{
            .server = self,
            .client = c,
            .args = args,
            .w = c.writer(),
            .gpa = self.gpa,
        };
        c.last_command = cmd.name;
        c.commands_processed += 1;
        try cmd.handler(&ctx);
        self.stats.total_commands += 1;
        self.command_calls[commands.indexOf(cmd)] += 1;
        if (self.dirty != dirty_before and !ctx.custom_propagation and cmd.flags.write) {
            try self.propagate(c.db, args);
        }
    }

    /// Feeds a command to the AOF, wrapping EXEC blocks in MULTI/EXEC.
    pub fn propagate(self: *Server, db: usize, args: []const []const u8) Allocator.Error!void {
        if (self.loading or !self.aof.enabled) return;
        if (self.exec_depth > 0 and !self.exec_multi_emitted) {
            self.exec_multi_emitted = true;
            try self.aof.feed(db, &.{"MULTI"});
        }
        try self.aof.feed(db, args);
    }

    fn onKeyExpired(ctx: *anyopaque, db: *Db, key: []const u8) void {
        const self: *Server = @ptrCast(@alignCast(ctx));
        self.touchWatchedKey(db.id, key);
        self.dirty += 1;
        self.propagate(db.id, &.{ "DEL", key }) catch {};
    }

    // ------------------------------------------------------------ WATCH --

    pub fn watchKey(self: *Server, c: *Client, key: []const u8) Allocator.Error!void {
        if (c.isWatching(c.db, key)) return;
        const reg = &self.watched_keys[c.db];
        const gop = try reg.getOrPut(self.gpa, key);
        if (!gop.found_existing) {
            gop.key_ptr.* = self.gpa.dupe(u8, key) catch |err| {
                _ = reg.remove(key);
                return err;
            };
            gop.value_ptr.* = .empty;
        }
        try gop.value_ptr.append(self.gpa, c);
        const owned = try self.gpa.dupe(u8, key);
        errdefer self.gpa.free(owned);
        try c.watched.append(self.gpa, .{ .db = c.db, .key = owned });
    }

    pub fn unwatchAll(self: *Server, c: *Client) void {
        for (c.watched.items) |wk| {
            const reg = &self.watched_keys[wk.db];
            if (reg.getEntry(wk.key)) |e| {
                removeClient(e.value_ptr, c);
                if (e.value_ptr.items.len == 0) {
                    e.value_ptr.deinit(self.gpa);
                    const owned = e.key_ptr.*;
                    _ = reg.remove(wk.key);
                    self.gpa.free(owned);
                }
            }
            self.gpa.free(wk.key);
        }
        c.watched.clearRetainingCapacity();
        c.dirty_cas = false;
    }

    pub fn touchWatchedKey(self: *Server, db: usize, key: []const u8) void {
        const reg = &self.watched_keys[db];
        if (reg.count() == 0) return;
        const list = reg.get(key) orelse return;
        for (list.items) |c| c.dirty_cas = true;
    }

    /// FLUSHDB/FLUSHALL invalidate every WATCH on the affected databases.
    pub fn touchAllWatchedKeys(self: *Server, db: ?usize) void {
        for (self.watched_keys, 0..) |*reg, i| {
            if (db != null and db.? != i) continue;
            var it = reg.valueIterator();
            while (it.next()) |list| {
                for (list.items) |c| c.dirty_cas = true;
            }
        }
    }

    // ---------------------------------------------------------- pub/sub --

    fn subscribeTo(self: *Server, reg: *std.StringArrayHashMapUnmanaged(ClientList), mine: *std.StringArrayHashMapUnmanaged(void), c: *Client, name: []const u8) Allocator.Error!bool {
        if (mine.contains(name)) return false;
        const gop = try reg.getOrPut(self.gpa, name);
        if (!gop.found_existing) {
            gop.key_ptr.* = self.gpa.dupe(u8, name) catch |err| {
                _ = reg.swapRemove(name);
                return err;
            };
            gop.value_ptr.* = .empty;
        }
        try gop.value_ptr.append(self.gpa, c);
        const owned = try self.gpa.dupe(u8, name);
        errdefer self.gpa.free(owned);
        try mine.put(self.gpa, owned, {});
        return true;
    }

    fn unsubscribeFrom(self: *Server, reg: *std.StringArrayHashMapUnmanaged(ClientList), mine: *std.StringArrayHashMapUnmanaged(void), c: *Client, name: []const u8) bool {
        const kv = mine.fetchSwapRemove(name) orelse return false;
        if (reg.getEntry(name)) |e| {
            removeClient(e.value_ptr, c);
            if (e.value_ptr.items.len == 0) {
                e.value_ptr.deinit(self.gpa);
                const owned = e.key_ptr.*;
                _ = reg.swapRemove(name);
                self.gpa.free(owned);
            }
        }
        self.gpa.free(kv.key);
        return true;
    }

    fn subscriptionReply(c: *Client, kind: []const u8, name: ?[]const u8) Allocator.Error!void {
        var w = c.writer();
        try w.push(3);
        try w.bulk(kind);
        if (name) |n| try w.bulk(n) else try w.nullBulk();
        try w.int(@intCast(c.subscriptionCount()));
    }

    pub fn subscribe(self: *Server, c: *Client, channel: []const u8) Allocator.Error!void {
        _ = try self.subscribeTo(&self.channels, &c.channels, c, channel);
        try subscriptionReply(c, "subscribe", channel);
    }

    pub fn psubscribe(self: *Server, c: *Client, pattern: []const u8) Allocator.Error!void {
        _ = try self.subscribeTo(&self.patterns, &c.patterns, c, pattern);
        try subscriptionReply(c, "psubscribe", pattern);
    }

    pub fn unsubscribe(self: *Server, c: *Client, channel: []const u8, notify: bool) Allocator.Error!void {
        _ = self.unsubscribeFrom(&self.channels, &c.channels, c, channel);
        if (notify) try subscriptionReply(c, "unsubscribe", channel);
    }

    pub fn punsubscribe(self: *Server, c: *Client, pattern: []const u8, notify: bool) Allocator.Error!void {
        _ = self.unsubscribeFrom(&self.patterns, &c.patterns, c, pattern);
        if (notify) try subscriptionReply(c, "punsubscribe", pattern);
    }

    /// Unsubscribes from every channel. With `notify` and no channels, a
    /// single reply with a null channel is sent, as Redis does.
    pub fn unsubscribeAll(self: *Server, c: *Client, notify: bool) void {
        if (notify and c.channels.count() == 0) {
            subscriptionReply(c, "unsubscribe", null) catch {};
            return;
        }
        while (c.channels.count() > 0) {
            const name = self.gpa.dupe(u8, c.channels.keys()[0]) catch return;
            defer self.gpa.free(name);
            self.unsubscribe(c, name, notify) catch {};
        }
    }

    pub fn punsubscribeAll(self: *Server, c: *Client, notify: bool) void {
        if (notify and c.patterns.count() == 0) {
            subscriptionReply(c, "punsubscribe", null) catch {};
            return;
        }
        while (c.patterns.count() > 0) {
            const name = self.gpa.dupe(u8, c.patterns.keys()[0]) catch return;
            defer self.gpa.free(name);
            self.punsubscribe(c, name, notify) catch {};
        }
    }

    /// Delivers a message to channel and pattern subscribers. Returns the
    /// number of clients that received it.
    pub fn publish(self: *Server, channel: []const u8, message: []const u8) Allocator.Error!usize {
        var receivers: usize = 0;
        if (self.channels.get(channel)) |list| {
            for (list.items) |c| {
                var w = c.writer();
                try w.push(3);
                try w.bulk("message");
                try w.bulk(channel);
                try w.bulk(message);
                self.afterPush(c);
                receivers += 1;
            }
        }
        var it = self.patterns.iterator();
        while (it.next()) |e| {
            if (!glob.match(e.key_ptr.*, channel)) continue;
            for (e.value_ptr.items) |c| {
                var w = c.writer();
                try w.push(4);
                try w.bulk("pmessage");
                try w.bulk(e.key_ptr.*);
                try w.bulk(channel);
                try w.bulk(message);
                self.afterPush(c);
                receivers += 1;
            }
        }
        self.stats.pubsub_messages += 1;
        return receivers;
    }

    fn afterPush(self: *Server, c: *Client) void {
        if (c.pendingOutput() > self.config.pubsub_output_limit) {
            self.log.log(.warning, "Client id={d} scheduled to be closed for overcoming of output buffer limits", .{c.id});
            c.close_asap = true;
            return;
        }
        self.queueWrite(c);
    }

    // --------------------------------------------------------- blocking --

    /// Blocks the client on `keys` until one becomes ready or the
    /// deadline passes. Takes ownership of `op` allocations.
    pub fn blockClient(self: *Server, c: *Client, keys: []const []const u8, deadline_ms: i64, op: client_mod.BlockOp) Allocator.Error!void {
        const owned = try self.gpa.alloc([]u8, keys.len);
        var n: usize = 0;
        errdefer {
            for (owned[0..n]) |k| self.gpa.free(k);
            self.gpa.free(owned);
        }
        for (keys) |k| {
            owned[n] = try self.gpa.dupe(u8, k);
            n += 1;
        }
        const reg = &self.blocking_keys[c.db];
        for (owned) |k| {
            const gop = try reg.getOrPut(self.gpa, k);
            if (!gop.found_existing) {
                gop.key_ptr.* = try self.gpa.dupe(u8, k);
                gop.value_ptr.* = .empty;
            }
            if (std.mem.indexOfScalar(*Client, gop.value_ptr.items, c) == null) {
                try gop.value_ptr.append(self.gpa, c);
            }
        }
        c.blocked = .{ .db = c.db, .keys = owned, .deadline_ms = deadline_ms, .op = op };
        self.blocked_clients += 1;
    }

    /// Removes the client from every blocking list. When `resume_input`,
    /// buffered pipelined commands are processed before the next sleep.
    pub fn unblockClient(self: *Server, c: *Client, resume_input: bool) void {
        var state = c.blocked orelse return;
        const reg = &self.blocking_keys[state.db];
        for (state.keys) |k| {
            if (reg.getEntry(k)) |e| {
                removeClient(e.value_ptr, c);
                if (e.value_ptr.items.len == 0) {
                    e.value_ptr.deinit(self.gpa);
                    const owned = e.key_ptr.*;
                    _ = reg.swapRemove(k);
                    self.gpa.free(owned);
                }
            }
        }
        state.deinit(self.gpa);
        c.blocked = null;
        self.blocked_clients -= 1;
        if (resume_input and !c.resume_pending and c.in_pos < c.in.items.len) {
            self.unblocked.append(self.gpa, c) catch return;
            c.resume_pending = true;
        }
    }

    pub fn signalKeyAsReady(self: *Server, db: usize, key: []const u8) Allocator.Error!void {
        if (self.blocked_clients == 0) return;
        if (!self.blocking_keys[db].contains(key)) return;
        for (self.ready_keys.items) |rk| {
            if (rk.db == db and std.mem.eql(u8, rk.key, key)) return;
        }
        const owned = try self.gpa.dupe(u8, key);
        errdefer self.gpa.free(owned);
        try self.ready_keys.append(self.gpa, .{ .db = db, .key = owned });
    }

    /// Serves clients blocked on keys that received data. Serving a
    /// BLMOVE can make another key ready, so this loops to a fixpoint.
    pub fn handleReadyKeys(self: *Server) void {
        while (self.ready_keys.items.len > 0) {
            const batch = self.ready_keys.toOwnedSlice(self.gpa) catch return;
            defer {
                for (batch) |rk| self.gpa.free(rk.key);
                self.gpa.free(batch);
            }
            for (batch) |rk| {
                while (true) {
                    const list = self.blocking_keys[rk.db].getPtr(rk.key) orelse break;
                    if (list.items.len == 0) break;
                    const c = list.items[0];
                    const served = self.serveBlockedClient(c, rk.db, rk.key) catch false;
                    if (!served) break;
                }
            }
        }
    }

    fn serveBlockedClient(self: *Server, c: *Client, db_index: usize, key: []const u8) Allocator.Error!bool {
        const state = c.blocked.?;
        const db = &self.dbs[db_index];
        const v = db.lookupWrite(key) orelse return false;
        var w = c.writer();
        self.now_ms = sys.nowMs();
        switch (state.op) {
            .pop => |end| {
                if (v.* != .list or v.list.len == 0) return false;
                const item = (if (end == .left) v.list.popFront(self.gpa) else v.list.popBack(self.gpa)).?;
                defer self.gpa.free(item);
                try w.array(2);
                try w.bulk(key);
                try w.bulk(item);
                const empty = v.list.len == 0;
                try self.propagate(db_index, &.{ if (end == .left) "LPOP" else "RPOP", key });
                if (empty) _ = db.delete(key);
                self.modifiedKey(db_index, key);
            },
            .move => |m| {
                if (v.* != .list or v.list.len == 0) return false;
                if (db.lookupWrite(m.dest)) |dv| {
                    if (dv.* != .list) {
                        try w.err(ctx_mod.msg.wrong_type);
                        self.unblockClient(c, true);
                        self.queueWrite(c);
                        return true;
                    }
                }
                const item = (if (m.from == .left) v.list.popFront(self.gpa) else v.list.popBack(self.gpa)).?;
                defer self.gpa.free(item);
                if (v.list.len == 0) _ = db.delete(key);
                const dest = db.lookupWrite(m.dest) orelse try db.add(m.dest, .{ .list = .empty });
                if (m.to == .left) try dest.list.pushFront(self.gpa, item) else try dest.list.pushBack(self.gpa, item);
                try w.bulk(item);
                try self.propagate(db_index, &.{ "LMOVE", key, m.dest, if (m.from == .left) "LEFT" else "RIGHT", if (m.to == .left) "LEFT" else "RIGHT" });
                self.modifiedKey(db_index, key);
                self.modifiedKey(db_index, m.dest);
                try self.signalKeyAsReady(db_index, m.dest);
            },
            .zpop => |which| {
                if (v.* != .zset or v.zset.len() == 0) return false;
                const popped = (try v.zset.popExtreme(self.gpa, which == .max)).?;
                defer self.gpa.free(popped.member);
                try w.array(3);
                try w.bulk(key);
                try w.bulk(popped.member);
                try w.double(popped.score);
                try self.propagate(db_index, &.{ if (which == .max) "ZPOPMAX" else "ZPOPMIN", key });
                if (v.zset.len() == 0) _ = db.delete(key);
                self.modifiedKey(db_index, key);
            },
        }
        self.unblockClient(c, true);
        self.queueWrite(c);
        return true;
    }

    fn modifiedKey(self: *Server, db: usize, key: []const u8) void {
        self.dirty += 1;
        self.touchWatchedKey(db, key);
    }

    fn handleBlockedTimeouts(self: *Server) void {
        if (self.blocked_clients == 0) return;
        const now = sys.nowMs();
        var i: usize = 0;
        while (i < self.clients.count()) : (i += 1) {
            const c = self.clients.values()[i];
            const b = c.blocked orelse continue;
            if (b.deadline_ms == 0 or b.deadline_ms > now) continue;
            var w = c.writer();
            switch (b.op) {
                .move => w.nullBulk() catch {},
                else => w.nullArray() catch {},
            }
            self.unblockClient(c, true);
            self.queueWrite(c);
        }
    }

    // ------------------------------------------------------------- misc --

    pub fn randomSeed(self: *Server) u64 {
        return self.rng.random().int(u64);
    }

    pub fn usedMemory(self: *const Server) usize {
        const t = self.tracker orelse return 0;
        return t.used;
    }

    pub fn peakMemory(self: *const Server) usize {
        const t = self.tracker orelse return 0;
        return t.peak;
    }
};

test {
    _ = commands;
}
