//! Number parsing and formatting with Redis-compatible edge cases.
//!
//! Redis is strict about what counts as an integer ("01", "+1", " 1" and
//! "-0" are all rejected) and has two distinct double formats: a shortest
//! round-trip form used for scores and RESP3 doubles, and a "human" form
//! with 17 fractional digits computed in extended precision used by
//! INCRBYFLOAT and HINCRBYFLOAT. Both are reproduced here byte for byte.

const std = @import("std");

/// Maximum characters needed by `formatDouble`.
pub const max_double_chars = 32;

/// Maximum characters needed by `formatHuman`.
pub const max_human_chars = 5200;

/// Strict signed 64-bit integer parser matching Redis' `string2ll`.
pub fn parseI64(s: []const u8) ?i64 {
    if (s.len == 0 or s.len > 20) return null;
    if (s.len == 1 and s[0] == '0') return 0;
    var i: usize = 0;
    var negative = false;
    if (s[0] == '-') {
        negative = true;
        i = 1;
        if (s.len == 1) return null;
    }
    // First digit must be 1-9: no leading zeros, no "-0".
    if (s[i] < '1' or s[i] > '9') return null;
    var v: u64 = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c < '0' or c > '9') return null;
        v = std.math.mul(u64, v, 10) catch return null;
        v = std.math.add(u64, v, c - '0') catch return null;
    }
    if (negative) {
        if (v > @as(u64, std.math.maxInt(i64)) + 1) return null;
        if (v == @as(u64, std.math.maxInt(i64)) + 1) return std.math.minInt(i64);
        return -@as(i64, @intCast(v));
    }
    if (v > std.math.maxInt(i64)) return null;
    return @intCast(v);
}

/// Parses a double the way Redis' `string2d` does: no surrounding
/// whitespace, no trailing garbage, and NaN is rejected.
pub fn parseF64(s: []const u8) ?f64 {
    if (s.len == 0 or s.len > 5120) return null;
    if (std.ascii.isWhitespace(s[0]) or std.ascii.isWhitespace(s[s.len - 1])) return null;
    const v = parseFloatLoose(f64, s) orelse return null;
    if (std.math.isNan(v)) return null;
    return v;
}

/// Extended precision parse used by INCRBYFLOAT, mirroring `strtold`.
pub fn parseF80(s: []const u8) ?f80 {
    if (s.len == 0 or s.len > 5120) return null;
    if (std.ascii.isWhitespace(s[0]) or std.ascii.isWhitespace(s[s.len - 1])) return null;
    const v = parseFloatLoose(f80, s) orelse return null;
    if (std.math.isNan(v)) return null;
    return v;
}

fn parseFloatLoose(comptime T: type, s: []const u8) ?T {
    // strtod accepts "inf"/"infinity" case-insensitively with an optional sign.
    var body = s;
    var neg = false;
    if (body[0] == '+' or body[0] == '-') {
        neg = body[0] == '-';
        body = body[1..];
    }
    if (std.ascii.eqlIgnoreCase(body, "inf") or std.ascii.eqlIgnoreCase(body, "infinity")) {
        return if (neg) -std.math.inf(T) else std.math.inf(T);
    }
    if (std.ascii.eqlIgnoreCase(body, "nan")) return null;
    // Underscores are a Zig literal feature, not something strtod allows.
    if (std.mem.indexOfScalar(u8, s, '_') != null) return null;
    return std.fmt.parseFloat(T, s) catch null;
}

/// Formats a double like Redis' `d2string`: integers in the safe range
/// print without a fraction, everything else uses the shortest digits
/// that round-trip, laid out with the same thresholds as `fpconv_dtoa`.
pub fn formatDouble(buf: *[max_double_chars]u8, v: f64) []const u8 {
    if (std.math.isNan(v)) return copyInto(buf, "nan");
    if (std.math.isInf(v)) return copyInto(buf, if (v < 0) "-inf" else "inf");
    if (v == 0) return copyInto(buf, if (std.math.signbit(v)) "-0" else "0");

    const limit: f64 = @floatFromInt(@divTrunc(std.math.maxInt(i64), 2));
    if (v > -limit and v < limit) {
        const as_int: i64 = @intFromFloat(v);
        if (@as(f64, @floatFromInt(as_int)) == v) {
            return std.fmt.bufPrint(buf, "{d}", .{as_int}) catch unreachable;
        }
    }

    // Obtain the shortest round-trip digits in scientific form, e.g. "-1.25e-7".
    var sci_buf: [64]u8 = undefined;
    const sci = std.fmt.bufPrint(&sci_buf, "{e}", .{v}) catch unreachable;
    var digits_buf: [32]u8 = undefined;
    var ndigits: usize = 0;
    var idx: usize = 0;
    const neg = sci[0] == '-';
    if (neg) idx = 1;
    while (idx < sci.len and sci[idx] != 'e') : (idx += 1) {
        if (sci[idx] != '.') {
            digits_buf[ndigits] = sci[idx];
            ndigits += 1;
        }
    }
    const exp10 = std.fmt.parseInt(i32, sci[idx + 1 ..], 10) catch unreachable;
    // Strip trailing zeros from the digit string (e.g. "1.0e3").
    while (ndigits > 1 and digits_buf[ndigits - 1] == '0') ndigits -= 1;
    const digits = digits_buf[0..ndigits];
    const k: i32 = exp10 - @as(i32, @intCast(ndigits)) + 1;

    var out: usize = 0;
    if (neg) {
        buf[0] = '-';
        out = 1;
    }
    out += emitDigits(digits, k, buf[out..], neg);
    return buf[0..out];
}

fn emitDigits(digits: []const u8, k: i32, dest: []u8, neg: bool) usize {
    const nd: i32 = @intCast(digits.len);
    var exp: i32 = @intCast(@abs(k + nd - 1));

    // Plain integer.
    if (k >= 0 and exp < nd + 7) {
        @memcpy(dest[0..digits.len], digits);
        const zeros: usize = @intCast(k);
        @memset(dest[digits.len..][0..zeros], '0');
        return digits.len + zeros;
    }

    // Decimal without scientific notation.
    if (k < 0 and (k > -7 or exp < 4)) {
        var offset: i32 = nd - @as(i32, @intCast(@abs(k)));
        if (offset <= 0) {
            offset = -offset;
            const off: usize = @intCast(offset);
            dest[0] = '0';
            dest[1] = '.';
            @memset(dest[2..][0..off], '0');
            @memcpy(dest[2 + off ..][0..digits.len], digits);
            return digits.len + 2 + off;
        }
        const off: usize = @intCast(offset);
        @memcpy(dest[0..off], digits[0..off]);
        dest[off] = '.';
        @memcpy(dest[off + 1 ..][0 .. digits.len - off], digits[off..]);
        return digits.len + 1;
    }

    // Scientific notation.
    const limit: usize = if (neg) 17 else 18;
    const n = @min(digits.len, limit);
    var i: usize = 0;
    dest[i] = digits[0];
    i += 1;
    if (n > 1) {
        dest[i] = '.';
        i += 1;
        @memcpy(dest[i..][0 .. n - 1], digits[1..n]);
        i += n - 1;
    }
    dest[i] = 'e';
    i += 1;
    dest[i] = if (k + nd - 1 < 0) '-' else '+';
    i += 1;
    var cent: i32 = 0;
    if (exp > 99) {
        cent = @divTrunc(exp, 100);
        dest[i] = @intCast('0' + cent);
        i += 1;
        exp -= cent * 100;
    }
    if (exp > 9) {
        const dec = @divTrunc(exp, 10);
        dest[i] = @intCast('0' + dec);
        i += 1;
        exp -= dec * 10;
    } else if (cent != 0) {
        dest[i] = '0';
        i += 1;
    }
    dest[i] = @intCast('0' + exp);
    i += 1;
    return i;
}

/// The "human" long double format used by INCRBYFLOAT: `%.17Lf` with
/// trailing zeros (and a dangling dot) removed, and "-0" folded to "0".
pub fn formatHuman(buf: []u8, v: f80) []const u8 {
    if (std.math.isNan(v)) return copyInto(buf, "nan");
    if (std.math.isInf(v)) return copyInto(buf, if (v < 0) "-inf" else "inf");
    var s = std.fmt.bufPrint(buf, "{d:.17}", .{v}) catch return copyInto(buf, "nan");
    if (std.mem.indexOfScalar(u8, s, '.') != null) {
        var l = s.len;
        while (s[l - 1] == '0') l -= 1;
        if (s[l - 1] == '.') l -= 1;
        s = s[0..l];
    }
    if (std.mem.eql(u8, s, "-0")) return copyInto(buf, "0");
    return s;
}

fn copyInto(buf: []u8, s: []const u8) []const u8 {
    @memcpy(buf[0..s.len], s);
    return buf[0..s.len];
}

/// Formats an integer into a caller-provided buffer.
pub fn formatI64(buf: *[24]u8, v: i64) []const u8 {
    return std.fmt.bufPrint(buf, "{d}", .{v}) catch unreachable;
}

/// Clamps Redis-style signed indexes (negative counts from the end) into
/// an inclusive [start, end] range over a sequence of `len` items.
/// Returns null when the range is empty.
pub fn normalizeRange(start_in: i64, end_in: i64, len: usize) ?struct { start: usize, end: usize } {
    const l: i64 = @intCast(len);
    var start = start_in;
    var end = end_in;
    if (start < 0) start += l;
    if (end < 0) end += l;
    if (start < 0) start = 0;
    if (start > end or start >= l) return null;
    if (end >= l) end = l - 1;
    return .{ .start = @intCast(start), .end = @intCast(end) };
}

const testing = std.testing;

test "parseI64 accepts canonical integers only" {
    try testing.expectEqual(@as(?i64, 0), parseI64("0"));
    try testing.expectEqual(@as(?i64, 42), parseI64("42"));
    try testing.expectEqual(@as(?i64, -42), parseI64("-42"));
    try testing.expectEqual(@as(?i64, std.math.maxInt(i64)), parseI64("9223372036854775807"));
    try testing.expectEqual(@as(?i64, std.math.minInt(i64)), parseI64("-9223372036854775808"));
    try testing.expectEqual(@as(?i64, null), parseI64("9223372036854775808"));
    try testing.expectEqual(@as(?i64, null), parseI64("-9223372036854775809"));
    try testing.expectEqual(@as(?i64, null), parseI64("01"));
    try testing.expectEqual(@as(?i64, null), parseI64("-0"));
    try testing.expectEqual(@as(?i64, null), parseI64("+1"));
    try testing.expectEqual(@as(?i64, null), parseI64(" 1"));
    try testing.expectEqual(@as(?i64, null), parseI64("1 "));
    try testing.expectEqual(@as(?i64, null), parseI64(""));
    try testing.expectEqual(@as(?i64, null), parseI64("-"));
    try testing.expectEqual(@as(?i64, null), parseI64("1.0"));
    try testing.expectEqual(@as(?i64, null), parseI64("99999999999999999999999"));
}

test "parseF64 matches strtod rules" {
    try testing.expectEqual(@as(?f64, 1.5), parseF64("1.5"));
    try testing.expectEqual(@as(?f64, 0.5), parseF64(".5"));
    try testing.expectEqual(@as(?f64, 5), parseF64("5."));
    try testing.expectEqual(@as(?f64, 1e10), parseF64("1e10"));
    try testing.expectEqual(@as(?f64, -3), parseF64("-3"));
    try testing.expectEqual(@as(?f64, 3), parseF64("+3"));
    try testing.expect(std.math.isPositiveInf(parseF64("inf").?));
    try testing.expect(std.math.isPositiveInf(parseF64("+inf").?));
    try testing.expect(std.math.isNegativeInf(parseF64("-inf").?));
    try testing.expect(std.math.isNegativeInf(parseF64("-Infinity").?));
    try testing.expectEqual(@as(?f64, null), parseF64("nan"));
    try testing.expectEqual(@as(?f64, null), parseF64(" 1"));
    try testing.expectEqual(@as(?f64, null), parseF64("1 "));
    try testing.expectEqual(@as(?f64, null), parseF64("1x"));
    try testing.expectEqual(@as(?f64, null), parseF64("1_000"));
    try testing.expectEqual(@as(?f64, null), parseF64(""));
}

fn expectDouble(expected: []const u8, v: f64) !void {
    var buf: [max_double_chars]u8 = undefined;
    try testing.expectEqualStrings(expected, formatDouble(&buf, v));
}

test "formatDouble mirrors d2string and fpconv_dtoa" {
    try expectDouble("0", 0.0);
    try expectDouble("-0", -0.0);
    try expectDouble("1", 1.0);
    try expectDouble("-17", -17.0);
    try expectDouble("1.5", 1.5);
    try expectDouble("1.1", 1.1);
    try expectDouble("0.1", 0.1);
    var tenth: f64 = 0.1;
    _ = &tenth;
    try expectDouble("0.30000000000000004", tenth + 0.2);
    try expectDouble("3.14159", 3.14159);
    try expectDouble("inf", std.math.inf(f64));
    try expectDouble("-inf", -std.math.inf(f64));
    try expectDouble("1e+20", 1e20);
    try expectDouble("1.5e+300", 1.5e300);
    try expectDouble("1e-7", 1e-7);
    try expectDouble("0.000001", 1e-6);
    try expectDouble("-2.5e-10", -2.5e-10);
    // 2^62 sits just outside the integer fast path and goes through fpconv.
    try expectDouble("4611686018427388000", 4611686018427387904.0);
    try expectDouble("1000000000000000", 1e15);
    try expectDouble("123456.789", 123456.789);
}

fn expectHuman(expected: []const u8, v: f80) !void {
    var buf: [max_human_chars]u8 = undefined;
    try testing.expectEqualStrings(expected, formatHuman(&buf, v));
}

test "formatHuman trims like ld2string" {
    try expectHuman("10.5", 10.5);
    try expectHuman("3", 3.0);
    try expectHuman("0", -0.0);
    try expectHuman("-1.25", -1.25);
    // In extended precision 0.1 + 0.2 rounds to 0.3 at 17 fractional digits.
    try expectHuman("0.3", parseF80("0.1").? + parseF80("0.2").?);
    try expectHuman("5000", 5.0e3);
    try expectHuman("inf", std.math.inf(f80));
}

test "normalizeRange" {
    const r = normalizeRange(0, -1, 5).?;
    try testing.expectEqual(@as(usize, 0), r.start);
    try testing.expectEqual(@as(usize, 4), r.end);
    const r2 = normalizeRange(-100, 100, 3).?;
    try testing.expectEqual(@as(usize, 0), r2.start);
    try testing.expectEqual(@as(usize, 2), r2.end);
    try testing.expect(normalizeRange(3, 10, 3) == null);
    try testing.expect(normalizeRange(2, 1, 5) == null);
    try testing.expect(normalizeRange(0, -1, 0) == null);
    const r3 = normalizeRange(-2, -1, 5).?;
    try testing.expectEqual(@as(usize, 3), r3.start);
}
