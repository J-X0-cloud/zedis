//! zedis-server entry point.

const std = @import("std");
const zedis = @import("zedis");

const usage =
    \\Usage: zedis-server [--option value]...
    \\
    \\Options mirror redis.conf directives, for example:
    \\  --port 6379                 TCP port (defaults to $PORT when set, else 6379)
    \\  --bind 127.0.0.1            IPv4 address to listen on
    \\  --dir .                     Working directory for the AOF
    \\  --appendonly yes|no         Enable append-only file persistence
    \\  --appendfilename NAME       AOF file name inside --dir
    \\  --appendfsync always|everysec|no
    \\  --requirepass PASSWORD      Require AUTH before other commands
    \\  --databases 16              Number of logical databases
    \\  --hz 10                     Background task frequency
    \\  --maxclients 10000
    \\  --loglevel debug|verbose|notice|warning
    \\
;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var tracker = zedis.TrackingAllocator.init(init.gpa);
    const gpa = tracker.allocator();

    // Ownership of the configuration moves to the server once it starts.
    var config: zedis.Config = .{};

    for (args[1..]) |a| {
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            zedis.sys.writeAll(1, usage) catch {};
            return;
        }
        if (std.mem.eql(u8, a, "--version") or std.mem.eql(u8, a, "-v")) {
            zedis.sys.writeAll(1, "zedis-server 0.1.0 (redis protocol 7.2 compatible subset)\n") catch {};
            return;
        }
    }

    // Platforms such as Railway and Heroku announce the port via $PORT.
    if (init.environ_map.get("PORT")) |p| {
        config.set(gpa, "port", p, true) catch {
            std.debug.print("Invalid $PORT value: {s}\n", .{p});
            std.process.exit(1);
        };
    }

    var bad: []const u8 = "";
    config.applyArgs(gpa, args[1..], &bad) catch |err| {
        std.debug.print("Bad configuration option {s}: {s}\n\n{s}", .{ bad, @errorName(err), usage });
        std.process.exit(1);
    };

    zedis.sys.ignoreSigpipe();
    const server = try zedis.Server.init(gpa, config);
    defer server.deinit();
    server.tracker = &tracker;
    server.start() catch |err| {
        server.log.log(.warning, "Failed to start: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
    try server.run();
}
