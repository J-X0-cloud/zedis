//! A skiplist ordered by (score, member), with per-link spans so rank
//! queries are O(log n). This is the same design Redis uses for sorted
//! sets: each node carries a backward pointer for reverse iteration and
//! each forward link records how many nodes it skips.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const max_level = 32;
const branching_p: u32 = 0x4000; // 0.25 in 16-bit fixed point

pub const Node = struct {
    score: f64,
    member: []u8,
    backward: ?*Node,
    levels: []Level,

    pub const Level = struct {
        forward: ?*Node,
        span: usize,
    };

    pub fn next(self: *const Node) ?*Node {
        return self.levels[0].forward;
    }
};

/// Inclusive or exclusive bounds on scores.
pub const ScoreRange = struct {
    min: f64,
    max: f64,
    min_ex: bool = false,
    max_ex: bool = false,

    pub fn aboveMin(self: ScoreRange, v: f64) bool {
        return if (self.min_ex) v > self.min else v >= self.min;
    }

    pub fn belowMax(self: ScoreRange, v: f64) bool {
        return if (self.max_ex) v < self.max else v <= self.max;
    }

    pub fn isEmpty(self: ScoreRange) bool {
        return self.min > self.max or (self.min == self.max and (self.min_ex or self.max_ex));
    }
};

/// A lexicographic bound: negative/positive infinity or a string that is
/// either inclusive (`[`) or exclusive (`(`).
pub const LexBound = union(enum) {
    neg_inf,
    pos_inf,
    inclusive: []const u8,
    exclusive: []const u8,

    /// Parses `-`, `+`, `[value` or `(value`.
    pub fn parse(s: []const u8) ?LexBound {
        if (s.len == 0) return null;
        return switch (s[0]) {
            '-' => if (s.len == 1) .neg_inf else null,
            '+' => if (s.len == 1) .pos_inf else null,
            '[' => .{ .inclusive = s[1..] },
            '(' => .{ .exclusive = s[1..] },
            else => null,
        };
    }
};

pub const LexRange = struct {
    min: LexBound,
    max: LexBound,

    pub fn aboveMin(self: LexRange, v: []const u8) bool {
        return switch (self.min) {
            .neg_inf => true,
            .pos_inf => false,
            .inclusive => |m| std.mem.order(u8, v, m) != .lt,
            .exclusive => |m| std.mem.order(u8, v, m) == .gt,
        };
    }

    pub fn belowMax(self: LexRange, v: []const u8) bool {
        return switch (self.max) {
            .neg_inf => false,
            .pos_inf => true,
            .inclusive => |m| std.mem.order(u8, v, m) != .gt,
            .exclusive => |m| std.mem.order(u8, v, m) == .lt,
        };
    }

    pub fn isEmpty(self: LexRange) bool {
        if (self.min == .pos_inf or self.max == .neg_inf) return true;
        if (self.min == .neg_inf or self.max == .pos_inf) return false;
        const a = switch (self.min) {
            .inclusive, .exclusive => |s| s,
            else => unreachable,
        };
        const b = switch (self.max) {
            .inclusive, .exclusive => |s| s,
            else => unreachable,
        };
        return switch (std.mem.order(u8, a, b)) {
            .gt => true,
            .eq => self.min == .exclusive or self.max == .exclusive,
            .lt => false,
        };
    }
};

/// Total order used by the skiplist: score first, then member bytes.
fn lessThan(score_a: f64, member_a: []const u8, score_b: f64, member_b: []const u8) bool {
    if (score_a != score_b) return score_a < score_b;
    return std.mem.order(u8, member_a, member_b) == .lt;
}

pub const SkipList = struct {
    header: *Node,
    tail: ?*Node = null,
    len: usize = 0,
    level: usize = 1,
    rng: std.Random.DefaultPrng,

    pub fn init(gpa: Allocator, seed: u64) Allocator.Error!SkipList {
        const header = try createNode(gpa, max_level, 0, &.{});
        for (header.levels) |*l| l.* = .{ .forward = null, .span = 0 };
        header.backward = null;
        return .{ .header = header, .rng = std.Random.DefaultPrng.init(seed) };
    }

    pub fn deinit(self: *SkipList, gpa: Allocator) void {
        var node = self.header.levels[0].forward;
        while (node) |n| {
            const nxt = n.levels[0].forward;
            destroyNode(gpa, n);
            node = nxt;
        }
        destroyNode(gpa, self.header);
        self.* = undefined;
    }

    fn createNode(gpa: Allocator, level: usize, score: f64, member: []u8) Allocator.Error!*Node {
        const node = try gpa.create(Node);
        errdefer gpa.destroy(node);
        const levels = try gpa.alloc(Node.Level, level);
        node.* = .{ .score = score, .member = member, .backward = null, .levels = levels };
        return node;
    }

    fn destroyNode(gpa: Allocator, node: *Node) void {
        gpa.free(node.member);
        gpa.free(node.levels);
        gpa.destroy(node);
    }

    fn randomLevel(self: *SkipList) usize {
        var level: usize = 1;
        const r = self.rng.random();
        while (level < max_level and (r.int(u16) & 0xFFFF) < branching_p) level += 1;
        return level;
    }

    /// Inserts a node taking ownership of `member`. The caller guarantees
    /// that the member is not already present. Returns the new node.
    pub fn insert(self: *SkipList, gpa: Allocator, score: f64, member: []u8) Allocator.Error!*Node {
        var update: [max_level]*Node = undefined;
        var ranks: [max_level]usize = undefined;
        var x = self.header;
        var i: usize = self.level;
        while (i > 0) {
            i -= 1;
            ranks[i] = if (i == self.level - 1) 0 else ranks[i + 1];
            while (x.levels[i].forward) |f| {
                if (!lessThan(f.score, f.member, score, member)) break;
                ranks[i] += x.levels[i].span;
                x = f;
            }
            update[i] = x;
        }
        const level = self.randomLevel();
        if (level > self.level) {
            var j = self.level;
            while (j < level) : (j += 1) {
                ranks[j] = 0;
                update[j] = self.header;
                update[j].levels[j].span = self.len;
            }
            self.level = level;
        }
        const node = try createNode(gpa, level, score, member);
        var j: usize = 0;
        while (j < level) : (j += 1) {
            node.levels[j].forward = update[j].levels[j].forward;
            update[j].levels[j].forward = node;
            node.levels[j].span = update[j].levels[j].span - (ranks[0] - ranks[j]);
            update[j].levels[j].span = (ranks[0] - ranks[j]) + 1;
        }
        // Untouched higher levels now skip one more node.
        j = level;
        while (j < self.level) : (j += 1) update[j].levels[j].span += 1;

        node.backward = if (update[0] == self.header) null else update[0];
        if (node.levels[0].forward) |f| f.backward = node else self.tail = node;
        self.len += 1;
        return node;
    }

    fn unlink(self: *SkipList, x: *Node, update: *[max_level]*Node) void {
        var i: usize = 0;
        while (i < self.level) : (i += 1) {
            if (update[i].levels[i].forward == x) {
                update[i].levels[i].span += x.levels[i].span;
                update[i].levels[i].span -= 1;
                update[i].levels[i].forward = x.levels[i].forward;
            } else {
                update[i].levels[i].span -= 1;
            }
        }
        if (x.levels[0].forward) |f| f.backward = x.backward else self.tail = x.backward;
        while (self.level > 1 and self.header.levels[self.level - 1].forward == null) self.level -= 1;
        self.len -= 1;
    }

    fn findUpdate(self: *SkipList, score: f64, member: []const u8, update: *[max_level]*Node) ?*Node {
        var x = self.header;
        var i: usize = self.level;
        while (i > 0) {
            i -= 1;
            while (x.levels[i].forward) |f| {
                if (!lessThan(f.score, f.member, score, member)) break;
                x = f;
            }
            update[i] = x;
        }
        const candidate = x.levels[0].forward orelse return null;
        if (candidate.score == score and std.mem.eql(u8, candidate.member, member)) return candidate;
        return null;
    }

    /// Removes the node with this exact score and member and frees it.
    /// Returns false when no such node exists.
    pub fn delete(self: *SkipList, gpa: Allocator, score: f64, member: []const u8) bool {
        var update: [max_level]*Node = undefined;
        const x = self.findUpdate(score, member, &update) orelse return false;
        self.unlink(x, &update);
        destroyNode(gpa, x);
        return true;
    }

    /// Changes the score of an existing element. When the node stays in
    /// order it is updated in place; otherwise it is relinked while keeping
    /// the same member allocation. Returns the node now holding the member.
    pub fn updateScore(self: *SkipList, gpa: Allocator, cur_score: f64, member: []const u8, new_score: f64) Allocator.Error!*Node {
        var update: [max_level]*Node = undefined;
        const x = self.findUpdate(cur_score, member, &update) orelse unreachable;
        const prev_ok = if (x.backward) |b| b.score < new_score else true;
        const next_ok = if (x.levels[0].forward) |f| f.score > new_score else true;
        if (prev_ok and next_ok) {
            x.score = new_score;
            return x;
        }
        self.unlink(x, &update);
        const owned = x.member;
        x.member = &.{};
        destroyNode(gpa, x);
        return self.insert(gpa, new_score, owned);
    }

    /// 1-based rank of the element, or 0 when it is not present.
    pub fn rank(self: *const SkipList, score: f64, member: []const u8) usize {
        var r: usize = 0;
        var x = self.header;
        var i: usize = self.level;
        while (i > 0) {
            i -= 1;
            while (x.levels[i].forward) |f| {
                const before_or_eq = lessThan(f.score, f.member, score, member) or
                    (f.score == score and std.mem.eql(u8, f.member, member));
                if (!before_or_eq) break;
                r += x.levels[i].span;
                x = f;
            }
            if (x != self.header and x.score == score and std.mem.eql(u8, x.member, member)) return r;
        }
        return 0;
    }

    /// Node at 1-based rank, or null when out of range.
    pub fn byRank(self: *const SkipList, r: usize) ?*Node {
        if (r == 0 or r > self.len) return null;
        var traversed: usize = 0;
        var x = self.header;
        var i: usize = self.level;
        while (i > 0) {
            i -= 1;
            while (x.levels[i].forward) |f| {
                if (traversed + x.levels[i].span > r) break;
                traversed += x.levels[i].span;
                x = f;
            }
            if (traversed == r) return x;
        }
        return null;
    }

    pub fn first(self: *const SkipList) ?*Node {
        return self.header.levels[0].forward;
    }

    pub fn last(self: *const SkipList) ?*Node {
        return self.tail;
    }

    fn intersectsScore(self: *const SkipList, range: ScoreRange) bool {
        if (range.isEmpty()) return false;
        const t = self.tail orelse return false;
        if (!range.aboveMin(t.score)) return false;
        const h = self.first() orelse return false;
        return range.belowMax(h.score);
    }

    /// First node whose score is inside `range`.
    pub fn firstInScoreRange(self: *const SkipList, range: ScoreRange) ?*Node {
        if (!self.intersectsScore(range)) return null;
        var x = self.header;
        var i: usize = self.level;
        while (i > 0) {
            i -= 1;
            while (x.levels[i].forward) |f| {
                if (range.aboveMin(f.score)) break;
                x = f;
            }
        }
        const n = x.levels[0].forward orelse return null;
        return if (range.belowMax(n.score)) n else null;
    }

    /// Last node whose score is inside `range`.
    pub fn lastInScoreRange(self: *const SkipList, range: ScoreRange) ?*Node {
        if (!self.intersectsScore(range)) return null;
        var x = self.header;
        var i: usize = self.level;
        while (i > 0) {
            i -= 1;
            while (x.levels[i].forward) |f| {
                if (!range.belowMax(f.score)) break;
                x = f;
            }
        }
        if (x == self.header) return null;
        return if (range.aboveMin(x.score)) x else null;
    }

    fn intersectsLex(self: *const SkipList, range: LexRange) bool {
        if (range.isEmpty()) return false;
        const t = self.tail orelse return false;
        if (!range.aboveMin(t.member)) return false;
        const h = self.first() orelse return false;
        return range.belowMax(h.member);
    }

    /// First node whose member is inside the lexicographic `range`.
    /// Only meaningful when all scores are equal, as Redis documents.
    pub fn firstInLexRange(self: *const SkipList, range: LexRange) ?*Node {
        if (!self.intersectsLex(range)) return null;
        var x = self.header;
        var i: usize = self.level;
        while (i > 0) {
            i -= 1;
            while (x.levels[i].forward) |f| {
                if (range.aboveMin(f.member)) break;
                x = f;
            }
        }
        const n = x.levels[0].forward orelse return null;
        return if (range.belowMax(n.member)) n else null;
    }

    pub fn lastInLexRange(self: *const SkipList, range: LexRange) ?*Node {
        if (!self.intersectsLex(range)) return null;
        var x = self.header;
        var i: usize = self.level;
        while (i > 0) {
            i -= 1;
            while (x.levels[i].forward) |f| {
                if (!range.belowMax(f.member)) break;
                x = f;
            }
        }
        if (x == self.header) return null;
        return if (range.aboveMin(x.member)) x else null;
    }

    /// Verifies structural invariants. Used by tests.
    pub fn checkInvariants(self: *const SkipList) !void {
        var count: usize = 0;
        var prev: ?*Node = null;
        var x = self.first();
        while (x) |n| : (x = n.next()) {
            count += 1;
            if (n.backward != prev) return error.BrokenBackward;
            if (prev) |p| {
                if (!lessThan(p.score, p.member, n.score, n.member)) return error.OutOfOrder;
            }
            if (self.rank(n.score, n.member) != count) return error.BadRank;
            prev = n;
        }
        if (count != self.len) return error.BadLength;
        if (self.tail != prev) return error.BadTail;
    }
};

const testing = std.testing;

fn insertStr(sl: *SkipList, score: f64, member: []const u8) !void {
    _ = try sl.insert(testing.allocator, score, try testing.allocator.dupe(u8, member));
}

test "insert keeps order and ranks" {
    var sl = try SkipList.init(testing.allocator, 42);
    defer sl.deinit(testing.allocator);
    try insertStr(&sl, 3, "c");
    try insertStr(&sl, 1, "a");
    try insertStr(&sl, 2, "b");
    try insertStr(&sl, 2, "a2");
    try sl.checkInvariants();
    try testing.expectEqual(@as(usize, 4), sl.len);
    try testing.expectEqualStrings("a", sl.byRank(1).?.member);
    try testing.expectEqualStrings("a2", sl.byRank(2).?.member);
    try testing.expectEqualStrings("b", sl.byRank(3).?.member);
    try testing.expectEqualStrings("c", sl.byRank(4).?.member);
    try testing.expect(sl.byRank(5) == null);
    try testing.expectEqual(@as(usize, 3), sl.rank(2, "b"));
    try testing.expectEqual(@as(usize, 0), sl.rank(2, "zz"));
}

test "delete and update score" {
    const gpa = testing.allocator;
    var sl = try SkipList.init(gpa, 7);
    defer sl.deinit(gpa);
    var buf: [16]u8 = undefined;
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        const m = std.fmt.bufPrint(&buf, "m{d}", .{i}) catch unreachable;
        try insertStr(&sl, @floatFromInt(i), m);
    }
    try sl.checkInvariants();
    try testing.expect(sl.delete(gpa, 10, "m10"));
    try testing.expect(!sl.delete(gpa, 10, "m10"));
    try testing.expect(!sl.delete(gpa, 11, "m12"));
    _ = try sl.updateScore(gpa, 0, "m0", 1000);
    _ = try sl.updateScore(gpa, 50, "m50", 50.5);
    try sl.checkInvariants();
    try testing.expectEqualStrings("m0", sl.last().?.member);
    try testing.expectEqualStrings("m1", sl.first().?.member);
    try testing.expectEqual(@as(usize, 199), sl.len);
}

test "score and lex ranges" {
    const gpa = testing.allocator;
    var sl = try SkipList.init(gpa, 1);
    defer sl.deinit(gpa);
    for ([_][]const u8{ "a", "b", "c", "d", "e" }, 0..) |m, i| try insertStr(&sl, @floatFromInt(i), m);
    try testing.expectEqualStrings("b", sl.firstInScoreRange(.{ .min = 1, .max = 3 }).?.member);
    try testing.expectEqualStrings("c", sl.firstInScoreRange(.{ .min = 1, .max = 3, .min_ex = true }).?.member);
    try testing.expectEqualStrings("d", sl.lastInScoreRange(.{ .min = 1, .max = 3 }).?.member);
    try testing.expectEqualStrings("c", sl.lastInScoreRange(.{ .min = 1, .max = 3, .max_ex = true }).?.member);
    try testing.expect(sl.firstInScoreRange(.{ .min = 10, .max = 20 }) == null);
    try testing.expect(sl.firstInScoreRange(.{ .min = 2, .max = 2, .min_ex = true }) == null);
    try testing.expect(sl.firstInScoreRange(.{ .min = 1.5, .max = 1.7 }) == null);

    var same = try SkipList.init(gpa, 2);
    defer same.deinit(gpa);
    for ([_][]const u8{ "apple", "banana", "cherry", "date" }) |m| {
        _ = try same.insert(gpa, 0, try gpa.dupe(u8, m));
    }
    const r: LexRange = .{ .min = LexBound.parse("[b").?, .max = LexBound.parse("(d").? };
    try testing.expectEqualStrings("banana", same.firstInLexRange(r).?.member);
    try testing.expectEqualStrings("cherry", same.lastInLexRange(r).?.member);
    const all: LexRange = .{ .min = .neg_inf, .max = .pos_inf };
    try testing.expectEqualStrings("apple", same.firstInLexRange(all).?.member);
    try testing.expectEqualStrings("date", same.lastInLexRange(all).?.member);
    try testing.expect((LexRange{ .min = .{ .exclusive = "a" }, .max = .{ .inclusive = "a" } }).isEmpty());
    try testing.expect(LexBound.parse("x") == null);
    try testing.expect(LexBound.parse("-x") == null);
}

test "randomized operations agree with a sorted reference" {
    const gpa = testing.allocator;
    var sl = try SkipList.init(gpa, 99);
    defer sl.deinit(gpa);
    var reference = std.StringHashMap(f64).init(gpa);
    defer {
        var it = reference.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        reference.deinit();
    }
    var prng = std.Random.DefaultPrng.init(1234);
    const rnd = prng.random();
    var step: usize = 0;
    while (step < 3000) : (step += 1) {
        var buf: [16]u8 = undefined;
        const m = std.fmt.bufPrint(&buf, "k{d}", .{rnd.uintLessThan(u32, 300)}) catch unreachable;
        const score: f64 = @floatFromInt(rnd.uintLessThan(u32, 50));
        if (reference.get(m)) |old| {
            if (rnd.boolean()) {
                try testing.expect(sl.delete(gpa, old, m));
                const kv = reference.fetchRemove(m).?;
                gpa.free(kv.key);
            } else {
                _ = try sl.updateScore(gpa, old, m, score);
                reference.getPtr(m).?.* = score;
            }
        } else {
            _ = try sl.insert(gpa, score, try gpa.dupe(u8, m));
            try reference.put(try gpa.dupe(u8, m), score);
        }
    }
    try sl.checkInvariants();
    try testing.expectEqual(reference.count(), sl.len);
}
