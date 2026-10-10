//! The execution context handed to every command implementation, plus
//! the shared reply and argument helpers that keep error messages
//! identical to Redis across all commands.

const std = @import("std");
const resp = @import("../resp.zig");
const num = @import("../num.zig");
const db_mod = @import("../db.zig");
const Server = @import("../server/server.zig").Server;
const Client = @import("../server/client.zig").Client;
const Allocator = std.mem.Allocator;

pub const Db = db_mod.Db;
pub const Value = db_mod.Value;
pub const Kind = db_mod.Kind;

pub const Error = Allocator.Error;

pub const Flags = packed struct {
    write: bool = false,
    readonly: bool = false,
    /// Allowed before AUTH when a password is configured.
    no_auth: bool = false,
    /// Allowed in RESP2 subscriber mode.
    pubsub_ok: bool = false,
    /// Executed immediately even inside MULTI.
    multi_control: bool = false,
    admin: bool = false,
    fast: bool = false,
    blocking: bool = false,
    pubsub: bool = false,
};

pub const Command = struct {
    name: []const u8,
    handler: *const fn (*Ctx) Error!void,
    /// Positive: exact argument count including the name. Negative: minimum.
    arity: i32,
    flags: Flags = .{},
    first_key: i32 = 0,
    last_key: i32 = 0,
    key_step: i32 = 0,

    pub fn arityOk(self: *const Command, argc: usize) bool {
        const n: i32 = @intCast(argc);
        return if (self.arity >= 0) n == self.arity else n >= -self.arity;
    }
};

pub const msg = struct {
    pub const wrong_type = "WRONGTYPE Operation against a key holding the wrong kind of value";
    pub const syntax = "ERR syntax error";
    pub const not_integer = "ERR value is not an integer or out of range";
    pub const not_float = "ERR value is not a valid float";
    pub const overflow = "ERR increment or decrement would overflow";
    pub const no_such_key = "ERR no such key";
    pub const out_of_range = "ERR index out of range";
    pub const min_max_float = "ERR min or max is not a float";
    pub const min_max_lex = "ERR min or max not valid string range item";
    pub const nan = "ERR resulting score is not a number (NaN)";
    pub const positive = "ERR value is out of range, must be positive";
    pub const timeout_negative = "ERR timeout is negative";
    pub const timeout_invalid = "ERR timeout is not a float or out of range";
};

pub const Ctx = struct {
    server: *Server,
    client: *Client,
    args: []const []const u8,
    w: resp.Writer,
    gpa: Allocator,
    /// Set by commands that already propagated a deterministic rewrite of
    /// themselves (or nothing), so the default propagation is skipped.
    custom_propagation: bool = false,

    pub fn db(self: *Ctx) *Db {
        return &self.server.dbs[self.client.db];
    }

    /// The cached command time in ms.
    pub fn now(self: *const Ctx) i64 {
        return self.server.now_ms;
    }

    pub fn argc(self: *const Ctx) usize {
        return self.args.len;
    }

    /// Records a modification of `key` in the current database: bumps the
    /// dirty counter and invalidates WATCHes on the key.
    pub fn modified(self: *Ctx, key: []const u8) void {
        self.server.dirty += 1;
        self.server.touchWatchedKey(self.client.db, key);
    }

    pub fn modifiedIn(self: *Ctx, db_index: usize, key: []const u8) void {
        self.server.dirty += 1;
        self.server.touchWatchedKey(db_index, key);
    }

    /// Wakes clients blocked on `key` (after a push or ZADD).
    pub fn signalReady(self: *Ctx, key: []const u8) Error!void {
        try self.server.signalKeyAsReady(self.client.db, key);
    }

    /// Appends a command to the AOF in place of the original arguments.
    pub fn propagate(self: *Ctx, args: []const []const u8) Error!void {
        self.custom_propagation = true;
        try self.server.propagate(self.client.db, args);
    }

    /// Suppresses default propagation without emitting anything.
    pub fn noPropagation(self: *Ctx) void {
        self.custom_propagation = true;
    }

    // ---- replies

    pub fn wrongType(self: *Ctx) Error!void {
        try self.w.err(msg.wrong_type);
    }

    pub fn syntaxError(self: *Ctx) Error!void {
        try self.w.err(msg.syntax);
    }

    pub fn wrongArity(self: *Ctx) Error!void {
        var lower: [64]u8 = undefined;
        const name = self.args[0];
        const shown = if (name.len <= lower.len) std.ascii.lowerString(&lower, name) else name;
        try self.w.errFmt("ERR wrong number of arguments for '{s}' command", .{shown});
    }

    // ---- argument parsing; each writes the error reply on failure

    pub fn int(self: *Ctx, s: []const u8) Error!?i64 {
        if (num.parseI64(s)) |v| return v;
        try self.w.err(msg.not_integer);
        return null;
    }

    pub fn intMsg(self: *Ctx, s: []const u8, message: []const u8) Error!?i64 {
        if (num.parseI64(s)) |v| return v;
        try self.w.err(message);
        return null;
    }

    pub fn positiveInt(self: *Ctx, s: []const u8) Error!?i64 {
        const v = (try self.int(s)) orelse return null;
        if (v <= 0) {
            try self.w.err(msg.positive);
            return null;
        }
        return v;
    }

    pub fn float(self: *Ctx, s: []const u8) Error!?f64 {
        if (num.parseF64(s)) |v| return v;
        try self.w.err(msg.not_float);
        return null;
    }

    /// Parses a blocking timeout in seconds (fractions allowed) into an
    /// absolute deadline in ms; 0 means block forever.
    pub fn timeoutDeadline(self: *Ctx, s: []const u8) Error!?i64 {
        const secs = num.parseF64(s) orelse {
            try self.w.err(msg.timeout_invalid);
            return null;
        };
        if (secs < 0) {
            try self.w.err(msg.timeout_negative);
            return null;
        }
        if (std.math.isInf(secs) or secs > 1e12) {
            try self.w.err(msg.timeout_invalid);
            return null;
        }
        if (secs == 0) return 0;
        const ms: i64 = @intFromFloat(@ceil(secs * 1000.0));
        return self.now() + @max(ms, 1);
    }

    /// Case-insensitive comparison against an ASCII option keyword.
    pub fn is(s: []const u8, keyword: []const u8) bool {
        return std.ascii.eqlIgnoreCase(s, keyword);
    }

    // ---- typed lookups; `null` with an error reply means wrong type

    pub const Lookup = union(enum) {
        missing,
        wrong_type,
        found: *Value,
    };

    pub fn lookup(self: *Ctx, key: []const u8, kind: Kind, for_write: bool) Lookup {
        const d = self.db();
        const v = (if (for_write) d.lookupWrite(key) else d.lookupRead(key)) orelse return .missing;
        if (v.kind() != kind) return .wrong_type;
        return .{ .found = v };
    }
};
