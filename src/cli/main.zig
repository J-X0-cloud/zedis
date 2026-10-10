//! zedis-cli: a minimal redis-cli compatible command line client.
//!
//!   zedis-cli [-h host] [-p port] [-a password] [-n db] [-3] [--raw] [cmd [arg ...]]
//!
//! With a command it runs once and prints the reply; otherwise it reads
//! commands from stdin, one per line, using redis-cli quoting rules.

const std = @import("std");
const zedis = @import("zedis");
const sys = zedis.sys;
const resp = zedis.resp;
const Connection = zedis.client.Connection;

const Options = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 6379,
    password: ?[]const u8 = null,
    db: ?[]const u8 = null,
    resp3: bool = false,
    raw: bool = false,
    command: []const []const u8 = &.{},
};

const usage =
    \\Usage: zedis-cli [OPTIONS] [cmd [arg [arg ...]]]
    \\  -h <hostname>   Server hostname (default: 127.0.0.1).
    \\  -p <port>       Server port (default: 6379).
    \\  -a <password>   Password to use when connecting to the server.
    \\  -n <db>         Database number.
    \\  -3              Start the session in RESP3 protocol mode.
    \\  --raw           Use raw formatting for replies.
    \\  --help          Output this help and exit.
    \\
;

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt ++ "\n", args);
    std.process.exit(1);
}

fn parseArgs(args: []const []const u8) Options {
    var o: Options = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        const has_next = i + 1 < args.len;
        if (std.mem.eql(u8, a, "-h") and has_next) {
            o.host = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, a, "-p") and has_next) {
            o.port = std.fmt.parseInt(u16, args[i + 1], 10) catch fail("Invalid port: {s}", .{args[i + 1]});
            i += 1;
        } else if (std.mem.eql(u8, a, "-a") and has_next) {
            o.password = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, a, "-n") and has_next) {
            o.db = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, a, "-3")) {
            o.resp3 = true;
        } else if (std.mem.eql(u8, a, "--raw")) {
            o.raw = true;
        } else if (std.mem.eql(u8, a, "--help")) {
            sys.writeAll(1, usage) catch {};
            std.process.exit(0);
        } else {
            o.command = args[i..];
            break;
        }
    }
    return o;
}

const Output = struct {
    buf: [16 * 1024]u8 = undefined,
    writer: std.Io.Writer = undefined,

    fn init(self: *Output) void {
        self.writer = .fixed(&self.buf);
    }

    fn flush(self: *Output) void {
        sys.writeAll(1, self.writer.buffered()) catch {};
        self.writer = .fixed(&self.buf);
    }
};

fn printValue(out: *Output, v: resp.Value, raw: bool) void {
    // Render into a growable buffer so large replies are not truncated.
    var list: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer list.deinit();
    const w = &list.writer;
    if (raw) {
        renderRaw(w, v) catch return;
    } else {
        v.render(w, 0) catch return;
    }
    out.flush();
    sys.writeAll(1, list.written()) catch {};
}

fn renderRaw(w: *std.Io.Writer, v: resp.Value) std.Io.Writer.Error!void {
    switch (v) {
        .simple, .bulk, .verbatim, .big_number => |s| try w.print("{s}\n", .{s}),
        .err => |s| try w.print("{s}\n", .{s}),
        .int => |i| try w.print("{d}\n", .{i}),
        .nil => try w.writeAll("\n"),
        .double => |d| {
            var buf: [zedis.num.max_double_chars]u8 = undefined;
            try w.print("{s}\n", .{zedis.num.formatDouble(&buf, d)});
        },
        .boolean => |b| try w.print("{d}\n", .{@intFromBool(b)}),
        .array, .set, .push, .map => |items| for (items) |item| try renderRaw(w, item),
    }
}

fn isSubscribe(args: []const []const u8) bool {
    if (args.len == 0) return false;
    return std.ascii.eqlIgnoreCase(args[0], "subscribe") or std.ascii.eqlIgnoreCase(args[0], "psubscribe");
}

fn runCommand(conn: *Connection, out: *Output, args: []const []const u8, raw: bool) !void {
    const reply = conn.call(args) catch |err| switch (err) {
        // SHUTDOWN closes the connection without replying.
        error.ConnectionClosed => if (std.ascii.eqlIgnoreCase(args[0], "shutdown")) return else {
            fail("Error: Server closed the connection", .{});
        },
        else => return err,
    };
    printValue(out, reply, raw);
    if (isSubscribe(args)) {
        // Read every subscription confirmation, then stream messages.
        var i: usize = 2;
        while (i < args.len) : (i += 1) printValue(out, try conn.read(), raw);
        while (true) {
            conn.resetArena();
            printValue(out, try conn.read(), raw);
        }
    }
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const gpa = init.gpa;
    const argv = try init.minimal.args.toSlice(arena);
    var args_list: std.ArrayList([]const u8) = .empty;
    for (argv[1..]) |a| try args_list.append(arena, a);
    var opts = parseArgs(args_list.items);
    // Like redis-cli, default to raw output when stdout is not a terminal.
    if (!sys.isTty(1)) opts.raw = true;
    sys.ignoreSigpipe();

    var conn = Connection.connect(gpa, opts.host, opts.port) catch |err| {
        fail("Could not connect to Redis at {s}:{d}: {s}", .{ opts.host, opts.port, @errorName(err) });
    };
    defer conn.close();
    var out: Output = .{};
    out.init();

    if (opts.password) |p| {
        const r = try conn.call(&.{ "AUTH", p });
        if (r == .err) fail("AUTH failed: {s}", .{r.err});
    }
    if (opts.resp3) {
        const r = try conn.call(&.{ "HELLO", "3" });
        if (r == .err) fail("HELLO 3 failed: {s}", .{r.err});
    }
    if (opts.db) |d| {
        const r = try conn.call(&.{ "SELECT", d });
        if (r == .err) fail("SELECT failed: {s}", .{r.err});
    }

    if (opts.command.len > 0) {
        try runCommand(&conn, &out, opts.command, opts.raw);
        out.flush();
        return;
    }

    // Interactive / scripted mode: one command per line from stdin.
    const interactive = sys.isTty(0);
    var line_buf: std.ArrayList(u8) = .empty;
    defer line_buf.deinit(gpa);
    var read_buf: [4096]u8 = undefined;
    var prompt_buf: [128]u8 = undefined;
    const prompt = std.fmt.bufPrint(&prompt_buf, "{s}:{d}> ", .{ opts.host, opts.port }) catch "> ";
    while (true) {
        if (interactive) sys.writeAll(1, prompt) catch {};
        // Read one line.
        const line = while (true) {
            if (std.mem.indexOfScalar(u8, line_buf.items, '\n')) |nl| break line_buf.items[0..nl];
            const n = sys.read(0, &read_buf) catch 0;
            if (n == 0) {
                if (line_buf.items.len == 0) return;
                try line_buf.append(gpa, '\n');
                continue;
            }
            try line_buf.appendSlice(gpa, read_buf[0..n]);
        };
        const consumed = line.len + 1;
        var storage: std.ArrayList(u8) = .empty;
        defer storage.deinit(gpa);
        var bounds: std.ArrayList(struct { start: usize, len: usize }) = .empty;
        defer bounds.deinit(gpa);
        const trimmed = std.mem.trimEnd(u8, line, "\r");
        resp.splitArgs(gpa, trimmed, &storage, &bounds) catch {
            sys.writeAll(2, "Invalid argument(s)\n") catch {};
            line_buf.replaceRangeAssumeCapacity(0, consumed, &.{});
            continue;
        };
        var cmd_args: std.ArrayList([]const u8) = .empty;
        defer cmd_args.deinit(gpa);
        for (bounds.items) |b| try cmd_args.append(gpa, storage.items[b.start..][0..b.len]);
        line_buf.replaceRangeAssumeCapacity(0, consumed, &.{});
        if (cmd_args.items.len == 0) continue;
        if (std.ascii.eqlIgnoreCase(cmd_args.items[0], "exit") or std.ascii.eqlIgnoreCase(cmd_args.items[0], "quit")) return;
        runCommand(&conn, &out, cmd_args.items, opts.raw) catch |err| {
            fail("Error: {s}", .{@errorName(err)});
        };
        out.flush();
    }
}
