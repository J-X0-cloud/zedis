//! The list type: a growable ring buffer of owned byte strings.
//!
//! Push and pop at either end are O(1) amortized, indexing is O(1), and
//! inserting or removing in the middle shifts whichever side is shorter,
//! so operations near either end stay cheap. Elements are owned by the
//! list and freed with the list's allocator.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const List = struct {
    buf: [][]u8 = &.{},
    head: usize = 0,
    len: usize = 0,

    pub const empty: List = .{};

    pub fn deinit(self: *List, gpa: Allocator) void {
        var i: usize = 0;
        while (i < self.len) : (i += 1) gpa.free(self.buf[self.phys(i)]);
        gpa.free(self.buf);
        self.* = .{};
    }

    inline fn phys(self: *const List, i: usize) usize {
        const p = self.head + i;
        return if (p >= self.buf.len) p - self.buf.len else p;
    }

    fn grow(self: *List, gpa: Allocator) Allocator.Error!void {
        const new_cap = if (self.buf.len == 0) 8 else self.buf.len * 2;
        const nb = try gpa.alloc([]u8, new_cap);
        var i: usize = 0;
        while (i < self.len) : (i += 1) nb[i] = self.buf[self.phys(i)];
        gpa.free(self.buf);
        self.buf = nb;
        self.head = 0;
    }

    /// Shrinks the backing array when it is mostly empty, so a list that
    /// briefly held millions of items does not pin that memory forever.
    fn maybeShrink(self: *List, gpa: Allocator) void {
        if (self.buf.len <= 16 or self.len * 4 > self.buf.len) return;
        const new_cap = @max(16, self.buf.len / 2);
        const nb = gpa.alloc([]u8, new_cap) catch return;
        var i: usize = 0;
        while (i < self.len) : (i += 1) nb[i] = self.buf[self.phys(i)];
        gpa.free(self.buf);
        self.buf = nb;
        self.head = 0;
    }

    fn ensureSpare(self: *List, gpa: Allocator) Allocator.Error!void {
        if (self.len == self.buf.len) try self.grow(gpa);
    }

    /// Pushes a copy of `item` at the head.
    pub fn pushFront(self: *List, gpa: Allocator, item: []const u8) Allocator.Error!void {
        const owned = try gpa.dupe(u8, item);
        errdefer gpa.free(owned);
        try self.pushFrontOwned(gpa, owned);
    }

    /// Pushes a copy of `item` at the tail.
    pub fn pushBack(self: *List, gpa: Allocator, item: []const u8) Allocator.Error!void {
        const owned = try gpa.dupe(u8, item);
        errdefer gpa.free(owned);
        try self.pushBackOwned(gpa, owned);
    }

    pub fn pushFrontOwned(self: *List, gpa: Allocator, owned: []u8) Allocator.Error!void {
        try self.ensureSpare(gpa);
        self.head = if (self.head == 0) self.buf.len - 1 else self.head - 1;
        self.buf[self.head] = owned;
        self.len += 1;
    }

    pub fn pushBackOwned(self: *List, gpa: Allocator, owned: []u8) Allocator.Error!void {
        try self.ensureSpare(gpa);
        self.buf[self.phys(self.len)] = owned;
        self.len += 1;
    }

    /// Removes and returns the head element; the caller owns it.
    pub fn popFront(self: *List, gpa: Allocator) ?[]u8 {
        if (self.len == 0) return null;
        const item = self.buf[self.head];
        self.head = self.phys(1);
        self.len -= 1;
        if (self.len == 0) self.head = 0;
        self.maybeShrink(gpa);
        return item;
    }

    /// Removes and returns the tail element; the caller owns it.
    pub fn popBack(self: *List, gpa: Allocator) ?[]u8 {
        if (self.len == 0) return null;
        const item = self.buf[self.phys(self.len - 1)];
        self.len -= 1;
        if (self.len == 0) self.head = 0;
        self.maybeShrink(gpa);
        return item;
    }

    pub fn get(self: *const List, i: usize) []u8 {
        std.debug.assert(i < self.len);
        return self.buf[self.phys(i)];
    }

    /// Resolves a Redis index (negative counts from the tail).
    pub fn resolveIndex(self: *const List, index: i64) ?usize {
        const l: i64 = @intCast(self.len);
        const i = if (index < 0) index + l else index;
        if (i < 0 or i >= l) return null;
        return @intCast(i);
    }

    /// Replaces element `i` with a copy of `item`.
    pub fn set(self: *List, gpa: Allocator, i: usize, item: []const u8) Allocator.Error!void {
        const owned = try gpa.dupe(u8, item);
        const slot = &self.buf[self.phys(i)];
        gpa.free(slot.*);
        slot.* = owned;
    }

    /// Inserts a copy of `item` so that it ends up at position `i`.
    pub fn insertAt(self: *List, gpa: Allocator, i: usize, item: []const u8) Allocator.Error!void {
        std.debug.assert(i <= self.len);
        const owned = try gpa.dupe(u8, item);
        errdefer gpa.free(owned);
        if (i == 0) return self.pushFrontOwned(gpa, owned);
        if (i == self.len) return self.pushBackOwned(gpa, owned);
        try self.ensureSpare(gpa);
        if (i < self.len / 2) {
            // Shift the front part one slot towards the head.
            self.head = if (self.head == 0) self.buf.len - 1 else self.head - 1;
            var j: usize = 0;
            while (j < i) : (j += 1) self.buf[self.phys(j)] = self.buf[self.phys(j + 1)];
        } else {
            var j: usize = self.len;
            while (j > i) : (j -= 1) self.buf[self.phys(j)] = self.buf[self.phys(j - 1)];
        }
        self.buf[self.phys(i)] = owned;
        self.len += 1;
    }

    /// Removes element `i` and frees it.
    pub fn removeAt(self: *List, gpa: Allocator, i: usize) void {
        std.debug.assert(i < self.len);
        gpa.free(self.buf[self.phys(i)]);
        if (i < self.len / 2) {
            var j: usize = i;
            while (j > 0) : (j -= 1) self.buf[self.phys(j)] = self.buf[self.phys(j - 1)];
            self.head = self.phys(1);
        } else {
            var j: usize = i;
            while (j + 1 < self.len) : (j += 1) self.buf[self.phys(j)] = self.buf[self.phys(j + 1)];
        }
        self.len -= 1;
        if (self.len == 0) self.head = 0;
        self.maybeShrink(gpa);
    }

    /// Keeps only the inclusive range [start, end]; frees everything else.
    pub fn retainRange(self: *List, gpa: Allocator, start: usize, end: usize) void {
        std.debug.assert(start <= end and end < self.len);
        var i: usize = 0;
        while (i < start) : (i += 1) gpa.free(self.buf[self.phys(i)]);
        i = end + 1;
        while (i < self.len) : (i += 1) gpa.free(self.buf[self.phys(i)]);
        self.head = self.phys(start);
        self.len = end - start + 1;
        self.maybeShrink(gpa);
    }

    /// Frees every element but keeps the list usable.
    pub fn clear(self: *List, gpa: Allocator) void {
        var i: usize = 0;
        while (i < self.len) : (i += 1) gpa.free(self.buf[self.phys(i)]);
        self.head = 0;
        self.len = 0;
        self.maybeShrink(gpa);
    }

    /// Removes up to `count` elements equal to `value`. A positive count
    /// scans from the head, a negative count from the tail, and zero removes
    /// all matches. Returns how many were removed.
    pub fn removeMatching(self: *List, gpa: Allocator, value: []const u8, count: i64) usize {
        const limit: usize = if (count == 0) std.math.maxInt(usize) else @intCast(@abs(count));
        var removed: usize = 0;
        if (count >= 0) {
            // Stable compaction from the head.
            var write: usize = 0;
            var read: usize = 0;
            while (read < self.len) : (read += 1) {
                const item = self.buf[self.phys(read)];
                if (removed < limit and std.mem.eql(u8, item, value)) {
                    gpa.free(item);
                    removed += 1;
                } else {
                    self.buf[self.phys(write)] = item;
                    write += 1;
                }
            }
            self.len = write;
        } else {
            // Stable compaction from the tail towards the head.
            var write: usize = self.len;
            var read: usize = self.len;
            while (read > 0) {
                read -= 1;
                const item = self.buf[self.phys(read)];
                if (removed < limit and std.mem.eql(u8, item, value)) {
                    gpa.free(item);
                    removed += 1;
                } else {
                    write -= 1;
                    self.buf[self.phys(write)] = item;
                }
            }
            self.head = self.phys(write);
            self.len -= write;
        }
        if (self.len == 0) self.head = 0;
        self.maybeShrink(gpa);
        return removed;
    }

    pub const Iterator = struct {
        list: *const List,
        i: usize,

        pub fn next(it: *Iterator) ?[]u8 {
            if (it.i >= it.list.len) return null;
            defer it.i += 1;
            return it.list.get(it.i);
        }
    };

    pub fn iterator(self: *const List) Iterator {
        return .{ .list = self, .i = 0 };
    }
};

const testing = std.testing;

fn expectContents(l: *const List, expected: []const []const u8) !void {
    try testing.expectEqual(expected.len, l.len);
    for (expected, 0..) |e, i| try testing.expectEqualStrings(e, l.get(i));
}

test "push and pop both ends with wraparound" {
    const gpa = testing.allocator;
    var l: List = .empty;
    defer l.deinit(gpa);
    try l.pushBack(gpa, "b");
    try l.pushFront(gpa, "a");
    try l.pushBack(gpa, "c");
    try expectContents(&l, &.{ "a", "b", "c" });
    const a = l.popFront(gpa).?;
    defer gpa.free(a);
    try testing.expectEqualStrings("a", a);
    const c = l.popBack(gpa).?;
    defer gpa.free(c);
    try testing.expectEqualStrings("c", c);
    try expectContents(&l, &.{"b"});

    // Force many wraparounds and growth.
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        var buf: [8]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable;
        if (i % 2 == 0) try l.pushFront(gpa, s) else try l.pushBack(gpa, s);
    }
    try testing.expectEqual(@as(usize, 101), l.len);
    try testing.expectEqualStrings("98", l.get(0));
    try testing.expectEqualStrings("99", l.get(100));
}

test "insert and remove in the middle shift the short side" {
    const gpa = testing.allocator;
    var l: List = .empty;
    defer l.deinit(gpa);
    for ([_][]const u8{ "a", "b", "d", "e" }) |s| try l.pushBack(gpa, s);
    try l.insertAt(gpa, 2, "c");
    try expectContents(&l, &.{ "a", "b", "c", "d", "e" });
    try l.insertAt(gpa, 1, "x");
    try expectContents(&l, &.{ "a", "x", "b", "c", "d", "e" });
    l.removeAt(gpa, 1);
    l.removeAt(gpa, 3);
    try expectContents(&l, &.{ "a", "b", "c", "e" });
    l.removeAt(gpa, 0);
    l.removeAt(gpa, 2);
    try expectContents(&l, &.{ "b", "c" });
}

test "retainRange implements LTRIM" {
    const gpa = testing.allocator;
    var l: List = .empty;
    defer l.deinit(gpa);
    for ([_][]const u8{ "1", "2", "3", "4", "5" }) |s| try l.pushBack(gpa, s);
    l.retainRange(gpa, 1, 3);
    try expectContents(&l, &.{ "2", "3", "4" });
}

test "removeMatching honours count direction" {
    const gpa = testing.allocator;
    var l: List = .empty;
    defer l.deinit(gpa);
    for ([_][]const u8{ "x", "a", "x", "b", "x", "c", "x" }) |s| try l.pushBack(gpa, s);
    try testing.expectEqual(@as(usize, 2), l.removeMatching(gpa, "x", -2));
    try expectContents(&l, &.{ "x", "a", "x", "b", "c" });
    try testing.expectEqual(@as(usize, 1), l.removeMatching(gpa, "x", 1));
    try expectContents(&l, &.{ "a", "x", "b", "c" });
    try testing.expectEqual(@as(usize, 1), l.removeMatching(gpa, "x", 0));
    try expectContents(&l, &.{ "a", "b", "c" });
    try testing.expectEqual(@as(usize, 0), l.removeMatching(gpa, "zz", 0));
}

test "set and resolveIndex" {
    const gpa = testing.allocator;
    var l: List = .empty;
    defer l.deinit(gpa);
    for ([_][]const u8{ "a", "b", "c" }) |s| try l.pushBack(gpa, s);
    try testing.expectEqual(@as(?usize, 2), l.resolveIndex(-1));
    try testing.expectEqual(@as(?usize, null), l.resolveIndex(3));
    try testing.expectEqual(@as(?usize, null), l.resolveIndex(-4));
    try l.set(gpa, 1, "B");
    try expectContents(&l, &.{ "a", "B", "c" });
}

test "shrinks after draining" {
    const gpa = testing.allocator;
    var l: List = .empty;
    defer l.deinit(gpa);
    var i: usize = 0;
    while (i < 1000) : (i += 1) try l.pushBack(gpa, "v");
    const big_cap = l.buf.len;
    while (l.len > 3) gpa.free(l.popFront(gpa).?);
    try testing.expect(l.buf.len < big_cap);
    try expectContents(&l, &.{ "v", "v", "v" });
}
