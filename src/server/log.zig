//! Minimal Redis-style logger: `pid:M dd Mon yyyy hh:mm:ss.mmm * message`.

const std = @import("std");
const sys = @import("../sys.zig");

pub const Level = enum(u8) { debug, verbose, notice, warning };

pub const Logger = struct {
    min: Level = .notice,
    /// Disables output entirely (used by tests that embed a server).
    quiet: bool = false,
    fd: sys.fd_t = 2,

    pub fn log(self: *const Logger, level: Level, comptime fmt: []const u8, args: anytype) void {
        if (self.quiet or @backingInt(level) < @backingInt(self.min)) return;
        var buf: [1024]u8 = undefined;
        const ms = sys.nowMs();
        const secs: u64 = @intCast(@divTrunc(ms, 1000));
        const es: std.time.epoch.EpochSeconds = .{ .secs = secs };
        const day = es.getEpochDay().calculateYearDay();
        const md = day.calculateMonthDay();
        const ds = es.getDaySeconds();
        const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
        const mark: u8 = switch (level) {
            .debug => '.',
            .verbose => '-',
            .notice => '*',
            .warning => '#',
        };
        const prefix = std.fmt.bufPrint(&buf, "{d}:M {d:0>2} {s} {d} {d:0>2}:{d:0>2}:{d:0>2}.{d:0>3} {c} ", .{
            sys.getPid(),
            md.day_index + 1,
            months[@backingInt(md.month) - 1],
            day.year,
            ds.getHoursIntoDay(),
            ds.getMinutesIntoHour(),
            ds.getSecondsIntoMinute(),
            @as(u64, @intCast(@mod(ms, 1000))),
            mark,
        }) catch return;
        const body = std.fmt.bufPrint(buf[prefix.len..], fmt ++ "\n", args) catch blk: {
            buf[buf.len - 1] = '\n';
            break :blk buf[prefix.len..];
        };
        sys.writeAll(self.fd, buf[0 .. prefix.len + body.len]) catch {};
    }
};
