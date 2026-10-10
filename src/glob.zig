//! Glob-style pattern matching used by KEYS, SCAN MATCH and PSUBSCRIBE.
//!
//! Supports the same syntax as Redis' `stringmatchlen`: `*`, `?`, character
//! classes such as `[abc]`, `[^abc]` and `[a-z]`, and backslash escapes.
//! Unlike the recursive reference implementation this matcher backtracks
//! only to the most recent `*`, which bounds the work to O(pattern * input)
//! and makes pathological patterns like `*a*a*a*a*b` cheap.

const std = @import("std");

pub fn match(pattern: []const u8, input: []const u8) bool {
    return matchImpl(pattern, input, false);
}

pub fn matchNoCase(pattern: []const u8, input: []const u8) bool {
    return matchImpl(pattern, input, true);
}

fn fold(c: u8, nocase: bool) u8 {
    return if (nocase) std.ascii.toLower(c) else c;
}

/// Matches a single input byte against the element at `pattern[p]`.
/// Returns the index just past the element, or null on mismatch.
fn matchOne(pattern: []const u8, p: usize, c: u8, nocase: bool) ?usize {
    switch (pattern[p]) {
        '?' => return p + 1,
        '[' => {
            var i = p + 1;
            var negate = false;
            if (i < pattern.len and pattern[i] == '^') {
                negate = true;
                i += 1;
            }
            var matched = false;
            while (i < pattern.len and pattern[i] != ']') {
                if (pattern[i] == '\\' and i + 1 < pattern.len) {
                    i += 1;
                    if (fold(pattern[i], nocase) == fold(c, nocase)) matched = true;
                    i += 1;
                } else if (i + 2 < pattern.len and pattern[i + 1] == '-' and pattern[i + 2] != ']') {
                    var lo = fold(pattern[i], nocase);
                    var hi = fold(pattern[i + 2], nocase);
                    if (lo > hi) std.mem.swap(u8, &lo, &hi);
                    const fc = fold(c, nocase);
                    if (fc >= lo and fc <= hi) matched = true;
                    i += 3;
                } else {
                    if (fold(pattern[i], nocase) == fold(c, nocase)) matched = true;
                    i += 1;
                }
            }
            // An unterminated class is treated as running to the end, like Redis.
            const next = if (i < pattern.len) i + 1 else i;
            if (negate) matched = !matched;
            return if (matched) next else null;
        },
        '\\' => {
            if (p + 1 < pattern.len) {
                return if (fold(pattern[p + 1], nocase) == fold(c, nocase)) p + 2 else null;
            }
            return if (c == '\\') p + 1 else null;
        },
        else => return if (fold(pattern[p], nocase) == fold(c, nocase)) p + 1 else null,
    }
}

fn matchImpl(pattern: []const u8, input: []const u8, nocase: bool) bool {
    var p: usize = 0;
    var s: usize = 0;
    var star_p: ?usize = null;
    var star_s: usize = 0;
    while (s < input.len) {
        if (p < pattern.len and pattern[p] == '*') {
            // Collapse consecutive stars.
            while (p < pattern.len and pattern[p] == '*') p += 1;
            if (p == pattern.len) return true;
            star_p = p;
            star_s = s;
            continue;
        }
        if (p < pattern.len) {
            if (matchOne(pattern, p, input[s], nocase)) |next| {
                p = next;
                s += 1;
                continue;
            }
        }
        if (star_p) |sp| {
            p = sp;
            star_s += 1;
            s = star_s;
            continue;
        }
        return false;
    }
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

/// True when the pattern contains no special characters, so callers can
/// turn a SCAN MATCH into a direct lookup.
pub fn isLiteral(pattern: []const u8) bool {
    for (pattern) |c| switch (c) {
        '*', '?', '[', '\\' => return false,
        else => {},
    };
    return true;
}

const testing = std.testing;

test "basic wildcards" {
    try testing.expect(match("*", ""));
    try testing.expect(match("*", "anything"));
    try testing.expect(match("h?llo", "hello"));
    try testing.expect(match("h?llo", "hallo"));
    try testing.expect(!match("h?llo", "hllo"));
    try testing.expect(match("h*llo", "hllo"));
    try testing.expect(match("h*llo", "heeeello"));
    try testing.expect(match("user:*:name", "user:1000:name"));
    try testing.expect(!match("user:*:name", "user:1000:email"));
    try testing.expect(match("a*b*c", "a__b__c"));
    try testing.expect(!match("a*b*c", "a__b__"));
    try testing.expect(match("", ""));
    try testing.expect(!match("", "a"));
    try testing.expect(match("**a", "bba"));
}

test "character classes" {
    try testing.expect(match("h[ae]llo", "hello"));
    try testing.expect(match("h[ae]llo", "hallo"));
    try testing.expect(!match("h[ae]llo", "hillo"));
    try testing.expect(match("h[^e]llo", "hallo"));
    try testing.expect(!match("h[^e]llo", "hello"));
    try testing.expect(match("h[a-b]llo", "hbllo"));
    try testing.expect(!match("h[a-b]llo", "hcllo"));
    try testing.expect(match("h[b-a]llo", "hallo"));
    try testing.expect(match("[\\]]", "]"));
    try testing.expect(match("x[a-]", "x-"));
}

test "escapes" {
    try testing.expect(match("h\\*llo", "h*llo"));
    try testing.expect(!match("h\\*llo", "hello"));
    try testing.expect(match("\\?", "?"));
    try testing.expect(match("a\\", "a\\"));
}

test "case insensitive" {
    try testing.expect(matchNoCase("HeLLo*", "hello world"));
    try testing.expect(matchNoCase("[A-C]x", "bX"));
    try testing.expect(!match("HELLO", "hello"));
}

test "pathological pattern stays fast" {
    const input_arr: [4096]u8 = @splat('a');
    const input: []const u8 = &input_arr;
    try testing.expect(!match("*a*a*a*a*a*a*a*a*a*a*a*a*b", input));
    try testing.expect(match("*a*a*a*a*a*a*a*a*a*a*a*a*", input));
}

test "isLiteral" {
    try testing.expect(isLiteral("plain:key"));
    try testing.expect(!isLiteral("key*"));
    try testing.expect(!isLiteral("k[ab]"));
}
