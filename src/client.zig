//! A small blocking RESP client used by zedis-cli, the compatibility
//! suite and the benchmark tool. Replies are decoded into `resp.Value`
//! trees owned by a per-connection arena that is reset on every call.

const std = @import("std");
const sys = @import("sys.zig");
const resp = @import("resp.zig");
const Allocator = std.mem.Allocator;

pub const Connection = struct {
    gpa: Allocator,
    fd: sys.fd_t,
    in: std.ArrayList(u8) = .empty,
    in_pos: usize = 0,
    out: std.ArrayList(u8) = .empty,
    arena: std.heap.ArenaAllocator,

    pub const Error = sys.Error || resp.DecodeError || error{ConnectionClosed};

    pub fn connect(gpa: Allocator, host: []const u8, port: u16) (sys.Error || Allocator.Error)!Connection {
        const addr = try sys.Ipv4.parse(host, port);
        const fd = try sys.connectTcp(addr);
        return .{ .gpa = gpa, .fd = fd, .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn close(self: *Connection) void {
        sys.close(self.fd);
        self.in.deinit(self.gpa);
        self.out.deinit(self.gpa);
        self.arena.deinit();
    }

    /// Queues a command without sending it (for pipelining).
    pub fn append(self: *Connection, args: []const []const u8) Allocator.Error!void {
        try resp.encodeCommand(self.gpa, &self.out, args);
    }

    /// Queues raw bytes, for protocol-level tests.
    pub fn appendRaw(self: *Connection, bytes: []const u8) Allocator.Error!void {
        try self.out.appendSlice(self.gpa, bytes);
    }

    pub fn flush(self: *Connection) Error!void {
        try sys.sendAll(self.fd, self.out.items);
        self.out.clearRetainingCapacity();
    }

    /// Reads one reply. The returned value is valid until the next call
    /// to `read`, `call` or `resetArena`.
    pub fn read(self: *Connection) Error!resp.Value {
        while (true) {
            if (self.in_pos < self.in.items.len) {
                if (try resp.decode(self.arena.allocator(), self.in.items[self.in_pos..])) |r| {
                    self.in_pos += r.consumed;
                    return r.value;
                }
            }
            if (self.in_pos > 0) {
                const rest = self.in.items.len - self.in_pos;
                std.mem.copyForwards(u8, self.in.items[0..rest], self.in.items[self.in_pos..]);
                self.in.items.len = rest;
                self.in_pos = 0;
            }
            try self.in.ensureUnusedCapacity(self.gpa, 16 * 1024);
            const n = try sys.read(self.fd, self.in.unusedCapacitySlice());
            if (n == 0) return error.ConnectionClosed;
            self.in.items.len += n;
        }
    }

    /// Frees memory used by previously returned replies.
    pub fn resetArena(self: *Connection) void {
        _ = self.arena.reset(.retain_capacity);
    }

    /// Sends a command and waits for its reply.
    pub fn call(self: *Connection, args: []const []const u8) Error!resp.Value {
        self.resetArena();
        try self.append(args);
        try self.flush();
        return self.read();
    }

    /// Waits up to `timeout_ms` for data. Returns false on timeout.
    pub fn waitReadable(self: *Connection, timeout_ms: i32) bool {
        if (self.in_pos < self.in.items.len) return true;
        var fds = [_]std.os.linux.pollfd{.{ .fd = self.fd, .events = std.os.linux.POLL.IN, .revents = 0 }};
        const rc = std.os.linux.poll(&fds, 1, timeout_ms);
        return std.os.linux.errno(rc) == .SUCCESS and rc > 0;
    }
};

const testing = std.testing;

test "client talks to a raw socket peer" {
    const lfd = try sys.listenTcp(try sys.Ipv4.parse("127.0.0.1", 0), 4);
    defer sys.close(lfd);
    const port = try sys.localPort(lfd);
    var conn = try Connection.connect(testing.allocator, "127.0.0.1", port);
    defer conn.close();
    var peer: sys.fd_t = -1;
    var tries: usize = 0;
    while (tries < 200) : (tries += 1) {
        const a = sys.accept(lfd) catch {
            sys.sleepMs(1);
            continue;
        };
        peer = a.fd;
        break;
    }
    defer sys.close(peer);
    try conn.append(&.{"PING"});
    try conn.flush();
    // Answer with a reply split over two writes.
    var got: [64]u8 = undefined;
    var n: usize = 0;
    while (n < 14) n += sys.read(peer, got[n..]) catch {
        sys.sleepMs(1);
        continue;
    };
    try testing.expectEqualStrings("*1\r\n$4\r\nPING\r\n", got[0..n]);
    try sys.sendAll(peer, "+PO");
    try sys.sendAll(peer, "NG\r\n");
    const v = try conn.read();
    try testing.expectEqualStrings("PONG", v.simple);
}
