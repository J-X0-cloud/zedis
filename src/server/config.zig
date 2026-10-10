//! Server configuration. The same table drives command line flags
//! (`--port 6380`), CONFIG GET and CONFIG SET, so every knob is described
//! exactly once.

const std = @import("std");
const num = @import("../num.zig");
const glob = @import("../glob.zig");
const Allocator = std.mem.Allocator;

pub const FsyncPolicy = enum {
    always,
    everysec,
    no,
};

pub const Config = struct {
    bind: []const u8 = "127.0.0.1",
    port: u16 = 6379,
    dir: []const u8 = ".",
    databases: usize = 16,
    hz: u32 = 10,
    maxclients: u32 = 10000,
    requirepass: []const u8 = "",
    appendonly: bool = false,
    appendfilename: []const u8 = "appendonly.aof",
    appendfsync: FsyncPolicy = .everysec,
    auto_aof_rewrite_percentage: u32 = 100,
    auto_aof_rewrite_min_size: u64 = 64 * 1024 * 1024,
    aof_load_truncated: bool = true,
    /// Per-client output buffer hard limit for pub/sub subscribers.
    pubsub_output_limit: u64 = 32 * 1024 * 1024,
    /// Maximum size of a client's unprocessed input.
    client_query_buffer_limit: u64 = 1024 * 1024 * 1024,
    loglevel: LogLevel = .notice,

    /// Strings set at runtime are allocated here so they can be replaced.
    owned: std.ArrayList([]u8) = .empty,

    pub const LogLevel = enum { debug, verbose, notice, warning };

    pub fn deinit(self: *Config, gpa: Allocator) void {
        for (self.owned.items) |s| gpa.free(s);
        self.owned.deinit(gpa);
    }

    pub const SetError = error{ UnknownOption, InvalidValue, Immutable } || Allocator.Error;

    pub const Param = struct {
        name: []const u8,
        mutable: bool,
    };

    pub const params = [_]Param{
        .{ .name = "bind", .mutable = false },
        .{ .name = "port", .mutable = false },
        .{ .name = "dir", .mutable = false },
        .{ .name = "databases", .mutable = false },
        .{ .name = "hz", .mutable = true },
        .{ .name = "maxclients", .mutable = true },
        .{ .name = "requirepass", .mutable = true },
        .{ .name = "appendonly", .mutable = true },
        .{ .name = "appendfilename", .mutable = false },
        .{ .name = "appendfsync", .mutable = true },
        .{ .name = "auto-aof-rewrite-percentage", .mutable = true },
        .{ .name = "auto-aof-rewrite-min-size", .mutable = true },
        .{ .name = "aof-load-truncated", .mutable = true },
        .{ .name = "client-query-buffer-limit", .mutable = true },
        .{ .name = "loglevel", .mutable = true },
    };

    fn dupe(self: *Config, gpa: Allocator, s: []const u8) Allocator.Error![]const u8 {
        const copy = try gpa.dupe(u8, s);
        errdefer gpa.free(copy);
        try self.owned.append(gpa, copy);
        return copy;
    }

    /// Applies one option. `startup` allows immutable options.
    pub fn set(self: *Config, gpa: Allocator, name_in: []const u8, value: []const u8, startup: bool) SetError!void {
        var lower_buf: [64]u8 = undefined;
        if (name_in.len > lower_buf.len) return error.UnknownOption;
        const name = std.ascii.lowerString(&lower_buf, name_in);
        const param = for (params) |p| {
            if (std.mem.eql(u8, p.name, name)) break p;
        } else return error.UnknownOption;
        if (!param.mutable and !startup) return error.Immutable;

        if (std.mem.eql(u8, name, "bind")) {
            self.bind = try self.dupe(gpa, value);
        } else if (std.mem.eql(u8, name, "port")) {
            self.port = std.fmt.parseInt(u16, value, 10) catch return error.InvalidValue;
        } else if (std.mem.eql(u8, name, "dir")) {
            self.dir = try self.dupe(gpa, value);
        } else if (std.mem.eql(u8, name, "databases")) {
            const n = std.fmt.parseInt(usize, value, 10) catch return error.InvalidValue;
            if (n < 1 or n > 1024) return error.InvalidValue;
            self.databases = n;
        } else if (std.mem.eql(u8, name, "hz")) {
            const n = std.fmt.parseInt(u32, value, 10) catch return error.InvalidValue;
            self.hz = std.math.clamp(n, 1, 500);
        } else if (std.mem.eql(u8, name, "maxclients")) {
            const n = std.fmt.parseInt(u32, value, 10) catch return error.InvalidValue;
            if (n < 1) return error.InvalidValue;
            self.maxclients = n;
        } else if (std.mem.eql(u8, name, "requirepass")) {
            self.requirepass = try self.dupe(gpa, value);
        } else if (std.mem.eql(u8, name, "appendonly")) {
            self.appendonly = try parseBool(value);
        } else if (std.mem.eql(u8, name, "appendfilename")) {
            if (value.len == 0 or std.mem.indexOfScalar(u8, value, '/') != null) return error.InvalidValue;
            self.appendfilename = try self.dupe(gpa, value);
        } else if (std.mem.eql(u8, name, "appendfsync")) {
            self.appendfsync = std.meta.stringToEnum(FsyncPolicy, value) orelse return error.InvalidValue;
        } else if (std.mem.eql(u8, name, "auto-aof-rewrite-percentage")) {
            self.auto_aof_rewrite_percentage = std.fmt.parseInt(u32, value, 10) catch return error.InvalidValue;
        } else if (std.mem.eql(u8, name, "auto-aof-rewrite-min-size")) {
            self.auto_aof_rewrite_min_size = parseMemory(value) orelse return error.InvalidValue;
        } else if (std.mem.eql(u8, name, "aof-load-truncated")) {
            self.aof_load_truncated = try parseBool(value);
        } else if (std.mem.eql(u8, name, "client-query-buffer-limit")) {
            const v = parseMemory(value) orelse return error.InvalidValue;
            if (v < 1024 * 1024) return error.InvalidValue;
            self.client_query_buffer_limit = v;
        } else if (std.mem.eql(u8, name, "loglevel")) {
            self.loglevel = std.meta.stringToEnum(LogLevel, value) orelse return error.InvalidValue;
        } else unreachable;
    }

    /// Renders the current value of a parameter into `buf`.
    pub fn get(self: *const Config, name: []const u8, buf: []u8) []const u8 {
        if (std.mem.eql(u8, name, "bind")) return self.bind;
        if (std.mem.eql(u8, name, "port")) return fmtInt(buf, self.port);
        if (std.mem.eql(u8, name, "dir")) return self.dir;
        if (std.mem.eql(u8, name, "databases")) return fmtInt(buf, self.databases);
        if (std.mem.eql(u8, name, "hz")) return fmtInt(buf, self.hz);
        if (std.mem.eql(u8, name, "maxclients")) return fmtInt(buf, self.maxclients);
        if (std.mem.eql(u8, name, "requirepass")) return self.requirepass;
        if (std.mem.eql(u8, name, "appendonly")) return if (self.appendonly) "yes" else "no";
        if (std.mem.eql(u8, name, "appendfilename")) return self.appendfilename;
        if (std.mem.eql(u8, name, "appendfsync")) return @tagName(self.appendfsync);
        if (std.mem.eql(u8, name, "auto-aof-rewrite-percentage")) return fmtInt(buf, self.auto_aof_rewrite_percentage);
        if (std.mem.eql(u8, name, "auto-aof-rewrite-min-size")) return fmtInt(buf, self.auto_aof_rewrite_min_size);
        if (std.mem.eql(u8, name, "aof-load-truncated")) return if (self.aof_load_truncated) "yes" else "no";
        if (std.mem.eql(u8, name, "client-query-buffer-limit")) return fmtInt(buf, self.client_query_buffer_limit);
        if (std.mem.eql(u8, name, "loglevel")) return @tagName(self.loglevel);
        unreachable;
    }

    /// Calls `visitor.emit(name, value)` for every parameter matching `pattern`.
    pub fn matching(self: *const Config, pattern: []const u8, visitor: anytype) !void {
        for (params) |p| {
            if (!glob.matchNoCase(pattern, p.name)) continue;
            var buf: [32]u8 = undefined;
            try visitor.emit(p.name, self.get(p.name, &buf));
        }
    }

    pub const ArgsError = SetError || error{MissingValue};

    /// Parses `--name value` pairs from the command line.
    pub fn applyArgs(self: *Config, gpa: Allocator, args: []const []const u8, bad_option: *[]const u8) ArgsError!void {
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const a = args[i];
            if (!std.mem.startsWith(u8, a, "--")) {
                bad_option.* = a;
                return error.UnknownOption;
            }
            if (i + 1 >= args.len) {
                bad_option.* = a;
                return error.MissingValue;
            }
            bad_option.* = a;
            try self.set(gpa, a[2..], args[i + 1], true);
            i += 1;
        }
    }
};

fn fmtInt(buf: []u8, v: anytype) []const u8 {
    return std.fmt.bufPrint(buf, "{d}", .{v}) catch unreachable;
}

pub fn parseBool(s: []const u8) error{InvalidValue}!bool {
    if (std.ascii.eqlIgnoreCase(s, "yes")) return true;
    if (std.ascii.eqlIgnoreCase(s, "no")) return false;
    return error.InvalidValue;
}

/// Parses memory sizes like "64mb", "1gb", "512k" or plain bytes.
pub fn parseMemory(s: []const u8) ?u64 {
    var i: usize = 0;
    while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
    if (i == 0) return null;
    const base = std.fmt.parseInt(u64, s[0..i], 10) catch return null;
    const unit = s[i..];
    const mul: u64 = if (unit.len == 0 or std.ascii.eqlIgnoreCase(unit, "b"))
        1
    else if (std.ascii.eqlIgnoreCase(unit, "k"))
        1000
    else if (std.ascii.eqlIgnoreCase(unit, "kb"))
        1024
    else if (std.ascii.eqlIgnoreCase(unit, "m"))
        1000 * 1000
    else if (std.ascii.eqlIgnoreCase(unit, "mb"))
        1024 * 1024
    else if (std.ascii.eqlIgnoreCase(unit, "g"))
        1000 * 1000 * 1000
    else if (std.ascii.eqlIgnoreCase(unit, "gb"))
        1024 * 1024 * 1024
    else
        return null;
    return std.math.mul(u64, base, mul) catch null;
}

const testing = std.testing;

test "apply command line flags" {
    var cfg: Config = .{};
    defer cfg.deinit(testing.allocator);
    var bad: []const u8 = "";
    try cfg.applyArgs(testing.allocator, &.{ "--port", "7000", "--appendonly", "yes", "--appendfsync", "always", "--bind", "0.0.0.0" }, &bad);
    try testing.expectEqual(@as(u16, 7000), cfg.port);
    try testing.expect(cfg.appendonly);
    try testing.expectEqual(FsyncPolicy.always, cfg.appendfsync);
    try testing.expectEqualStrings("0.0.0.0", cfg.bind);
    try testing.expectError(error.UnknownOption, cfg.applyArgs(testing.allocator, &.{ "--nope", "1" }, &bad));
    try testing.expectEqualStrings("--nope", bad);
    try testing.expectError(error.MissingValue, cfg.applyArgs(testing.allocator, &.{"--port"}, &bad));
    try testing.expectError(error.InvalidValue, cfg.applyArgs(testing.allocator, &.{ "--port", "99999" }, &bad));
}

test "runtime set respects mutability" {
    var cfg: Config = .{};
    defer cfg.deinit(testing.allocator);
    try cfg.set(testing.allocator, "HZ", "50", false);
    try testing.expectEqual(@as(u32, 50), cfg.hz);
    try testing.expectError(error.Immutable, cfg.set(testing.allocator, "port", "1", false));
    try testing.expectError(error.InvalidValue, cfg.set(testing.allocator, "appendonly", "maybe", false));
    try cfg.set(testing.allocator, "auto-aof-rewrite-min-size", "1mb", false);
    try testing.expectEqual(@as(u64, 1024 * 1024), cfg.auto_aof_rewrite_min_size);
}

test "config get with glob" {
    var cfg: Config = .{};
    defer cfg.deinit(testing.allocator);
    const Collect = struct {
        names: std.ArrayList([]const u8) = .empty,
        fn emit(self: *@This(), name: []const u8, _: []const u8) !void {
            try self.names.append(testing.allocator, name);
        }
    };
    var c: Collect = .{};
    defer c.names.deinit(testing.allocator);
    try cfg.matching("append*", &c);
    try testing.expectEqual(@as(usize, 3), c.names.items.len);
}

test "parseMemory" {
    try testing.expectEqual(@as(?u64, 100), parseMemory("100"));
    try testing.expectEqual(@as(?u64, 64 * 1024 * 1024), parseMemory("64mb"));
    try testing.expectEqual(@as(?u64, 2000), parseMemory("2k"));
    try testing.expectEqual(@as(?u64, null), parseMemory("mb"));
    try testing.expectEqual(@as(?u64, null), parseMemory("10xb"));
}
