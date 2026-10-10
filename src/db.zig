//! A logical database: the main keyspace plus the expiry index.
//!
//! Keys are owned by `dict`; `expires` borrows the very same slices, as in
//! Redis, so a key with a TTL costs one allocation. Both maps are array
//! hash maps, which gives O(1) uniform random sampling for RANDOMKEY and the
//! active expiry cycle, and a dense index space for SCAN cursors.
//!
//! Expiration is enforced in two ways. Every lookup checks the TTL and
//! deletes the key if it is already past due (lazy expiry), and the server
//! cron periodically samples keys with a TTL and evicts the expired ones
//! (active expiry), adapting its effort to how many it finds.

const std = @import("std");
const Allocator = std.mem.Allocator;
const value_mod = @import("value.zig");
const glob = @import("glob.zig");

pub const Value = value_mod.Value;
pub const Kind = value_mod.Kind;

pub const Stats = struct {
    keyspace_hits: u64 = 0,
    keyspace_misses: u64 = 0,
    expired_keys: u64 = 0,
};

/// Callbacks into the server for events that originate inside the keyspace.
pub const Listener = struct {
    ctx: *anyopaque,
    /// A key was removed because its TTL elapsed.
    on_expired: *const fn (ctx: *anyopaque, db: *Db, key: []const u8) void,
};

pub const Db = struct {
    gpa: Allocator,
    id: usize,
    dict: std.StringArrayHashMapUnmanaged(Value) = .empty,
    expires: std.StringArrayHashMapUnmanaged(i64) = .empty,
    /// Current time in ms as seen by the command being executed. Owned by
    /// the server so that a whole command (or transaction) sees one clock.
    clock: *const i64,
    stats: *Stats,
    listener: ?Listener = null,
    /// When false, lookups do not delete expired keys. Used while loading
    /// the AOF, where the file itself decides what exists.
    lazy_expire: bool = true,
    rng: std.Random.DefaultPrng,

    pub fn init(gpa: Allocator, id: usize, clock: *const i64, stats: *Stats, seed: u64) Db {
        return .{ .gpa = gpa, .id = id, .clock = clock, .stats = stats, .rng = std.Random.DefaultPrng.init(seed ^ id) };
    }

    pub fn deinit(self: *Db) void {
        self.clear();
        self.dict.deinit(self.gpa);
        self.expires.deinit(self.gpa);
    }

    pub fn size(self: *const Db) usize {
        return self.dict.count();
    }

    pub fn expiresCount(self: *const Db) usize {
        return self.expires.count();
    }

    /// Removes every key.
    pub fn clear(self: *Db) void {
        self.expires.clearRetainingCapacity();
        var it = self.dict.iterator();
        while (it.next()) |e| {
            e.value_ptr.deinit(self.gpa);
            self.gpa.free(e.key_ptr.*);
        }
        self.dict.clearRetainingCapacity();
        if (self.dict.capacity() > 1024) {
            self.dict.clearAndFree(self.gpa);
            self.expires.clearAndFree(self.gpa);
        }
    }

    pub fn nextSeed(self: *Db) u64 {
        return self.rng.random().int(u64);
    }

    fn isExpired(self: *const Db, key: []const u8) bool {
        const when = self.expires.get(key) orelse return false;
        return when <= self.clock.*;
    }

    /// Deletes the key if its TTL has elapsed. Returns true if it did.
    pub fn expireIfNeeded(self: *Db, key: []const u8) bool {
        if (!self.lazy_expire) return false;
        if (!self.isExpired(key)) return false;
        self.evictExpired(key);
        return true;
    }

    fn evictExpired(self: *Db, key: []const u8) void {
        self.stats.expired_keys += 1;
        // Notify before freeing so the listener can still read the key.
        if (self.listener) |l| l.on_expired(l.ctx, self, key);
        _ = self.delete(key);
    }

    /// Looks up a key for reading, applying lazy expiry and hit/miss stats.
    pub fn lookupRead(self: *Db, key: []const u8) ?*Value {
        _ = self.expireIfNeeded(key);
        if (self.dict.getPtr(key)) |v| {
            self.stats.keyspace_hits += 1;
            return v;
        }
        self.stats.keyspace_misses += 1;
        return null;
    }

    /// Looks up a key for writing. Applies lazy expiry, no stats.
    pub fn lookupWrite(self: *Db, key: []const u8) ?*Value {
        _ = self.expireIfNeeded(key);
        return self.dict.getPtr(key);
    }

    /// True when the key exists and is not expired.
    pub fn exists(self: *Db, key: []const u8) bool {
        _ = self.expireIfNeeded(key);
        return self.dict.contains(key);
    }

    /// Inserts a new key that must not already exist. Takes ownership of
    /// `value`; on failure the value is left for the caller to free.
    pub fn add(self: *Db, key: []const u8, value: Value) Allocator.Error!*Value {
        try self.dict.ensureUnusedCapacity(self.gpa, 1);
        const owned = try self.gpa.dupe(u8, key);
        const gop = self.dict.getOrPutAssumeCapacity(key);
        std.debug.assert(!gop.found_existing);
        gop.key_ptr.* = owned;
        gop.value_ptr.* = value;
        return gop.value_ptr;
    }

    pub const SetOptions = struct {
        keep_ttl: bool = false,
    };

    /// Sets a key to `value`, replacing any existing value of any type and,
    /// unless `keep_ttl`, clearing its TTL. Takes ownership of `value`.
    pub fn set(self: *Db, key: []const u8, value: Value, opts: SetOptions) Allocator.Error!void {
        if (self.dict.getEntry(key)) |e| {
            e.value_ptr.deinit(self.gpa);
            e.value_ptr.* = value;
            if (!opts.keep_ttl) _ = self.expires.swapRemove(key);
            return;
        }
        _ = try self.add(key, value);
    }

    /// Removes a key and frees its value. Returns false if it did not exist.
    pub fn delete(self: *Db, key: []const u8) bool {
        _ = self.expires.swapRemove(key);
        const kv = self.dict.fetchSwapRemove(key) orelse return false;
        var v = kv.value;
        v.deinit(self.gpa);
        self.gpa.free(kv.key);
        return true;
    }

    /// Removes the key and hands its value to the caller.
    pub fn take(self: *Db, key: []const u8) ?Value {
        _ = self.expires.swapRemove(key);
        const kv = self.dict.fetchSwapRemove(key) orelse return null;
        self.gpa.free(kv.key);
        return kv.value;
    }

    /// Absolute expiry time in ms, or null when the key has no TTL.
    pub fn getExpire(self: *const Db, key: []const u8) ?i64 {
        return self.expires.get(key);
    }

    /// Sets an absolute expiry for an existing key.
    pub fn setExpire(self: *Db, key: []const u8, when_ms: i64) Allocator.Error!void {
        const owned_key = self.dict.getKey(key) orelse unreachable;
        try self.expires.put(self.gpa, owned_key, when_ms);
    }

    /// Removes the TTL. Returns true if the key had one.
    pub fn persist(self: *Db, key: []const u8) bool {
        return self.expires.swapRemove(key);
    }

    /// Uniformly random live key, or null if the database is empty.
    /// Expired keys encountered on the way are evicted.
    pub fn randomKey(self: *Db) ?[]const u8 {
        var attempts: usize = 0;
        while (self.dict.count() > 0) : (attempts += 1) {
            const keys = self.dict.keys();
            const key = keys[self.rng.random().uintLessThan(usize, keys.len)];
            if (!self.isExpired(key)) return key;
            // If every key has a TTL in the past, keep evicting; otherwise a
            // bounded number of attempts suffices to find a live key.
            if (attempts > 100 and self.expires.count() != self.dict.count()) {
                for (self.dict.keys()) |k| if (!self.isExpired(k)) return k;
            }
            self.evictExpired(key);
        }
        return null;
    }

    /// One round of active expiry. Samples up to `samples` keys with a TTL
    /// and evicts those past due, repeating while more than a quarter of a
    /// sample was expired and the time budget allows. Returns the number of
    /// keys evicted.
    pub fn activeExpireCycle(self: *Db, samples: usize, deadline_ns: u64, now_ns: *const fn () u64) usize {
        var evicted: usize = 0;
        while (true) {
            const n = self.expires.count();
            if (n == 0) return evicted;
            const take_n = @min(samples, n);
            var expired_in_round: usize = 0;
            var i: usize = 0;
            while (i < take_n) : (i += 1) {
                const count = self.expires.count();
                if (count == 0) break;
                const idx = self.rng.random().uintLessThan(usize, count);
                const key = self.expires.keys()[idx];
                if (self.expires.values()[idx] <= self.clock.*) {
                    self.evictExpired(key);
                    expired_in_round += 1;
                }
            }
            evicted += expired_in_round;
            if (expired_in_round * 4 <= take_n) return evicted;
            if (now_ns() >= deadline_ns) return evicted;
        }
    }

    pub const ScanResult = struct {
        cursor: u64,
    };

    /// Walks the dense index space from high to low. Removing an element
    /// moves the last element into its slot; since the last element has
    /// already been visited, iterating downwards never skips an element
    /// that existed for the whole scan (it may at worst repeat one), which
    /// is exactly the guarantee Redis documents for SCAN.
    pub fn scanIndices(total: usize, cursor: u64, count: usize, visitor: anytype) u64 {
        var pos: usize = if (cursor == 0 or cursor > total) total else @intCast(cursor);
        var visited: usize = 0;
        while (pos > 0 and visited < count) {
            pos -= 1;
            visited += 1;
            visitor.visit(pos);
        }
        return pos;
    }

    /// Iterates keys for SCAN, applying an optional glob and type filter.
    pub fn scan(self: *Db, gpa: Allocator, cursor: u64, count: usize, pattern: ?[]const u8, type_filter: ?Kind, out: *std.ArrayList([]const u8)) Allocator.Error!u64 {
        const Visitor = struct {
            db: *Db,
            candidates: std.ArrayList([]const u8) = .empty,
            gpa: Allocator,
            oom: bool = false,

            pub fn visit(v: *@This(), idx: usize) void {
                v.candidates.append(v.gpa, v.db.dict.keys()[idx]) catch {
                    v.oom = true;
                };
            }
        };
        var visitor: Visitor = .{ .db = self, .gpa = gpa };
        defer visitor.candidates.deinit(gpa);
        const next = scanIndices(self.dict.count(), cursor, count, &visitor);
        if (visitor.oom) return error.OutOfMemory;
        // Filter after collecting: expiring a key mutates the index space.
        for (visitor.candidates.items) |key| {
            if (pattern) |p| if (!glob.match(p, key)) continue;
            if (self.isExpired(key)) continue;
            if (type_filter) |t| {
                const v = self.dict.getPtr(key) orelse continue;
                if (v.kind() != t) continue;
            }
            try out.append(gpa, key);
        }
        return next;
    }
};

const testing = std.testing;

const TestEnv = struct {
    clock: i64 = 1_000,
    stats: Stats = .{},
};

fn monoZero() u64 {
    return 0;
}

test "set, get, delete and overwrite" {
    var env: TestEnv = .{};
    var db = Db.init(testing.allocator, 0, &env.clock, &env.stats, 1);
    defer db.deinit();
    try db.set("k", try Value.initString(testing.allocator, "v1"), .{});
    try testing.expectEqualStrings("v1", db.lookupRead("k").?.string);
    try db.set("k", try Value.initString(testing.allocator, "v2"), .{});
    try testing.expectEqualStrings("v2", db.lookupRead("k").?.string);
    try testing.expect(db.lookupRead("missing") == null);
    try testing.expectEqual(@as(u64, 2), env.stats.keyspace_hits);
    try testing.expectEqual(@as(u64, 1), env.stats.keyspace_misses);
    try testing.expect(db.delete("k"));
    try testing.expect(!db.delete("k"));
    try testing.expectEqual(@as(usize, 0), db.size());
}

test "lazy expiry and set clears ttl unless keep_ttl" {
    var env: TestEnv = .{};
    var db = Db.init(testing.allocator, 0, &env.clock, &env.stats, 1);
    defer db.deinit();
    try db.set("k", try Value.initString(testing.allocator, "v"), .{});
    try db.setExpire("k", 1_500);
    try db.set("k", try Value.initString(testing.allocator, "v2"), .{ .keep_ttl = true });
    try testing.expectEqual(@as(?i64, 1_500), db.getExpire("k"));
    env.clock = 1_499;
    try testing.expect(db.exists("k"));
    env.clock = 1_500;
    try testing.expect(!db.exists("k"));
    try testing.expectEqual(@as(u64, 1), env.stats.expired_keys);
    try testing.expectEqual(@as(usize, 0), db.expiresCount());

    try db.set("p", try Value.initString(testing.allocator, "v"), .{});
    try db.setExpire("p", 5_000);
    try db.set("p", try Value.initString(testing.allocator, "w"), .{});
    try testing.expect(db.getExpire("p") == null);
}

test "active expiry evicts sampled keys and notifies" {
    var env: TestEnv = .{};
    var db = Db.init(testing.allocator, 0, &env.clock, &env.stats, 7);
    defer db.deinit();
    const Counter = struct {
        n: usize = 0,
        fn onExpired(ctx: *anyopaque, _: *Db, _: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.n += 1;
        }
    };
    var counter: Counter = .{};
    db.listener = .{ .ctx = &counter, .on_expired = Counter.onExpired };
    var buf: [16]u8 = undefined;
    var i: usize = 0;
    while (i < 500) : (i += 1) {
        const k = std.fmt.bufPrint(&buf, "k{d}", .{i}) catch unreachable;
        try db.set(k, try Value.initString(testing.allocator, "v"), .{});
        try db.setExpire(k, if (i % 5 == 0) 5_000 else 1_100);
    }
    env.clock = 2_000;
    var rounds: usize = 0;
    while (db.expiresCount() > 100 and rounds < 1000) : (rounds += 1) {
        _ = db.activeExpireCycle(20, std.math.maxInt(u64), &monoZero);
    }
    try testing.expectEqual(@as(usize, 100), db.size());
    try testing.expectEqual(@as(usize, 400), counter.n);
}

test "scan visits every stable key despite deletions" {
    var env: TestEnv = .{};
    var db = Db.init(testing.allocator, 0, &env.clock, &env.stats, 3);
    defer db.deinit();
    var buf: [16]u8 = undefined;
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const k = std.fmt.bufPrint(&buf, "key:{d}", .{i}) catch unreachable;
        try db.set(k, try Value.initString(testing.allocator, "v"), .{});
    }
    var seen = std.StringHashMap(void).init(testing.allocator);
    defer {
        var it = seen.keyIterator();
        while (it.next()) |k| testing.allocator.free(k.*);
        seen.deinit();
    }
    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(testing.allocator);
    var cursor: u64 = 0;
    var round: usize = 0;
    while (true) : (round += 1) {
        out.clearRetainingCapacity();
        cursor = try db.scan(testing.allocator, cursor, 7, null, null, &out);
        for (out.items) |k| {
            if (!seen.contains(k)) try seen.put(try testing.allocator.dupe(u8, k), {});
        }
        // Delete an odd key every round to perturb the index space.
        const victim = std.fmt.bufPrint(&buf, "key:{d}", .{round * 2 + 1}) catch unreachable;
        _ = db.delete(victim);
        if (cursor == 0) break;
    }
    // Every even key (never deleted) must have been returned.
    i = 0;
    while (i < 100) : (i += 2) {
        const k = std.fmt.bufPrint(&buf, "key:{d}", .{i}) catch unreachable;
        try testing.expect(seen.contains(k));
    }
}

test "scan with pattern and type filters" {
    var env: TestEnv = .{};
    var db = Db.init(testing.allocator, 0, &env.clock, &env.stats, 3);
    defer db.deinit();
    try db.set("user:1", try Value.initString(testing.allocator, "a"), .{});
    try db.set("user:2", .{ .list = .empty }, .{});
    try db.set("other", try Value.initString(testing.allocator, "b"), .{});
    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(testing.allocator);
    const c = try db.scan(testing.allocator, 0, 100, "user:*", .string, &out);
    try testing.expectEqual(@as(u64, 0), c);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqualStrings("user:1", out.items[0]);
}

test "randomKey skips expired keys" {
    var env: TestEnv = .{};
    var db = Db.init(testing.allocator, 0, &env.clock, &env.stats, 11);
    defer db.deinit();
    try testing.expect(db.randomKey() == null);
    try db.set("dead", try Value.initString(testing.allocator, "v"), .{});
    try db.setExpire("dead", 10);
    try db.set("alive", try Value.initString(testing.allocator, "v"), .{});
    var i: usize = 0;
    while (i < 20) : (i += 1) try testing.expectEqualStrings("alive", db.randomKey().?);
    try db.setExpire("alive", 10);
    try testing.expect(db.randomKey() == null);
    try testing.expectEqual(@as(usize, 0), db.size());
}

test "take moves ownership out" {
    var env: TestEnv = .{};
    var db = Db.init(testing.allocator, 0, &env.clock, &env.stats, 1);
    defer db.deinit();
    try db.set("k", try Value.initString(testing.allocator, "v"), .{});
    try db.setExpire("k", 99_999);
    var v = db.take("k").?;
    defer v.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), db.size());
    try testing.expectEqual(@as(usize, 0), db.expiresCount());
}
