//! The polymorphic value stored under each key.

const std = @import("std");
const Allocator = std.mem.Allocator;
const List = @import("ds/list.zig").List;
const ZSet = @import("ds/zset.zig").ZSet;

/// Field -> value map. Keys and values are owned by the map.
pub const Hash = std.StringArrayHashMapUnmanaged([]u8);
/// Member set. Keys are owned by the set.
pub const Set = std.StringArrayHashMapUnmanaged(void);

pub const Kind = enum {
    string,
    list,
    hash,
    set,
    zset,

    pub fn name(self: Kind) []const u8 {
        return @tagName(self);
    }
};

pub const Value = union(Kind) {
    string: []u8,
    list: List,
    hash: Hash,
    set: Set,
    zset: *ZSet,

    pub fn kind(self: *const Value) Kind {
        return std.meta.activeTag(self.*);
    }

    pub fn initString(gpa: Allocator, bytes: []const u8) Allocator.Error!Value {
        return .{ .string = try gpa.dupe(u8, bytes) };
    }

    pub fn initZSet(gpa: Allocator, seed: u64) Allocator.Error!Value {
        const z = try gpa.create(ZSet);
        errdefer gpa.destroy(z);
        z.* = try ZSet.init(gpa, seed);
        return .{ .zset = z };
    }

    pub fn deinit(self: *Value, gpa: Allocator) void {
        switch (self.*) {
            .string => |s| gpa.free(s),
            .list => |*l| l.deinit(gpa),
            .hash => |*h| {
                var it = h.iterator();
                while (it.next()) |e| {
                    gpa.free(e.key_ptr.*);
                    gpa.free(e.value_ptr.*);
                }
                h.deinit(gpa);
            },
            .set => |*s| {
                for (s.keys()) |k| gpa.free(k);
                s.deinit(gpa);
            },
            .zset => |z| {
                z.deinit(gpa);
                gpa.destroy(z);
            },
        }
        self.* = undefined;
    }

    /// Number of elements for aggregate types; string length for strings.
    pub fn len(self: *const Value) usize {
        return switch (self.*) {
            .string => |s| s.len,
            .list => |l| l.len,
            .hash => |h| h.count(),
            .set => |s| s.count(),
            .zset => |z| z.len(),
        };
    }

    /// Deep copy, used by COPY.
    pub fn clone(self: *const Value, gpa: Allocator, seed: u64) Allocator.Error!Value {
        switch (self.*) {
            .string => |s| return .{ .string = try gpa.dupe(u8, s) },
            .list => |l| {
                var out: Value = .{ .list = .empty };
                errdefer out.deinit(gpa);
                var it = l.iterator();
                while (it.next()) |item| try out.list.pushBack(gpa, item);
                return out;
            },
            .hash => |h| {
                var out: Value = .{ .hash = .empty };
                errdefer out.deinit(gpa);
                try out.hash.ensureTotalCapacity(gpa, h.count());
                var it = h.iterator();
                while (it.next()) |e| {
                    const k = try gpa.dupe(u8, e.key_ptr.*);
                    errdefer gpa.free(k);
                    const v = try gpa.dupe(u8, e.value_ptr.*);
                    out.hash.putAssumeCapacityNoClobber(k, v);
                }
                return out;
            },
            .set => |s| {
                var out: Value = .{ .set = .empty };
                errdefer out.deinit(gpa);
                try out.set.ensureTotalCapacity(gpa, s.count());
                for (s.keys()) |k| out.set.putAssumeCapacityNoClobber(try gpa.dupe(u8, k), {});
                return out;
            },
            .zset => |z| {
                var out = try initZSet(gpa, seed);
                errdefer out.deinit(gpa);
                var node = z.list.first();
                while (node) |n| : (node = n.next()) {
                    _ = try out.zset.add(gpa, n.member, n.score, .{}, null);
                }
                return out;
            },
        }
    }
};

/// Inserts or replaces a hash field, copying both strings.
/// Returns true when the field was newly created.
pub fn hashSet(gpa: Allocator, h: *Hash, field: []const u8, val: []const u8) Allocator.Error!bool {
    const v = try gpa.dupe(u8, val);
    errdefer gpa.free(v);
    const gop = try h.getOrPut(gpa, field);
    if (gop.found_existing) {
        gpa.free(gop.value_ptr.*);
        gop.value_ptr.* = v;
        return false;
    }
    gop.key_ptr.* = gpa.dupe(u8, field) catch |err| {
        _ = h.swapRemove(field);
        return err;
    };
    gop.value_ptr.* = v;
    return true;
}

pub fn hashDelete(gpa: Allocator, h: *Hash, field: []const u8) bool {
    const kv = h.fetchSwapRemove(field) orelse return false;
    gpa.free(kv.key);
    gpa.free(kv.value);
    return true;
}

/// Adds a member to a set, copying it. Returns true when newly added.
pub fn setAdd(gpa: Allocator, s: *Set, member: []const u8) Allocator.Error!bool {
    const gop = try s.getOrPut(gpa, member);
    if (gop.found_existing) return false;
    gop.key_ptr.* = gpa.dupe(u8, member) catch |err| {
        _ = s.swapRemove(member);
        return err;
    };
    return true;
}

pub fn setRemove(gpa: Allocator, s: *Set, member: []const u8) bool {
    const kv = s.fetchSwapRemove(member) orelse return false;
    gpa.free(kv.key);
    return true;
}

const testing = std.testing;

test "hash helpers own their strings" {
    const gpa = testing.allocator;
    var v: Value = .{ .hash = .empty };
    defer v.deinit(gpa);
    try testing.expect(try hashSet(gpa, &v.hash, "f", "1"));
    try testing.expect(!try hashSet(gpa, &v.hash, "f", "2"));
    try testing.expectEqualStrings("2", v.hash.get("f").?);
    try testing.expect(hashDelete(gpa, &v.hash, "f"));
    try testing.expect(!hashDelete(gpa, &v.hash, "f"));
}

test "clone is deep for every kind" {
    const gpa = testing.allocator;
    var values = [_]Value{
        try Value.initString(gpa, "hello"),
        .{ .list = .empty },
        .{ .hash = .empty },
        .{ .set = .empty },
        try Value.initZSet(gpa, 1),
    };
    defer for (&values) |*v| v.deinit(gpa);
    try values[1].list.pushBack(gpa, "a");
    _ = try hashSet(gpa, &values[2].hash, "k", "v");
    _ = try setAdd(gpa, &values[3].set, "m");
    _ = try values[4].zset.add(gpa, "z", 1.5, .{}, null);
    for (&values) |*v| {
        var c = try v.clone(gpa, 9);
        defer c.deinit(gpa);
        try testing.expectEqual(v.kind(), c.kind());
        try testing.expectEqual(v.len(), c.len());
    }
    try testing.expectEqual(Kind.zset, values[4].kind());
    try testing.expectEqualStrings("zset", values[4].kind().name());
}
