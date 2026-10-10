//! Per-connection state: buffers, protocol version, transaction queue,
//! subscriptions, watched keys and blocking state.

const std = @import("std");
const sys = @import("../sys.zig");
const resp = @import("../resp.zig");
const Allocator = std.mem.Allocator;

/// A command captured by MULTI. Arguments are copied because the input
/// buffer they came from is compacted between reads.
pub const QueuedCommand = struct {
    args: [][]u8,

    pub fn deinit(self: *QueuedCommand, gpa: Allocator) void {
        for (self.args) |a| gpa.free(a);
        gpa.free(self.args);
    }
};

pub const WatchedKey = struct {
    db: usize,
    key: []u8,
};

pub const End = enum { left, right };

/// What a blocked client is waiting to do once one of its keys is ready.
pub const BlockOp = union(enum) {
    /// BLPOP / BRPOP: reply with [key, element].
    pop: End,
    /// BLMOVE / BRPOPLPUSH: move to `dest` and reply with the element.
    move: struct { from: End, to: End, dest: []u8 },
    /// BZPOPMIN / BZPOPMAX: reply with [key, member, score].
    zpop: enum { min, max },
};

pub const BlockState = struct {
    db: usize,
    keys: [][]u8,
    /// Absolute deadline in ms, or 0 to wait forever.
    deadline_ms: i64,
    op: BlockOp,

    pub fn deinit(self: *BlockState, gpa: Allocator) void {
        for (self.keys) |k| gpa.free(k);
        gpa.free(self.keys);
        switch (self.op) {
            .move => |m| gpa.free(m.dest),
            else => {},
        }
    }
};

pub const Client = struct {
    gpa: Allocator,
    id: u64,
    /// -1 for the internal client used while replaying the AOF.
    fd: sys.fd_t,
    addr: sys.Ipv4,

    in: std.ArrayList(u8) = .empty,
    /// Bytes at the front of `in` already consumed by parsed commands.
    in_pos: usize = 0,
    parser: resp.RequestParser,
    out: std.ArrayList(u8) = .empty,
    /// Bytes of `out` already written to the socket.
    out_sent: usize = 0,
    /// Whether EPOLLOUT is currently registered for this client.
    want_write: bool = false,
    /// Whether this client is queued in the server's pending-write list.
    pending_write: bool = false,

    db: usize = 0,
    proto: u8 = 2,
    name: ?[]u8 = null,
    authenticated: bool = false,

    in_multi: bool = false,
    /// A queued command had a syntax/arity error; EXEC must abort.
    multi_error: bool = false,
    /// A watched key changed; EXEC must return a null reply.
    dirty_cas: bool = false,
    /// True while EXEC is running the queued commands.
    in_exec: bool = false,
    queue: std.ArrayList(QueuedCommand) = .empty,
    watched: std.ArrayList(WatchedKey) = .empty,

    channels: std.StringArrayHashMapUnmanaged(void) = .empty,
    patterns: std.StringArrayHashMapUnmanaged(void) = .empty,

    blocked: ?BlockState = null,
    /// Set when the client was unblocked and has buffered input to resume.
    resume_pending: bool = false,

    close_after_reply: bool = false,
    close_asap: bool = false,

    created_ms: i64,
    last_interaction_ms: i64,
    commands_processed: u64 = 0,
    last_command: []const u8 = "NULL",

    pub fn init(gpa: Allocator, id: u64, fd: sys.fd_t, addr: sys.Ipv4, now_ms: i64) Client {
        return .{
            .gpa = gpa,
            .id = id,
            .fd = fd,
            .addr = addr,
            .parser = resp.RequestParser.init(gpa),
            .created_ms = now_ms,
            .last_interaction_ms = now_ms,
        };
    }

    pub fn deinit(self: *Client) void {
        const gpa = self.gpa;
        self.in.deinit(gpa);
        self.parser.deinit();
        self.out.deinit(gpa);
        if (self.name) |n| gpa.free(n);
        self.discardQueue();
        self.queue.deinit(gpa);
        for (self.watched.items) |w| gpa.free(w.key);
        self.watched.deinit(gpa);
        for (self.channels.keys()) |k| gpa.free(k);
        self.channels.deinit(gpa);
        for (self.patterns.keys()) |k| gpa.free(k);
        self.patterns.deinit(gpa);
        if (self.blocked) |*b| b.deinit(gpa);
    }

    pub fn writer(self: *Client) resp.Writer {
        return .{ .gpa = self.gpa, .out = &self.out, .proto = self.proto };
    }

    pub fn isFake(self: *const Client) bool {
        return self.fd < 0;
    }

    pub fn subscriptionCount(self: *const Client) usize {
        return self.channels.count() + self.patterns.count();
    }

    /// RESP2 clients with subscriptions may only issue pub/sub commands.
    pub fn inPubSubContext(self: *const Client) bool {
        return self.proto < 3 and self.subscriptionCount() > 0;
    }

    pub fn pendingOutput(self: *const Client) usize {
        return self.out.items.len - self.out_sent;
    }

    pub fn discardQueue(self: *Client) void {
        for (self.queue.items) |*q| q.deinit(self.gpa);
        self.queue.clearRetainingCapacity();
        self.in_multi = false;
        self.multi_error = false;
    }

    pub fn enqueue(self: *Client, args: []const []const u8) Allocator.Error!void {
        const copy = try self.gpa.alloc([]u8, args.len);
        var n: usize = 0;
        errdefer {
            for (copy[0..n]) |a| self.gpa.free(a);
            self.gpa.free(copy);
        }
        for (args) |a| {
            copy[n] = try self.gpa.dupe(u8, a);
            n += 1;
        }
        try self.queue.append(self.gpa, .{ .args = copy });
    }

    pub fn isWatching(self: *const Client, db: usize, key: []const u8) bool {
        for (self.watched.items) |w| {
            if (w.db == db and std.mem.eql(u8, w.key, key)) return true;
        }
        return false;
    }

    /// Renders the line used by CLIENT LIST / CLIENT INFO.
    pub fn describe(self: *const Client, buf: *std.ArrayList(u8), now_ms: i64) Allocator.Error!void {
        var flags_buf: [8]u8 = undefined;
        var nf: usize = 0;
        if (self.in_multi) {
            flags_buf[nf] = 'x';
            nf += 1;
        }
        if (self.blocked != null) {
            flags_buf[nf] = 'b';
            nf += 1;
        }
        if (self.subscriptionCount() > 0) {
            flags_buf[nf] = 'P';
            nf += 1;
        }
        if (nf == 0) {
            flags_buf[0] = 'N';
            nf = 1;
        }
        const a = self.addr.addr;
        try buf.print(self.gpa, "id={d} addr={d}.{d}.{d}.{d}:{d} fd={d} name={s} age={d} idle={d} flags={s} db={d} sub={d} psub={d} multi={d} qbuf={d} obl={d} cmd={s} resp={d}\n", .{
            self.id,
            a[0],
            a[1],
            a[2],
            a[3],
            self.addr.port,
            self.fd,
            self.name orelse "",
            @divTrunc(now_ms - self.created_ms, 1000),
            @divTrunc(now_ms - self.last_interaction_ms, 1000),
            flags_buf[0..nf],
            self.db,
            self.channels.count(),
            self.patterns.count(),
            if (self.in_multi) @as(i64, @intCast(self.queue.items.len)) else -1,
            self.in.items.len,
            self.pendingOutput(),
            self.last_command,
            self.proto,
        });
    }
};

const testing = std.testing;

test "queue copies arguments and discards cleanly" {
    var c = Client.init(testing.allocator, 1, -1, .{ .addr = .{ 127, 0, 0, 1 }, .port = 0 }, 0);
    defer c.deinit();
    var arg = [_]u8{ 'a', 'b' };
    try c.enqueue(&.{ "SET", &arg });
    arg[0] = 'z';
    try testing.expectEqualStrings("ab", c.queue.items[0].args[1]);
    c.in_multi = true;
    c.discardQueue();
    try testing.expect(!c.in_multi);
    try testing.expectEqual(@as(usize, 0), c.queue.items.len);
}

test "describe renders a CLIENT LIST line" {
    var c = Client.init(testing.allocator, 7, 5, .{ .addr = .{ 10, 0, 0, 2 }, .port = 5555 }, 1000);
    defer c.deinit();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try c.describe(&buf, 3000);
    try testing.expect(std.mem.startsWith(u8, buf.items, "id=7 addr=10.0.0.2:5555 fd=5 name= age=2 idle=2 flags=N db=0"));
}
