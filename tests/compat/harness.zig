//! Assertion harness for the compatibility suite. Every check sends a real
//! command over TCP and compares the decoded reply. Failures are recorded
//! and reported at the end instead of aborting, so one run shows the whole
//! picture.

const std = @import("std");
const zedis = @import("zedis");
const resp = zedis.resp;
const Connection = zedis.client.Connection;
const Allocator = std.mem.Allocator;

pub const Expect = union(enum) {
    ok,
    simple: []const u8,
    int: i64,
    bulk: []const u8,
    nil,
    /// Error reply starting with this prefix.
    err: []const u8,
    /// Array whose scalar elements render to these strings, in order.
    strs: []const []const u8,
    /// Array of bulk strings in any order.
    unordered: []const []const u8,
    /// Array (or set/map) with this many top-level elements.
    len: usize,
    /// RESP3 double or RESP2 bulk string holding the formatted double.
    double: []const u8,
    boolean: bool,
    /// Any non-error reply.
    any,
};

pub const Failure = struct {
    case: []const u8,
    command: []const u8,
    detail: []const u8,
};

pub const Harness = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    host: []const u8,
    port: u16,
    conn: Connection,
    case: []const u8 = "",
    checks: usize = 0,
    failures: std.ArrayList(Failure) = .empty,
    /// True when talking to a server that is not zedis (for example a real
    /// Redis used to validate the expectations themselves).
    external: bool,

    pub fn init(gpa: Allocator, host: []const u8, port: u16, external: bool) !Harness {
        return .{
            .gpa = gpa,
            .arena = std.heap.ArenaAllocator.init(gpa),
            .host = host,
            .port = port,
            .conn = try Connection.connect(gpa, host, port),
            .external = external,
        };
    }

    pub fn deinit(self: *Harness) void {
        self.conn.close();
        self.failures.deinit(self.gpa);
        self.arena.deinit();
    }

    /// Opens an additional connection (pub/sub, WATCH and blocking tests).
    pub fn connect(self: *Harness) !Connection {
        return Connection.connect(self.gpa, self.host, self.port);
    }

    /// Reconnects the main connection, for example after a server restart.
    pub fn reconnect(self: *Harness, port: u16) !void {
        self.conn.close();
        self.port = port;
        self.conn = try Connection.connect(self.gpa, self.host, port);
    }

    fn describe(self: *Harness, args: []const []const u8) []const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (args, 0..) |a, i| {
            if (i > 0) out.append(self.arena.allocator(), ' ') catch {};
            const shown = if (a.len > 40) a[0..40] else a;
            out.appendSlice(self.arena.allocator(), shown) catch {};
        }
        return out.items;
    }

    pub fn render(self: *Harness, v: resp.Value) []const u8 {
        var w: std.Io.Writer.Allocating = .init(self.arena.allocator());
        v.render(&w.writer, 0) catch {};
        const s = w.written();
        return std.mem.trimEnd(u8, s, "\n");
    }

    pub fn fail(self: *Harness, args: []const []const u8, comptime fmt: []const u8, fmt_args: anytype) void {
        const detail = std.fmt.allocPrint(self.arena.allocator(), fmt, fmt_args) catch "(oom)";
        self.failures.append(self.gpa, .{
            .case = self.case,
            .command = self.describe(args),
            .detail = detail,
        }) catch {};
    }

    /// Sends a command on the main connection and returns the raw reply.
    pub fn call(self: *Harness, args: []const []const u8) !resp.Value {
        return self.callOn(&self.conn, args);
    }

    pub fn callOn(self: *Harness, conn: *Connection, args: []const []const u8) !resp.Value {
        _ = self;
        return conn.call(args);
    }

    pub fn expect(self: *Harness, args: []const []const u8, e: Expect) !void {
        try self.expectOn(&self.conn, args, e);
    }

    pub fn expectOn(self: *Harness, conn: *Connection, args: []const []const u8, e: Expect) !void {
        const v = try conn.call(args);
        self.check(args, v, e);
    }

    /// Reads the next reply (for pipelined or pushed data) and checks it.
    pub fn expectRead(self: *Harness, conn: *Connection, label: []const []const u8, e: Expect) !void {
        const v = try conn.read();
        self.check(label, v, e);
    }

    pub fn check(self: *Harness, args: []const []const u8, v: resp.Value, e: Expect) void {
        self.checks += 1;
        if (!self.matches(v, e)) {
            self.fail(args, "expected {s}, got {s}", .{ self.describeExpect(e), self.render(v) });
        }
    }

    fn describeExpect(self: *Harness, e: Expect) []const u8 {
        const a = self.arena.allocator();
        return switch (e) {
            .ok => "OK",
            .simple => |s| std.fmt.allocPrint(a, "+{s}", .{s}) catch "?",
            .int => |i| std.fmt.allocPrint(a, "(integer) {d}", .{i}) catch "?",
            .bulk => |s| std.fmt.allocPrint(a, "\"{s}\"", .{s}) catch "?",
            .nil => "(nil)",
            .err => |s| std.fmt.allocPrint(a, "error starting with '{s}'", .{s}) catch "?",
            .strs => |l| std.fmt.allocPrint(a, "{d} strings in order {any}", .{ l.len, l }) catch "?",
            .unordered => |l| std.fmt.allocPrint(a, "{d} strings in any order", .{l.len}) catch "?",
            .len => |n| std.fmt.allocPrint(a, "an aggregate of {d} elements", .{n}) catch "?",
            .double => |s| std.fmt.allocPrint(a, "double {s}", .{s}) catch "?",
            .boolean => |b| if (b) "true" else "false",
            .any => "any non-error reply",
        };
    }

    fn matches(self: *Harness, v: resp.Value, e: Expect) bool {
        _ = self;
        return switch (e) {
            .ok => v == .simple and std.mem.eql(u8, v.simple, "OK"),
            .simple => |s| v == .simple and std.mem.eql(u8, v.simple, s),
            .int => |i| v == .int and v.int == i,
            .bulk => |s| (v == .bulk or v == .verbatim) and std.mem.eql(u8, v.str().?, s),
            .nil => v == .nil,
            .err => |p| v == .err and std.mem.startsWith(u8, v.err, p),
            .strs => |l| blk: {
                const items = v.items() orelse break :blk false;
                if (items.len != l.len) break :blk false;
                for (items, l) |it, want| {
                    var ibuf: [24]u8 = undefined;
                    const s = scalarText(it, &ibuf) orelse break :blk false;
                    if (!std.mem.eql(u8, s, want)) break :blk false;
                }
                break :blk true;
            },
            .unordered => |l| blk: {
                const items = v.items() orelse break :blk false;
                if (items.len != l.len) break :blk false;
                for (l) |want| {
                    var found = false;
                    for (items) |it| {
                        if (it.str()) |s| if (std.mem.eql(u8, s, want)) {
                            found = true;
                            break;
                        };
                    }
                    if (!found) break :blk false;
                }
                break :blk true;
            },
            .len => |n| blk: {
                const items = v.items() orelse break :blk false;
                const count = if (v == .map) items.len / 2 else items.len;
                break :blk count == n;
            },
            .double => |s| switch (v) {
                .bulk => |b| std.mem.eql(u8, b, s),
                .double => |d| blk: {
                    var buf: [zedis.num.max_double_chars]u8 = undefined;
                    break :blk std.mem.eql(u8, zedis.num.formatDouble(&buf, d), s);
                },
                else => false,
            },
            .boolean => |b| switch (v) {
                .boolean => |x| x == b,
                .int => |x| x == @intFromBool(b),
                else => false,
            },
            .any => v != .err,
        };
    }

    /// Text of a scalar reply; integers and doubles are formatted the way
    /// RESP2 would carry them as strings.
    fn scalarText(v: resp.Value, buf: *[24]u8) ?[]const u8 {
        return switch (v) {
            .int => |i| std.fmt.bufPrint(buf, "{d}", .{i}) catch null,
            .double => |d| blk: {
                var dbuf: [zedis.num.max_double_chars]u8 = undefined;
                const t = zedis.num.formatDouble(&dbuf, d);
                if (t.len > buf.len) break :blk null;
                @memcpy(buf[0..t.len], t);
                break :blk buf[0..t.len];
            },
            else => v.str(),
        };
    }

    /// Asserts a free-form condition.
    pub fn assert(self: *Harness, cond: bool, comptime what: []const u8, args: anytype) void {
        self.checks += 1;
        if (!cond) self.fail(&.{}, what, args);
    }
};
