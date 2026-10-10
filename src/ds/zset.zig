//! Sorted set: a hash index from member to score for O(1) lookups, plus a
//! skiplist for ordered and ranked access. The member bytes are owned by
//! the skiplist node; the hash index borrows the same slice.

const std = @import("std");
const Allocator = std.mem.Allocator;
const skiplist = @import("skiplist.zig");

pub const SkipList = skiplist.SkipList;
pub const Node = skiplist.Node;
pub const ScoreRange = skiplist.ScoreRange;
pub const LexRange = skiplist.LexRange;
pub const LexBound = skiplist.LexBound;

pub const ZSet = struct {
    dict: std.StringArrayHashMapUnmanaged(f64) = .empty,
    list: SkipList,

    pub fn init(gpa: Allocator, seed: u64) Allocator.Error!ZSet {
        return .{ .list = try SkipList.init(gpa, seed) };
    }

    pub fn deinit(self: *ZSet, gpa: Allocator) void {
        self.dict.deinit(gpa);
        self.list.deinit(gpa);
    }

    pub fn len(self: *const ZSet) usize {
        return self.dict.count();
    }

    pub fn score(self: *const ZSet, member: []const u8) ?f64 {
        return self.dict.get(member);
    }

    pub const AddFlags = struct {
        nx: bool = false,
        xx: bool = false,
        gt: bool = false,
        lt: bool = false,
        incr: bool = false,
    };

    pub const AddResult = enum { added, updated, unchanged, skipped, nan };

    /// ZADD semantics for one member. With `incr` the score is an increment
    /// and the resulting score is stored in `out_score`.
    pub fn add(self: *ZSet, gpa: Allocator, member: []const u8, value: f64, flags: AddFlags, out_score: ?*f64) Allocator.Error!AddResult {
        if (self.dict.getPtr(member)) |cur_ptr| {
            if (flags.nx) return .skipped;
            const cur = cur_ptr.*;
            var new = value;
            if (flags.incr) {
                new = cur + value;
                if (std.math.isNan(new)) return .nan;
            }
            if (flags.gt and new <= cur) return .skipped;
            if (flags.lt and new >= cur) return .skipped;
            if (out_score) |o| o.* = new;
            if (new == cur) return .unchanged;
            const node = try self.list.updateScore(gpa, cur, member, new);
            // The member slice is preserved across relinking, but refresh the
            // pointer in case the node moved.
            const gop = self.dict.getEntry(member).?;
            gop.key_ptr.* = node.member;
            gop.value_ptr.* = new;
            return .updated;
        }
        if (flags.xx) return .skipped;
        const owned = try gpa.dupe(u8, member);
        var inserted = false;
        errdefer if (!inserted) gpa.free(owned);
        try self.dict.ensureUnusedCapacity(gpa, 1);
        const node = try self.list.insert(gpa, value, owned);
        inserted = true;
        self.dict.putAssumeCapacityNoClobber(node.member, value);
        if (out_score) |o| o.* = value;
        return .added;
    }

    pub fn remove(self: *ZSet, gpa: Allocator, member: []const u8) bool {
        const s = self.dict.get(member) orelse return false;
        _ = self.dict.swapRemove(member);
        const ok = self.list.delete(gpa, s, member);
        std.debug.assert(ok);
        return true;
    }

    /// 0-based rank in ascending order.
    pub fn rank(self: *const ZSet, member: []const u8, reverse: bool) ?usize {
        const s = self.dict.get(member) orelse return null;
        const r = self.list.rank(s, member);
        std.debug.assert(r != 0);
        return if (reverse) self.list.len - r else r - 1;
    }

    /// Node at a 0-based rank in ascending order.
    pub fn atRank(self: *const ZSet, r: usize) ?*Node {
        return self.list.byRank(r + 1);
    }

    pub fn countInScoreRange(self: *const ZSet, range: ScoreRange) usize {
        const first = self.list.firstInScoreRange(range) orelse return 0;
        const last = self.list.lastInScoreRange(range) orelse return 0;
        return self.list.rank(last.score, last.member) - self.list.rank(first.score, first.member) + 1;
    }

    pub fn countInLexRange(self: *const ZSet, range: LexRange) usize {
        const first = self.list.firstInLexRange(range) orelse return 0;
        const last = self.list.lastInLexRange(range) orelse return 0;
        return self.list.rank(last.score, last.member) - self.list.rank(first.score, first.member) + 1;
    }

    /// Removes members whose 0-based rank is within [start, end].
    pub fn removeRankRange(self: *ZSet, gpa: Allocator, start: usize, end: usize) usize {
        var removed: usize = 0;
        var node = self.atRank(start);
        while (node) |n| {
            if (start + removed > end) break;
            const nxt = n.next();
            _ = self.dict.swapRemove(n.member);
            _ = self.list.delete(gpa, n.score, n.member);
            removed += 1;
            node = nxt;
        }
        return removed;
    }

    pub fn removeScoreRange(self: *ZSet, gpa: Allocator, range: ScoreRange) usize {
        var removed: usize = 0;
        var node = self.list.firstInScoreRange(range);
        while (node) |n| {
            if (!range.belowMax(n.score)) break;
            const nxt = n.next();
            _ = self.dict.swapRemove(n.member);
            _ = self.list.delete(gpa, n.score, n.member);
            removed += 1;
            node = nxt;
        }
        return removed;
    }

    pub fn removeLexRange(self: *ZSet, gpa: Allocator, range: LexRange) usize {
        var removed: usize = 0;
        var node = self.list.firstInLexRange(range);
        while (node) |n| {
            if (!range.belowMax(n.member)) break;
            const nxt = n.next();
            _ = self.dict.swapRemove(n.member);
            _ = self.list.delete(gpa, n.score, n.member);
            removed += 1;
            node = nxt;
        }
        return removed;
    }

    /// Removes and returns (via callback) the lowest or highest element.
    /// The returned member is owned by the caller.
    pub fn popExtreme(self: *ZSet, gpa: Allocator, max: bool) Allocator.Error!?struct { member: []u8, score: f64 } {
        const n = (if (max) self.list.last() else self.list.first()) orelse return null;
        const member = try gpa.dupe(u8, n.member);
        const s = n.score;
        _ = self.remove(gpa, member);
        return .{ .member = member, .score = s };
    }
};

/// Parses a ZRANGEBYSCORE style bound: a float optionally prefixed by `(`.
pub fn parseScoreBound(s: []const u8) ?struct { value: f64, exclusive: bool } {
    const num = @import("../num.zig");
    if (s.len > 0 and s[0] == '(') {
        const v = num.parseF64(s[1..]) orelse return null;
        return .{ .value = v, .exclusive = true };
    }
    const v = num.parseF64(s) orelse return null;
    return .{ .value = v, .exclusive = false };
}

const testing = std.testing;

test "zadd flags" {
    const gpa = testing.allocator;
    var z = try ZSet.init(gpa, 3);
    defer z.deinit(gpa);
    try testing.expectEqual(ZSet.AddResult.added, try z.add(gpa, "a", 1, .{}, null));
    try testing.expectEqual(ZSet.AddResult.unchanged, try z.add(gpa, "a", 1, .{}, null));
    try testing.expectEqual(ZSet.AddResult.skipped, try z.add(gpa, "a", 5, .{ .nx = true }, null));
    try testing.expectEqual(ZSet.AddResult.skipped, try z.add(gpa, "b", 5, .{ .xx = true }, null));
    try testing.expectEqual(ZSet.AddResult.skipped, try z.add(gpa, "a", 0, .{ .gt = true }, null));
    try testing.expectEqual(ZSet.AddResult.updated, try z.add(gpa, "a", 3, .{ .gt = true }, null));
    try testing.expectEqual(ZSet.AddResult.skipped, try z.add(gpa, "a", 4, .{ .lt = true }, null));
    var out: f64 = 0;
    try testing.expectEqual(ZSet.AddResult.updated, try z.add(gpa, "a", 2.5, .{ .incr = true }, &out));
    try testing.expectEqual(@as(f64, 5.5), out);
    try testing.expectEqual(@as(?f64, 5.5), z.score("a"));
    const inf = std.math.inf(f64);
    _ = try z.add(gpa, "i", inf, .{}, null);
    try testing.expectEqual(ZSet.AddResult.nan, try z.add(gpa, "i", -inf, .{ .incr = true }, null));
    try z.list.checkInvariants();
}

test "ranks and range removal" {
    const gpa = testing.allocator;
    var z = try ZSet.init(gpa, 4);
    defer z.deinit(gpa);
    for ([_][]const u8{ "a", "b", "c", "d", "e", "f" }, 0..) |m, i| {
        _ = try z.add(gpa, m, @floatFromInt(i), .{}, null);
    }
    try testing.expectEqual(@as(?usize, 0), z.rank("a", false));
    try testing.expectEqual(@as(?usize, 5), z.rank("a", true));
    try testing.expectEqual(@as(?usize, null), z.rank("zz", false));
    try testing.expectEqual(@as(usize, 3), z.countInScoreRange(.{ .min = 1, .max = 3 }));
    try testing.expectEqual(@as(usize, 2), z.removeRankRange(gpa, 0, 1));
    try testing.expectEqual(@as(usize, 4), z.len());
    try testing.expectEqual(@as(usize, 2), z.removeScoreRange(gpa, .{ .min = 2, .max = 3 }));
    try testing.expectEqualStrings("e", z.atRank(0).?.member);
    const popped = (try z.popExtreme(gpa, true)).?;
    defer gpa.free(popped.member);
    try testing.expectEqualStrings("f", popped.member);
    try testing.expectEqual(@as(usize, 1), z.len());
    try z.list.checkInvariants();
}

test "lex removal and counting" {
    const gpa = testing.allocator;
    var z = try ZSet.init(gpa, 5);
    defer z.deinit(gpa);
    for ([_][]const u8{ "a", "b", "c", "d" }) |m| _ = try z.add(gpa, m, 0, .{}, null);
    const r: LexRange = .{ .min = .{ .exclusive = "a" }, .max = .{ .inclusive = "c" } };
    try testing.expectEqual(@as(usize, 2), z.countInLexRange(r));
    try testing.expectEqual(@as(usize, 2), z.removeLexRange(gpa, r));
    try testing.expectEqual(@as(usize, 2), z.len());
    try testing.expect(z.score("b") == null);
}

test "parseScoreBound" {
    const a = parseScoreBound("(1.5").?;
    try testing.expect(a.exclusive);
    try testing.expectEqual(@as(f64, 1.5), a.value);
    try testing.expect(std.math.isNegativeInf(parseScoreBound("-inf").?.value));
    try testing.expect(parseScoreBound("(") == null);
    try testing.expect(parseScoreBound("abc") == null);
}
