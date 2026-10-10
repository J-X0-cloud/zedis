//! Append-only file persistence.
//!
//! Every write command is appended to the AOF in RESP form after it has
//! been applied. Commands whose effect depends on when they run (relative
//! TTLs, random pops, float arithmetic) are rewritten by the command layer
//! into deterministic equivalents before they reach this module.
//!
//! The buffer is written to the file before the event loop sends replies,
//! so a client never sees an acknowledgement for a write that is not at
//! least in the kernel's page cache. Durability then depends on the fsync
//! policy: `always` fsyncs before replying, `everysec` fsyncs from the cron
//! at most once per second, and `no` leaves it to the kernel.
//!
//! Rewriting compacts the log. BGREWRITEAOF forks: the child inherits a
//! copy-on-write snapshot of the dataset and serializes it to a temporary
//! file without allocating, while the parent keeps serving and records
//! every command it appends in a rewrite buffer. When the child exits
//! successfully the parent appends that buffer to the new file and
//! atomically renames it over the old one.

const std = @import("std");
const sys = @import("sys.zig");
const num = @import("num.zig");
const resp = @import("resp.zig");
const db_mod = @import("db.zig");
const Allocator = std.mem.Allocator;
const Db = db_mod.Db;

/// Number of elements emitted per command when serializing collections,
/// matching Redis' AOF_REWRITE_ITEMS_PER_CMD.
pub const items_per_cmd = 64;

/// Buffered, allocation-free writer to a file descriptor. Safe to use in a
/// forked child of a multithreaded process.
pub const FdWriter = struct {
    fd: sys.fd_t,
    buf: []u8,
    len: usize = 0,
    written: u64 = 0,

    pub fn writeAll(self: *FdWriter, bytes: []const u8) sys.Error!void {
        if (self.len + bytes.len > self.buf.len) try self.flush();
        if (bytes.len > self.buf.len) {
            try sys.writeAll(self.fd, bytes);
            self.written += bytes.len;
            return;
        }
        @memcpy(self.buf[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }

    pub fn flush(self: *FdWriter) sys.Error!void {
        if (self.len == 0) return;
        try sys.writeAll(self.fd, self.buf[0..self.len]);
        self.written += self.len;
        self.len = 0;
    }

    fn header(self: *FdWriter, prefix: u8, n: usize) sys.Error!void {
        var tmp: [32]u8 = undefined;
        try self.writeAll(std.fmt.bufPrint(&tmp, "{c}{d}\r\n", .{ prefix, n }) catch unreachable);
    }

    pub fn arrayHeader(self: *FdWriter, n: usize) sys.Error!void {
        try self.header('*', n);
    }

    pub fn bulk(self: *FdWriter, s: []const u8) sys.Error!void {
        try self.header('$', s.len);
        try self.writeAll(s);
        try self.writeAll("\r\n");
    }

    pub fn command(self: *FdWriter, args: []const []const u8) sys.Error!void {
        try self.arrayHeader(args.len);
        for (args) |a| try self.bulk(a);
    }
};

/// Serializes every live key as the minimal sequence of commands that
/// recreates it. Allocation free. Returns the number of keys written.
pub fn writeSnapshot(w: *FdWriter, dbs: []Db, now_ms: i64) sys.Error!usize {
    var keys_written: usize = 0;
    for (dbs, 0..) |*db, idx| {
        if (db.size() == 0) continue;
        var dbbuf: [24]u8 = undefined;
        try w.command(&.{ "SELECT", num.formatI64(&dbbuf, @intCast(idx)) });
        var it = db.dict.iterator();
        while (it.next()) |e| {
            const key = e.key_ptr.*;
            const expire = db.expires.get(key);
            if (expire) |when| if (when <= now_ms) continue;
            try writeValue(w, key, e.value_ptr);
            if (expire) |when| {
                var tbuf: [24]u8 = undefined;
                try w.command(&.{ "PEXPIREAT", key, num.formatI64(&tbuf, when) });
            }
            keys_written += 1;
        }
    }
    try w.flush();
    return keys_written;
}

fn writeValue(w: *FdWriter, key: []const u8, v: *const db_mod.Value) sys.Error!void {
    switch (v.*) {
        .string => |s| try w.command(&.{ "SET", key, s }),
        .list => |l| {
            var i: usize = 0;
            while (i < l.len) {
                const n = @min(items_per_cmd, l.len - i);
                try w.arrayHeader(2 + n);
                try w.bulk("RPUSH");
                try w.bulk(key);
                var j: usize = 0;
                while (j < n) : (j += 1) try w.bulk(l.get(i + j));
                i += n;
            }
        },
        .hash => |h| {
            const keys = h.keys();
            const vals = h.values();
            var i: usize = 0;
            while (i < keys.len) {
                const n = @min(items_per_cmd, keys.len - i);
                try w.arrayHeader(2 + n * 2);
                try w.bulk("HSET");
                try w.bulk(key);
                var j: usize = 0;
                while (j < n) : (j += 1) {
                    try w.bulk(keys[i + j]);
                    try w.bulk(vals[i + j]);
                }
                i += n;
            }
        },
        .set => |s| {
            const keys = s.keys();
            var i: usize = 0;
            while (i < keys.len) {
                const n = @min(items_per_cmd, keys.len - i);
                try w.arrayHeader(2 + n);
                try w.bulk("SADD");
                try w.bulk(key);
                for (keys[i..][0..n]) |m| try w.bulk(m);
                i += n;
            }
        },
        .zset => |z| {
            var node = z.list.first();
            var remaining = z.len();
            while (remaining > 0) {
                const n = @min(items_per_cmd, remaining);
                try w.arrayHeader(2 + n * 2);
                try w.bulk("ZADD");
                try w.bulk(key);
                var j: usize = 0;
                while (j < n) : (j += 1) {
                    const nd = node.?;
                    var sbuf: [num.max_double_chars]u8 = undefined;
                    try w.bulk(num.formatDouble(&sbuf, nd.score));
                    try w.bulk(nd.member);
                    node = nd.next();
                }
                remaining -= n;
            }
        },
    }
}

/// Scratch buffer for snapshot serialization. Used either by the forked
/// child or by a synchronous rewrite in the parent, never both at once.
var snapshot_buf: [64 * 1024]u8 = undefined;

pub const RewriteStatus = enum { ok, err };

pub const Aof = struct {
    gpa: Allocator,
    enabled: bool = false,
    fd: ?sys.fd_t = null,
    dir: []const u8,
    filename: []const u8,
    /// Commands waiting to be written to the file.
    buf: std.ArrayList(u8) = .empty,
    /// Database the AOF stream currently has selected, if known.
    selected_db: ?usize = null,
    last_fsync_ms: i64 = 0,
    /// Size of the file including everything flushed so far.
    current_size: u64 = 0,
    /// Size right after the last rewrite (or at startup).
    base_size: u64 = 0,

    child_pid: ?std.os.linux.pid_t = null,
    /// Commands appended while a rewrite child is running.
    rewrite_buf: std.ArrayList(u8) = .empty,
    rewrite_start_ms: i64 = 0,
    rewrite_scheduled: bool = false,
    rewrites: u64 = 0,
    last_rewrite_status: RewriteStatus = .ok,
    last_rewrite_ms: i64 = -1,
    last_write_ok: bool = true,
    write_errors: u64 = 0,

    pub fn init(gpa: Allocator, dir: []const u8, filename: []const u8) Aof {
        return .{ .gpa = gpa, .dir = dir, .filename = filename };
    }

    pub fn deinit(self: *Aof) void {
        if (self.child_pid) |pid| {
            sys.killChild(pid);
            self.removeTempFile(pid);
        }
        _ = self.flush(.no);
        if (self.fd) |fd| sys.close(fd);
        self.buf.deinit(self.gpa);
        self.rewrite_buf.deinit(self.gpa);
    }

    pub fn pathInto(self: *const Aof, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "{s}/{s}", .{ self.dir, self.filename }) catch self.filename;
    }

    fn tempPathInto(self: *const Aof, buf: []u8, pid: std.os.linux.pid_t) []const u8 {
        return std.fmt.bufPrint(buf, "{s}/temp-rewriteaof-bg-{d}.aof", .{ self.dir, pid }) catch "temp-rewriteaof.aof";
    }

    fn removeTempFile(self: *const Aof, pid: std.os.linux.pid_t) void {
        var pbuf: [4096]u8 = undefined;
        sys.unlink(self.tempPathInto(&pbuf, pid)) catch {};
    }

    /// Opens the file for appending, creating it if needed.
    pub fn open(self: *Aof) sys.Error!void {
        var pbuf: [4096]u8 = undefined;
        const path = self.pathInto(&pbuf);
        const fd = try sys.open(path, .append_create);
        self.fd = fd;
        self.current_size = try sys.fileSize(fd);
        self.base_size = self.current_size;
        self.selected_db = null;
        self.enabled = true;
    }

    pub fn close(self: *Aof) void {
        _ = self.flush(.always);
        if (self.fd) |fd| sys.close(fd);
        self.fd = null;
        self.enabled = false;
        self.buf.clearRetainingCapacity();
    }

    fn append(self: *Aof, bytes: []const u8) Allocator.Error!void {
        try self.buf.appendSlice(self.gpa, bytes);
        if (self.child_pid != null) try self.rewrite_buf.appendSlice(self.gpa, bytes);
    }

    /// Appends a command executed against database `db`.
    pub fn feed(self: *Aof, db: usize, args: []const []const u8) Allocator.Error!void {
        if (!self.enabled) return;
        var tmp: std.ArrayList(u8) = .empty;
        defer tmp.deinit(self.gpa);
        if (self.selected_db == null or self.selected_db.? != db) {
            var dbuf: [24]u8 = undefined;
            try resp.encodeCommand(self.gpa, &tmp, &.{ "SELECT", num.formatI64(&dbuf, @intCast(db)) });
            self.selected_db = db;
        }
        try resp.encodeCommand(self.gpa, &tmp, args);
        try self.append(tmp.items);
    }

    /// Writes pending commands to the file. With `always`, also fsyncs.
    /// Returns false on a write error; the data stays buffered for retry.
    pub fn flush(self: *Aof, policy: @import("server/config.zig").FsyncPolicy) bool {
        const fd = self.fd orelse return true;
        if (self.buf.items.len == 0) return true;
        sys.writeAll(fd, self.buf.items) catch {
            self.last_write_ok = false;
            self.write_errors += 1;
            return false;
        };
        self.current_size += self.buf.items.len;
        self.last_write_ok = true;
        if (self.buf.capacity > 4 * 1024 * 1024) {
            self.buf.clearAndFree(self.gpa);
        } else {
            self.buf.clearRetainingCapacity();
        }
        if (policy == .always) sys.fsync(fd) catch {};
        return true;
    }

    /// fsync at most once per second for the `everysec` policy.
    pub fn fsyncIfDue(self: *Aof, now_ms: i64) void {
        const fd = self.fd orelse return;
        if (now_ms - self.last_fsync_ms < 1000) return;
        self.last_fsync_ms = now_ms;
        sys.fsync(fd) catch {};
    }

    pub fn rewriteInProgress(self: *const Aof) bool {
        return self.child_pid != null;
    }

    /// Whether the automatic rewrite thresholds have been crossed.
    pub fn shouldAutoRewrite(self: *const Aof, percentage: u32, min_size: u64) bool {
        if (!self.enabled or self.child_pid != null or percentage == 0) return false;
        if (self.current_size < min_size) return false;
        const base = @max(self.base_size, 1);
        const growth = (self.current_size -| base) * 100 / base;
        return growth >= percentage;
    }

    pub const StartError = sys.Error || Allocator.Error || error{AlreadyRunning};

    /// Forks a child that writes the snapshot to a temporary file.
    pub fn startBackgroundRewrite(self: *Aof, dbs: []Db, now_ms: i64) StartError!void {
        if (self.child_pid != null) return error.AlreadyRunning;
        // Make sure everything before the fork point is in the old file;
        // the snapshot covers it and the rewrite buffer covers what follows.
        _ = self.flush(.no);
        self.rewrite_buf.clearRetainingCapacity();
        const pid = try sys.fork();
        if (pid == 0) {
            const code: u8 = childRewrite(self, dbs, now_ms);
            sys.exitImmediately(code);
        }
        self.child_pid = pid;
        self.rewrite_start_ms = now_ms;
        self.rewrite_scheduled = false;
        // The new file starts with its own SELECT commands; force the
        // stream that follows the snapshot to select explicitly.
        self.selected_db = null;
    }

    fn childRewrite(self: *Aof, dbs: []Db, now_ms: i64) u8 {
        var pbuf: [4096]u8 = undefined;
        const tmp = self.tempPathInto(&pbuf, sys.getPid());
        const fd = sys.open(tmp, .write_truncate) catch return 1;
        var w: FdWriter = .{ .fd = fd, .buf = &snapshot_buf };
        _ = writeSnapshot(&w, dbs, now_ms) catch return 1;
        sys.fsync(fd) catch return 1;
        sys.close(fd);
        return 0;
    }

    pub const ChildResult = enum { none, running, succeeded, failed };

    /// Reaps a finished rewrite child and installs its output.
    pub fn checkChild(self: *Aof, now_ms: i64) ChildResult {
        const pid = self.child_pid orelse return .none;
        const status: sys.ChildStatus = sys.pollChild(pid) catch .{ .signaled = 0 };
        switch (status) {
            .running => return .running,
            .exited => |code| {
                self.child_pid = null;
                if (code == 0 and self.installRewrite(pid)) {
                    self.finishRewrite(.ok, now_ms);
                    return .succeeded;
                }
                self.removeTempFile(pid);
                self.finishRewrite(.err, now_ms);
                return .failed;
            },
            .signaled => {
                self.child_pid = null;
                self.removeTempFile(pid);
                self.finishRewrite(.err, now_ms);
                return .failed;
            },
        }
    }

    fn finishRewrite(self: *Aof, status: RewriteStatus, now_ms: i64) void {
        self.last_rewrite_status = status;
        self.last_rewrite_ms = now_ms - self.rewrite_start_ms;
        self.rewrite_buf.clearRetainingCapacity();
        if (status == .ok) self.rewrites += 1;
    }

    fn installRewrite(self: *Aof, pid: std.os.linux.pid_t) bool {
        var tbuf: [4096]u8 = undefined;
        const tmp = self.tempPathInto(&tbuf, pid);
        // Commands buffered since the last flush are part of the rewrite
        // buffer too; write them to the old file first so the two stay
        // equivalent should the rename fail.
        _ = self.flush(.no);
        const fd = sys.open(tmp, .append_create) catch return false;
        sys.writeAll(fd, self.rewrite_buf.items) catch {
            sys.close(fd);
            return false;
        };
        sys.fsync(fd) catch {};
        var pbuf: [4096]u8 = undefined;
        const path = self.pathInto(&pbuf);
        sys.rename(tmp, path) catch {
            sys.close(fd);
            return false;
        };
        const size = sys.fileSize(fd) catch 0;
        if (self.fd) |old| sys.close(old);
        self.fd = fd;
        self.current_size = size;
        self.base_size = size;
        return true;
    }

    /// Rewrites synchronously in this process (used when enabling AOF at
    /// runtime with no file yet, and by tests).
    pub fn rewriteSync(self: *Aof, dbs: []Db, now_ms: i64) (sys.Error || Allocator.Error)!void {
        _ = self.flush(.no);
        var tbuf: [4096]u8 = undefined;
        const tmp = self.tempPathInto(&tbuf, sys.getPid());
        const fd = try sys.open(tmp, .write_truncate);
        errdefer sys.close(fd);
        var w: FdWriter = .{ .fd = fd, .buf = &snapshot_buf };
        _ = try writeSnapshot(&w, dbs, now_ms);
        try sys.fsync(fd);
        sys.close(fd);
        var pbuf: [4096]u8 = undefined;
        try sys.rename(tmp, self.pathInto(&pbuf));
        if (self.fd) |old| sys.close(old);
        self.fd = null;
        try self.open();
        self.rewrites += 1;
        self.last_rewrite_status = .ok;
    }
};

const testing = std.testing;
const Value = db_mod.Value;

fn tmpDir(buf: []u8) ![]const u8 {
    const path = try std.fmt.bufPrint(buf, "/tmp/zedis-aof-test-{d}-{d}", .{ sys.getPid(), sys.nowUs() });
    var z = try sys.PathZ.init(path);
    _ = std.os.linux.mkdir(z.ptr(), 0o755);
    _ = &z;
    return path;
}

test "snapshot serializes every type and skips expired keys" {
    const gpa = testing.allocator;
    var clock: i64 = 1000;
    var stats: db_mod.Stats = .{};
    var dbs = [_]Db{ Db.init(gpa, 0, &clock, &stats, 1), Db.init(gpa, 1, &clock, &stats, 2) };
    defer for (&dbs) |*d| d.deinit();
    try dbs[0].set("s", try Value.initString(gpa, "hello"), .{});
    var l: Value = .{ .list = .empty };
    var i: usize = 0;
    while (i < 70) : (i += 1) try l.list.pushBack(gpa, "x");
    try dbs[0].set("l", l, .{});
    try dbs[0].set("gone", try Value.initString(gpa, "x"), .{});
    try dbs[0].setExpire("gone", 500);
    try dbs[0].set("ttl", try Value.initString(gpa, "x"), .{});
    try dbs[0].setExpire("ttl", 5000);
    var z = try Value.initZSet(gpa, 3);
    _ = try z.zset.add(gpa, "m", 1.5, .{}, null);
    try dbs[1].set("z", z, .{});

    var dir_buf: [128]u8 = undefined;
    const dir = try tmpDir(&dir_buf);
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/snap.aof", .{dir});
    const fd = try sys.open(path, .write_truncate);
    var w: FdWriter = .{ .fd = fd, .buf = &snapshot_buf };
    const n = try writeSnapshot(&w, &dbs, clock);
    sys.close(fd);
    try testing.expectEqual(@as(usize, 4), n);

    const data = (try sys.readFileAlloc(gpa, path)).?;
    defer gpa.free(data);
    try sys.unlink(path);
    var p = resp.RequestParser.init(gpa);
    defer p.deinit();
    var off: usize = 0;
    var names: std.ArrayList(u8) = .empty;
    defer names.deinit(gpa);
    while (off < data.len) {
        const r = (try p.parse(data[off..])).?;
        try names.appendSlice(gpa, r.args[0]);
        try names.append(gpa, ' ');
        off += r.consumed;
    }
    // 70 list items are split into a 64 item and a 6 item RPUSH.
    try testing.expectEqualStrings("SELECT SET RPUSH RPUSH SET PEXPIREAT SELECT ZADD ", names.items);
}

test "feed emits SELECT only when the database changes" {
    const gpa = testing.allocator;
    var aof = Aof.init(gpa, "/tmp", "unused.aof");
    defer aof.deinit();
    aof.enabled = true;
    try aof.feed(0, &.{ "SET", "a", "1" });
    try aof.feed(0, &.{ "SET", "b", "2" });
    try aof.feed(3, &.{ "DEL", "a" });
    try testing.expectEqualStrings(
        "*2\r\n$6\r\nSELECT\r\n$1\r\n0\r\n*3\r\n$3\r\nSET\r\n$1\r\na\r\n$1\r\n1\r\n" ++
            "*3\r\n$3\r\nSET\r\n$1\r\nb\r\n$1\r\n2\r\n" ++
            "*2\r\n$6\r\nSELECT\r\n$1\r\n3\r\n*2\r\n$3\r\nDEL\r\n$1\r\na\r\n",
        aof.buf.items,
    );
}

test "auto rewrite threshold" {
    var aof = Aof.init(testing.allocator, "/tmp", "x.aof");
    defer aof.deinit();
    aof.enabled = true;
    aof.base_size = 100;
    aof.current_size = 150;
    try testing.expect(!aof.shouldAutoRewrite(100, 0));
    aof.current_size = 200;
    try testing.expect(aof.shouldAutoRewrite(100, 0));
    try testing.expect(!aof.shouldAutoRewrite(100, 1000));
    try testing.expect(!aof.shouldAutoRewrite(0, 0));
}

test "background rewrite through fork installs a compacted file" {
    const gpa = testing.allocator;
    var clock: i64 = 1000;
    var stats: db_mod.Stats = .{};
    var dbs = [_]Db{Db.init(gpa, 0, &clock, &stats, 1)};
    defer dbs[0].deinit();
    var dir_buf: [128]u8 = undefined;
    const dir = try tmpDir(&dir_buf);
    var aof = Aof.init(gpa, dir, "bg.aof");
    defer aof.deinit();
    try aof.open();
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        try dbs[0].set("counter", try Value.initString(gpa, "v"), .{});
        try aof.feed(0, &.{ "SET", "counter", "v" });
    }
    _ = aof.flush(.no);
    try aof.startBackgroundRewrite(&dbs, clock);
    // A write that happens while the child runs must survive the swap.
    try dbs[0].set("late", try Value.initString(gpa, "1"), .{});
    try aof.feed(0, &.{ "SET", "late", "1" });
    var spins: usize = 0;
    while (aof.checkChild(clock) == .running and spins < 5000) : (spins += 1) sys.sleepMs(1);
    try testing.expectEqual(RewriteStatus.ok, aof.last_rewrite_status);
    _ = aof.flush(.no);

    var pbuf: [256]u8 = undefined;
    const data = (try sys.readFileAlloc(gpa, aof.pathInto(&pbuf))).?;
    defer gpa.free(data);
    try sys.unlink(aof.pathInto(&pbuf));
    try testing.expect(std.mem.indexOf(u8, data, "late") != null);
    try testing.expect(std.mem.count(u8, data, "counter") == 1);
}
