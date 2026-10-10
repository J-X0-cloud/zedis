//! RESP2/RESP3 wire protocol: a resumable request parser for the server,
//! a reply encoder that adapts to the negotiated protocol version, and a
//! reply decoder used by the bundled client.

const std = @import("std");
const num = @import("num.zig");
const Allocator = std.mem.Allocator;

pub const max_inline_size = 64 * 1024;
pub const max_multibulk_len = 1024 * 1024;
pub const max_bulk_len = 512 * 1024 * 1024;

// ------------------------------------------------------------ requests --

/// A parsed command. `args` points into the parser's storage and into the
/// caller's buffer; it is valid until the next call to `parse` or until the
/// caller mutates the buffer.
pub const Request = struct {
    args: []const []const u8,
    /// Number of bytes of the input buffer this request occupied.
    consumed: usize,
};

pub const ParseError = error{ProtocolError} || Allocator.Error;

const Span = struct { start: usize, len: usize };

/// Incremental request parser. Large multibulk requests that arrive across
/// many reads are not re-scanned from the start: the parser remembers how
/// many arguments it has already located and where.
pub const RequestParser = struct {
    gpa: Allocator,
    /// Remaining arguments of the current multibulk request; 0 when idle.
    remaining: usize = 0,
    /// Offset of the next unparsed byte relative to the request start.
    pos: usize = 0,
    /// Length of the bulk string being waited on, if its header was read.
    pending_bulk: ?usize = null,
    spans: std.ArrayList(Span) = .empty,
    args: std.ArrayList([]const u8) = .empty,
    inline_storage: std.ArrayList(u8) = .empty,
    /// Human readable reason for the last `error.ProtocolError`.
    err_msg: []const u8 = "",

    pub fn init(gpa: Allocator) RequestParser {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *RequestParser) void {
        self.spans.deinit(self.gpa);
        self.args.deinit(self.gpa);
        self.inline_storage.deinit(self.gpa);
    }

    fn resetState(self: *RequestParser) void {
        self.remaining = 0;
        self.pos = 0;
        self.pending_bulk = null;
        self.spans.clearRetainingCapacity();
    }

    fn fail(self: *RequestParser, msg: []const u8) ParseError {
        self.resetState();
        self.err_msg = msg;
        return error.ProtocolError;
    }

    /// Parses one request from the start of `buf`. Returns null when more
    /// bytes are needed. A request with zero arguments (an empty inline
    /// line or `*0`) is returned so the caller can skip its bytes.
    pub fn parse(self: *RequestParser, buf: []const u8) ParseError!?Request {
        if (buf.len == 0) return null;
        if (self.remaining == 0 and self.pos == 0 and buf[0] != '*') return self.parseInline(buf);
        return self.parseMultibulk(buf);
    }

    fn parseInline(self: *RequestParser, buf: []const u8) ParseError!?Request {
        const nl = std.mem.indexOfScalar(u8, buf, '\n') orelse {
            if (buf.len > max_inline_size) return self.fail("Protocol error: too big inline request");
            return null;
        };
        var line = buf[0..nl];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        self.args.clearRetainingCapacity();
        self.inline_storage.clearRetainingCapacity();
        try self.inline_storage.ensureTotalCapacity(self.gpa, line.len);
        var bounds: std.ArrayList(Span) = .empty;
        defer bounds.deinit(self.gpa);
        splitArgs(self.gpa, line, &self.inline_storage, &bounds) catch |err| switch (err) {
            error.UnbalancedQuotes => return self.fail("Protocol error: unbalanced quotes in request"),
            error.OutOfMemory => return error.OutOfMemory,
        };
        for (bounds.items) |b| {
            try self.args.append(self.gpa, self.inline_storage.items[b.start..][0..b.len]);
        }
        return .{ .args = self.args.items, .consumed = nl + 1 };
    }

    const Header = struct {
        /// Parsed integer, or null when the header is not a valid integer.
        value: ?i64,
        /// Offset just past the header's line terminator.
        next: usize,
    };

    /// Reads a newline terminated integer header (such as `*3` or `$5`)
    /// starting at `self.pos`. Returns null if the line is incomplete.
    fn readHeader(self: *RequestParser, buf: []const u8, too_big: []const u8) ParseError!?Header {
        const rest = buf[self.pos..];
        const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse {
            if (rest.len > max_inline_size) return self.fail(too_big);
            return null;
        };
        var line = rest[1..nl];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        return .{
            .value = std.fmt.parseInt(i64, line, 10) catch null,
            .next = self.pos + nl + 1,
        };
    }

    fn parseMultibulk(self: *RequestParser, buf: []const u8) ParseError!?Request {
        if (self.remaining == 0) {
            const hdr = (try self.readHeader(buf, "Protocol error: too big mbulk count string")) orelse return null;
            const count = hdr.value orelse return self.fail("Protocol error: invalid multibulk length");
            if (count > max_multibulk_len) return self.fail("Protocol error: invalid multibulk length");
            if (count <= 0) {
                self.resetState();
                self.args.clearRetainingCapacity();
                return .{ .args = self.args.items, .consumed = hdr.next };
            }
            self.pos = hdr.next;
            self.remaining = @intCast(count);
            self.spans.clearRetainingCapacity();
            // Do not trust the header blindly for preallocation.
            try self.spans.ensureTotalCapacity(self.gpa, @min(self.remaining, 1024));
        }

        while (self.remaining > 0) {
            if (self.pending_bulk == null) {
                if (self.pos >= buf.len) return null;
                if (buf[self.pos] != '$') return self.fail(expectedDollar(buf[self.pos]));
                const hdr = (try self.readHeader(buf, "Protocol error: too big bulk count string")) orelse return null;
                const len = hdr.value orelse return self.fail("Protocol error: invalid bulk length");
                if (len < 0 or len > max_bulk_len) return self.fail("Protocol error: invalid bulk length");
                self.pending_bulk = @intCast(len);
                self.pos = hdr.next;
            }
            const len = self.pending_bulk.?;
            if (buf.len < self.pos + len + 2) return null;
            try self.spans.append(self.gpa, .{ .start = self.pos, .len = len });
            self.pos += len + 2;
            self.pending_bulk = null;
            self.remaining -= 1;
        }

        self.args.clearRetainingCapacity();
        try self.args.ensureTotalCapacity(self.gpa, self.spans.items.len);
        for (self.spans.items) |s| self.args.appendAssumeCapacity(buf[s.start..][0..s.len]);
        const consumed = self.pos;
        self.resetState();
        return .{ .args = self.args.items, .consumed = consumed };
    }

    /// True while a partially received request is pending.
    pub fn inProgress(self: *const RequestParser) bool {
        return self.remaining != 0 or self.pos != 0;
    }
};

/// Redis reports the offending byte; we keep a static table so the message
/// does not need an allocation.
fn expectedDollar(c: u8) []const u8 {
    const table = comptime blk: {
        var t: [256][]const u8 = undefined;
        for (0..256) |i| {
            const ch: u8 = @intCast(i);
            t[i] = "Protocol error: expected '$', got '" ++ [_]u8{ch} ++ "'";
        }
        break :blk t;
    };
    return table[c];
}

pub const SplitError = error{UnbalancedQuotes} || Allocator.Error;

fn hexVal(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

/// Splits a line into arguments with the same rules as Redis' `sdssplitargs`:
/// whitespace separated, double quotes with C-like escapes (including \xHH),
/// single quotes with only \' escaped. A closing quote must be followed by
/// whitespace or the end of the line.
pub fn splitArgs(gpa: Allocator, line: []const u8, storage: *std.ArrayList(u8), bounds: anytype) SplitError!void {
    var i: usize = 0;
    while (true) {
        while (i < line.len and std.ascii.isWhitespace(line[i])) i += 1;
        if (i >= line.len) return;
        const start = storage.items.len;
        var in_dq = false;
        var in_sq = false;
        var done = false;
        while (!done) {
            if (in_dq) {
                if (i >= line.len) return error.UnbalancedQuotes;
                const c = line[i];
                if (c == '\\' and i + 3 < line.len and line[i + 1] == 'x' and hexVal(line[i + 2]) != null and hexVal(line[i + 3]) != null) {
                    try storage.append(gpa, hexVal(line[i + 2]).? * 16 + hexVal(line[i + 3]).?);
                    i += 3;
                } else if (c == '\\' and i + 1 < line.len) {
                    i += 1;
                    const e: u8 = switch (line[i]) {
                        'n' => '\n',
                        'r' => '\r',
                        't' => '\t',
                        'b' => 0x08,
                        'a' => 0x07,
                        else => line[i],
                    };
                    try storage.append(gpa, e);
                } else if (c == '"') {
                    if (i + 1 < line.len and !std.ascii.isWhitespace(line[i + 1])) return error.UnbalancedQuotes;
                    done = true;
                } else {
                    try storage.append(gpa, c);
                }
            } else if (in_sq) {
                if (i >= line.len) return error.UnbalancedQuotes;
                const c = line[i];
                if (c == '\\' and i + 1 < line.len and line[i + 1] == '\'') {
                    i += 1;
                    try storage.append(gpa, '\'');
                } else if (c == '\'') {
                    if (i + 1 < line.len and !std.ascii.isWhitespace(line[i + 1])) return error.UnbalancedQuotes;
                    done = true;
                } else {
                    try storage.append(gpa, c);
                }
            } else {
                if (i >= line.len) {
                    done = true;
                    break;
                }
                switch (line[i]) {
                    ' ', '\n', '\r', '\t', 0 => done = true,
                    '"' => in_dq = true,
                    '\'' => in_sq = true,
                    else => try storage.append(gpa, line[i]),
                }
            }
            if (i < line.len) i += 1;
        }
        try bounds.append(gpa, .{ .start = start, .len = storage.items.len - start });
    }
}

// ------------------------------------------------------------- replies --

/// Appends protocol-correct replies to an output buffer. The same calls
/// produce RESP2 or RESP3 depending on `proto`, so command implementations
/// never branch on the protocol themselves.
pub const Writer = struct {
    gpa: Allocator,
    out: *std.ArrayList(u8),
    proto: u8 = 2,

    pub const Error = Allocator.Error;

    fn header(self: Writer, prefix: u8, n: i64) Error!void {
        // Hot path for every reply: format the integer by hand rather than
        // going through std.fmt.
        var buf: [24]u8 = undefined;
        var i: usize = buf.len;
        var v: u64 = @abs(n);
        buf[i - 1] = '\n';
        buf[i - 2] = '\r';
        i -= 2;
        while (true) {
            i -= 1;
            buf[i] = @intCast('0' + v % 10);
            v /= 10;
            if (v == 0) break;
        }
        if (n < 0) {
            i -= 1;
            buf[i] = '-';
        }
        i -= 1;
        buf[i] = prefix;
        try self.out.appendSlice(self.gpa, buf[i..]);
    }

    pub fn raw(self: Writer, bytes: []const u8) Error!void {
        try self.out.appendSlice(self.gpa, bytes);
    }

    pub fn simple(self: Writer, s: []const u8) Error!void {
        try self.out.ensureUnusedCapacity(self.gpa, s.len + 3);
        self.out.appendAssumeCapacity('+');
        self.out.appendSliceAssumeCapacity(s);
        self.out.appendSliceAssumeCapacity("\r\n");
    }

    pub fn ok(self: Writer) Error!void {
        try self.raw("+OK\r\n");
    }

    /// Writes an error reply. `msg` must already include its code prefix
    /// (for example "ERR ..." or "WRONGTYPE ..."). CR/LF are replaced so a
    /// user-supplied fragment can never break framing.
    pub fn err(self: Writer, msg: []const u8) Error!void {
        try self.out.ensureUnusedCapacity(self.gpa, msg.len + 3);
        self.out.appendAssumeCapacity('-');
        for (msg) |c| self.out.appendAssumeCapacity(if (c == '\r' or c == '\n') ' ' else c);
        self.out.appendSliceAssumeCapacity("\r\n");
    }

    pub fn errFmt(self: Writer, comptime fmt: []const u8, args: anytype) Error!void {
        var buf: [512]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, fmt, args) catch blk: {
            // Truncate overly long messages rather than failing the reply.
            break :blk buf[0..];
        };
        try self.err(s);
    }

    pub fn int(self: Writer, v: i64) Error!void {
        try self.header(':', v);
    }

    pub fn bulk(self: Writer, s: []const u8) Error!void {
        try self.header('$', @intCast(s.len));
        try self.out.ensureUnusedCapacity(self.gpa, s.len + 2);
        self.out.appendSliceAssumeCapacity(s);
        self.out.appendSliceAssumeCapacity("\r\n");
    }

    pub fn bulkInt(self: Writer, v: i64) Error!void {
        var buf: [24]u8 = undefined;
        try self.bulk(num.formatI64(&buf, v));
    }

    pub fn bulkFmt(self: Writer, comptime fmt: []const u8, args: anytype) Error!void {
        const len = std.fmt.count(fmt, args);
        try self.header('$', @intCast(len));
        try self.out.ensureUnusedCapacity(self.gpa, len + 2);
        const dest = self.out.unusedCapacitySlice()[0..len];
        _ = std.fmt.bufPrint(dest, fmt, args) catch unreachable;
        self.out.items.len += len;
        self.out.appendSliceAssumeCapacity("\r\n");
    }

    /// Null bulk string: `$-1` in RESP2, `_` in RESP3.
    pub fn nullBulk(self: Writer) Error!void {
        try self.raw(if (self.proto >= 3) "_\r\n" else "$-1\r\n");
    }

    /// Null array: `*-1` in RESP2, `_` in RESP3.
    pub fn nullArray(self: Writer) Error!void {
        try self.raw(if (self.proto >= 3) "_\r\n" else "*-1\r\n");
    }

    pub fn array(self: Writer, n: usize) Error!void {
        try self.header('*', @intCast(n));
    }

    /// A map of `n` pairs; flattened to a 2n array in RESP2.
    pub fn map(self: Writer, n: usize) Error!void {
        if (self.proto >= 3) try self.header('%', @intCast(n)) else try self.header('*', @intCast(n * 2));
    }

    /// A set of `n` items; a plain array in RESP2.
    pub fn set(self: Writer, n: usize) Error!void {
        try self.header(if (self.proto >= 3) '~' else '*', @intCast(n));
    }

    /// Out-of-band push data (pub/sub messages); an array in RESP2.
    pub fn push(self: Writer, n: usize) Error!void {
        try self.header(if (self.proto >= 3) '>' else '*', @intCast(n));
    }

    /// A double: `,` in RESP3, a bulk string in RESP2.
    pub fn double(self: Writer, v: f64) Error!void {
        var buf: [num.max_double_chars]u8 = undefined;
        const s = num.formatDouble(&buf, v);
        if (self.proto >= 3) {
            try self.out.ensureUnusedCapacity(self.gpa, s.len + 3);
            self.out.appendAssumeCapacity(',');
            self.out.appendSliceAssumeCapacity(s);
            self.out.appendSliceAssumeCapacity("\r\n");
        } else {
            try self.bulk(s);
        }
    }

    /// A boolean: `#t`/`#f` in RESP3, `:1`/`:0` in RESP2.
    pub fn boolean(self: Writer, v: bool) Error!void {
        if (self.proto >= 3) {
            try self.raw(if (v) "#t\r\n" else "#f\r\n");
        } else {
            try self.raw(if (v) ":1\r\n" else ":0\r\n");
        }
    }

    /// Verbatim text (used by INFO): `=` with a `txt:` prefix in RESP3.
    pub fn verbatim(self: Writer, text: []const u8) Error!void {
        if (self.proto >= 3) {
            try self.header('=', @intCast(text.len + 4));
            try self.raw("txt:");
            try self.raw(text);
            try self.raw("\r\n");
        } else {
            try self.bulk(text);
        }
    }

    /// Writes an array header whose length is patched later. Returns a
    /// handle to pass to `finishDeferred`. Used when the element count is
    /// only known after producing the elements (for example LIMIT scans).
    pub fn deferredArray(self: Writer) Error!usize {
        const at = self.out.items.len;
        // Reserve a fixed width; the gap is closed when finishing.
        try self.raw("*00000000000000000000\r\n");
        return at;
    }

    pub fn finishDeferred(self: Writer, at: usize, n: usize, kind: enum { array, map, set }) void {
        var buf: [32]u8 = undefined;
        const prefix: u8 = switch (kind) {
            .array => '*',
            .map => if (self.proto >= 3) '%' else '*',
            .set => if (self.proto >= 3) '~' else '*',
        };
        const count = if (kind == .map and self.proto < 3) n * 2 else n;
        const hdr = std.fmt.bufPrint(&buf, "{c}{d}\r\n", .{ prefix, count }) catch unreachable;
        const placeholder_len = "*00000000000000000000\r\n".len;
        const items = self.out.items;
        @memcpy(items[at..][0..hdr.len], hdr);
        const tail_start = at + placeholder_len;
        const shift = placeholder_len - hdr.len;
        std.mem.copyForwards(u8, items[at + hdr.len ..], items[tail_start..]);
        self.out.items.len -= shift;
    }
};

// ------------------------------------------------------- reply decoding --

/// A decoded reply. Owned by the arena that produced it.
pub const Value = union(enum) {
    simple: []const u8,
    err: []const u8,
    int: i64,
    bulk: []const u8,
    nil,
    array: []Value,
    map: []Value, // flattened key, value, key, value...
    set: []Value,
    push: []Value,
    double: f64,
    boolean: bool,
    verbatim: []const u8,
    big_number: []const u8,

    /// The string payload for simple, bulk, verbatim and error replies.
    pub fn str(self: Value) ?[]const u8 {
        return switch (self) {
            .simple, .bulk, .verbatim, .err, .big_number => |s| s,
            else => null,
        };
    }

    pub fn items(self: Value) ?[]Value {
        return switch (self) {
            .array, .map, .set, .push => |a| a,
            else => null,
        };
    }

    /// Renders the value the way redis-cli does in its default mode.
    pub fn render(self: Value, w: *std.Io.Writer, indent: usize) std.Io.Writer.Error!void {
        switch (self) {
            .simple => |s| try w.print("{s}\n", .{s}),
            .err => |s| try w.print("(error) {s}\n", .{s}),
            .int => |v| try w.print("(integer) {d}\n", .{v}),
            .bulk, .verbatim => |s| {
                try w.writeAll("\"");
                for (s) |c| switch (c) {
                    '\\' => try w.writeAll("\\\\"),
                    '"' => try w.writeAll("\\\""),
                    '\n' => try w.writeAll("\\n"),
                    '\r' => try w.writeAll("\\r"),
                    '\t' => try w.writeAll("\\t"),
                    0x20...0x21, 0x23...0x5b, 0x5d...0x7e => try w.writeByte(c),
                    else => try w.print("\\x{x:0>2}", .{c}),
                };
                try w.writeAll("\"\n");
            },
            .nil => try w.writeAll("(nil)\n"),
            .double => |d| {
                var buf: [num.max_double_chars]u8 = undefined;
                try w.print("(double) {s}\n", .{num.formatDouble(&buf, d)});
            },
            .boolean => |b| try w.print("({s})\n", .{if (b) "true" else "false"}),
            .big_number => |s| try w.print("(big number) {s}\n", .{s}),
            .array, .set, .push => |a| {
                if (a.len == 0) {
                    try w.writeAll(if (self == .set) "(empty set)\n" else "(empty array)\n");
                    return;
                }
                for (a, 0..) |v, i| {
                    if (i != 0) try w.splatByteAll(' ', indent);
                    const prefix_len = std.fmt.count("{d}) ", .{i + 1});
                    try w.print("{d}) ", .{i + 1});
                    try v.render(w, indent + prefix_len);
                }
            },
            .map => |a| {
                if (a.len == 0) {
                    try w.writeAll("(empty hash)\n");
                    return;
                }
                var i: usize = 0;
                while (i + 1 < a.len) : (i += 2) {
                    if (i != 0) try w.splatByteAll(' ', indent);
                    const prefix_len = std.fmt.count("{d}# ", .{i / 2 + 1});
                    try w.print("{d}# ", .{i / 2 + 1});
                    const key = a[i].str() orelse "";
                    try w.print("\"{s}\" => ", .{key});
                    try a[i + 1].render(w, indent + prefix_len + key.len + 6);
                }
            },
        }
    }
};

pub const DecodeError = error{InvalidReply} || Allocator.Error;

/// Decodes one reply from `buf`. Returns null when the buffer does not yet
/// hold a complete reply. Allocations come from `arena`.
pub fn decode(arena: Allocator, buf: []const u8) DecodeError!?struct { value: Value, consumed: usize } {
    var pos: usize = 0;
    const v = (try decodeAt(arena, buf, &pos, 0)) orelse return null;
    return .{ .value = v, .consumed = pos };
}

fn readLine(buf: []const u8, pos: *usize) ?[]const u8 {
    const rest = buf[pos.*..];
    const nl = std.mem.indexOf(u8, rest, "\r\n") orelse return null;
    pos.* += nl + 2;
    return rest[0..nl];
}

fn decodeAt(arena: Allocator, buf: []const u8, pos: *usize, depth: usize) DecodeError!?Value {
    if (depth > 64) return error.InvalidReply;
    if (pos.* >= buf.len) return null;
    const kind = buf[pos.*];
    pos.* += 1;
    const line = readLine(buf, pos) orelse return null;
    switch (kind) {
        '+' => return .{ .simple = line },
        '-' => return .{ .err = line },
        ':' => return .{ .int = std.fmt.parseInt(i64, line, 10) catch return error.InvalidReply },
        '(' => return .{ .big_number = line },
        '_' => return .nil,
        '#' => {
            if (line.len != 1) return error.InvalidReply;
            return .{ .boolean = line[0] == 't' };
        },
        ',' => {
            const d = num.parseF64(line) orelse if (std.mem.eql(u8, line, "nan")) std.math.nan(f64) else return error.InvalidReply;
            return .{ .double = d };
        },
        '$', '=', '!' => {
            const n = std.fmt.parseInt(i64, line, 10) catch return error.InvalidReply;
            if (n < 0) return .nil;
            const len: usize = @intCast(n);
            if (buf.len < pos.* + len + 2) return null;
            const payload = buf[pos.*..][0..len];
            pos.* += len + 2;
            return switch (kind) {
                '$' => .{ .bulk = payload },
                '!' => .{ .err = payload },
                else => .{ .verbatim = if (payload.len >= 4) payload[4..] else payload },
            };
        },
        '*', '%', '~', '>' => {
            const n = std.fmt.parseInt(i64, line, 10) catch return error.InvalidReply;
            if (n < 0) return .nil;
            const count: usize = @intCast(if (kind == '%') n * 2 else n);
            if (count > buf.len) return null; // each element needs at least 1 byte
            const elems = try arena.alloc(Value, count);
            for (elems) |*e| {
                e.* = (try decodeAt(arena, buf, pos, depth + 1)) orelse return null;
            }
            return switch (kind) {
                '*' => .{ .array = elems },
                '%' => .{ .map = elems },
                '~' => .{ .set = elems },
                else => .{ .push = elems },
            };
        },
        else => return error.InvalidReply,
    }
}

/// Encodes a command as a RESP array of bulk strings.
pub fn encodeCommand(gpa: Allocator, out: *std.ArrayList(u8), args: []const []const u8) Allocator.Error!void {
    var buf: [32]u8 = undefined;
    try out.appendSlice(gpa, std.fmt.bufPrint(&buf, "*{d}\r\n", .{args.len}) catch unreachable);
    for (args) |a| {
        try out.appendSlice(gpa, std.fmt.bufPrint(&buf, "${d}\r\n", .{a.len}) catch unreachable);
        try out.appendSlice(gpa, a);
        try out.appendSlice(gpa, "\r\n");
    }
}

// ---------------------------------------------------------------- tests --

const testing = std.testing;

fn expectArgs(expected: []const []const u8, got: []const []const u8) !void {
    try testing.expectEqual(expected.len, got.len);
    for (expected, got) |e, g| try testing.expectEqualStrings(e, g);
}

test "parse multibulk in one go" {
    var p = RequestParser.init(testing.allocator);
    defer p.deinit();
    const buf = "*3\r\n$3\r\nSET\r\n$3\r\nkey\r\n$5\r\nvalue\r\n*1\r\n$4\r\nPING\r\n";
    const r = (try p.parse(buf)).?;
    try expectArgs(&.{ "SET", "key", "value" }, r.args);
    const r2 = (try p.parse(buf[r.consumed..])).?;
    try expectArgs(&.{"PING"}, r2.args);
    try testing.expectEqual(buf.len, r.consumed + r2.consumed);
}

test "parse multibulk byte by byte is resumable" {
    var p = RequestParser.init(testing.allocator);
    defer p.deinit();
    const buf = "*2\r\n$4\r\nECHO\r\n$12\r\nhello\r\nworld\r\n";
    var n: usize = 1;
    while (n < buf.len) : (n += 1) {
        try testing.expect((try p.parse(buf[0..n])) == null);
    }
    const r = (try p.parse(buf)).?;
    try expectArgs(&.{ "ECHO", "hello\r\nworld" }, r.args);
    try testing.expectEqual(buf.len, r.consumed);
    try testing.expect(!p.inProgress());
}

test "parse binary-safe empty and zero-length bulk" {
    var p = RequestParser.init(testing.allocator);
    defer p.deinit();
    const r = (try p.parse("*2\r\n$3\r\nGET\r\n$0\r\n\r\n")).?;
    try expectArgs(&.{ "GET", "" }, r.args);
    const z = (try p.parse("*0\r\n")).?;
    try testing.expectEqual(@as(usize, 0), z.args.len);
    try testing.expectEqual(@as(usize, 4), z.consumed);
}

test "parse inline commands with quoting" {
    var p = RequestParser.init(testing.allocator);
    defer p.deinit();
    const r = (try p.parse("SET  k \"a b\\x41\\n\" 'it\\'s'\r\n")).?;
    try expectArgs(&.{ "SET", "k", "a bA\n", "it's" }, r.args);
    const e = (try p.parse("\r\n")).?;
    try testing.expectEqual(@as(usize, 0), e.args.len);
    try testing.expect((try p.parse("PING")) == null);
    try testing.expectError(error.ProtocolError, p.parse("SET \"abc\r\n"));
    try testing.expectEqualStrings("Protocol error: unbalanced quotes in request", p.err_msg);
    try testing.expectError(error.ProtocolError, p.parse("SET \"a\"b\r\n"));
}

test "protocol errors" {
    var p = RequestParser.init(testing.allocator);
    defer p.deinit();
    try testing.expectError(error.ProtocolError, p.parse("*abc\r\n"));
    try testing.expectEqualStrings("Protocol error: invalid multibulk length", p.err_msg);
    try testing.expectError(error.ProtocolError, p.parse("*1\r\n+foo\r\n"));
    try testing.expectEqualStrings("Protocol error: expected '$', got '+'", p.err_msg);
    try testing.expectError(error.ProtocolError, p.parse("*1\r\n$-5\r\n"));
    try testing.expectEqualStrings("Protocol error: invalid bulk length", p.err_msg);
    try testing.expectError(error.ProtocolError, p.parse("*99999999\r\n"));
    const big = try testing.allocator.alloc(u8, max_inline_size + 10);
    defer testing.allocator.free(big);
    @memset(big, 'a');
    try testing.expectError(error.ProtocolError, p.parse(big));
    try testing.expectEqualStrings("Protocol error: too big inline request", p.err_msg);
}

test "writer emits RESP2 and RESP3 variants" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    var w: Writer = .{ .gpa = testing.allocator, .out = &out, .proto = 2 };
    try w.map(1);
    try w.bulk("k");
    try w.double(1.5);
    try w.nullBulk();
    try w.boolean(true);
    try w.err("ERR bad\r\nthing");
    try w.int(std.math.minInt(i64));
    try w.int(0);
    try testing.expectEqualStrings("*2\r\n$1\r\nk\r\n$3\r\n1.5\r\n$-1\r\n:1\r\n-ERR bad  thing\r\n:-9223372036854775808\r\n:0\r\n", out.items);

    out.clearRetainingCapacity();
    w.proto = 3;
    try w.map(1);
    try w.bulk("k");
    try w.double(1.5);
    try w.nullBulk();
    try w.boolean(false);
    try w.set(0);
    try w.push(1);
    try w.verbatim("hi");
    try testing.expectEqualStrings("%1\r\n$1\r\nk\r\n,1.5\r\n_\r\n#f\r\n~0\r\n>1\r\n=6\r\ntxt:hi\r\n", out.items);
}

test "deferred array length" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    const w: Writer = .{ .gpa = testing.allocator, .out = &out, .proto = 2 };
    try w.simple("pre");
    const at = try w.deferredArray();
    try w.int(1);
    try w.int(2);
    w.finishDeferred(at, 2, .array);
    try testing.expectEqualStrings("+pre\r\n*2\r\n:1\r\n:2\r\n", out.items);

    out.clearRetainingCapacity();
    const at2 = try w.deferredArray();
    try w.bulk("f");
    try w.bulk("v");
    w.finishDeferred(at2, 1, .map);
    try testing.expectEqualStrings("*2\r\n$1\r\nf\r\n$1\r\nv\r\n", out.items);
}

test "decode nested RESP3 reply" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const buf = "*4\r\n:5\r\n$3\r\nabc\r\n%1\r\n+k\r\n,2.5\r\n_\r\n";
    const r = (try decode(arena, buf)).?;
    try testing.expectEqual(buf.len, r.consumed);
    const items = r.value.items().?;
    try testing.expectEqual(@as(i64, 5), items[0].int);
    try testing.expectEqualStrings("abc", items[1].bulk);
    try testing.expectEqualStrings("k", items[2].map[0].simple);
    try testing.expectEqual(@as(f64, 2.5), items[2].map[1].double);
    try testing.expect(items[3] == .nil);
    try testing.expect((try decode(arena, buf[0 .. buf.len - 1])) == null);
    try testing.expectError(error.InvalidReply, decode(arena, "?x\r\n"));
}

test "encodeCommand round trips through the request parser" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try encodeCommand(testing.allocator, &out, &.{ "HSET", "h", "f\r\n", "" });
    var p = RequestParser.init(testing.allocator);
    defer p.deinit();
    const r = (try p.parse(out.items)).?;
    try expectArgs(&.{ "HSET", "h", "f\r\n", "" }, r.args);
}

test "render matches redis-cli formatting" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const r = (try decode(arena_state.allocator(), "*2\r\n$1\r\na\r\n*1\r\n:1\r\n")).?;
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try r.value.render(&w, 0);
    try testing.expectEqualStrings("1) \"a\"\n2) 1) (integer) 1\n", w.buffered());
}

test "random chunking of a pipelined stream yields the same commands" {
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const rnd = prng.random();
    var stream: std.ArrayList(u8) = .empty;
    defer stream.deinit(gpa);
    var expected_args: usize = 0;
    var n: usize = 0;
    while (n < 200) : (n += 1) {
        var argv: [6][]const u8 = undefined;
        var bufs: [6][40]u8 = undefined;
        const argc = 1 + rnd.uintLessThan(usize, argv.len);
        for (argv[0..argc], 0..) |*a, i| {
            const len = rnd.uintLessThan(usize, bufs[i].len);
            rnd.bytes(bufs[i][0..len]);
            a.* = bufs[i][0..len];
        }
        try encodeCommand(gpa, &stream, argv[0..argc]);
        expected_args += argc;
    }

    var p = RequestParser.init(gpa);
    defer p.deinit();
    // Feed the stream through a growing window, as a socket would.
    var window_end: usize = 0;
    var start: usize = 0;
    var commands: usize = 0;
    var args_seen: usize = 0;
    while (start < stream.items.len) {
        if (try p.parse(stream.items[start..window_end])) |r| {
            commands += 1;
            args_seen += r.args.len;
            start += r.consumed;
            continue;
        }
        if (window_end == stream.items.len) return error.TestUnexpectedResult;
        window_end = @min(stream.items.len, window_end + 1 + rnd.uintLessThan(usize, 64));
    }
    try testing.expectEqual(@as(usize, 200), commands);
    try testing.expectEqual(expected_args, args_seen);
}
