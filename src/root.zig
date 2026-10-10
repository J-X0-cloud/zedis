//! zedis: a Redis-protocol compatible in-memory data server.

pub const sys = @import("sys.zig");
pub const num = @import("num.zig");
pub const resp = @import("resp.zig");
pub const glob = @import("glob.zig");
pub const List = @import("ds/list.zig").List;
pub const skiplist = @import("ds/skiplist.zig");
pub const zset = @import("ds/zset.zig");
pub const value = @import("value.zig");
pub const db = @import("db.zig");
pub const aof = @import("aof.zig");
pub const Config = @import("server/config.zig").Config;
pub const Client = @import("server/client.zig").Client;
pub const TrackingAllocator = @import("server/tracking_allocator.zig").TrackingAllocator;
pub const log = @import("server/log.zig");
pub const Server = @import("server/server.zig").Server;
pub const commands = @import("commands/table.zig");
pub const client = @import("client.zig");
test {
    _ = @import("server/config.zig");
    _ = @import("server/client.zig");
    _ = @import("server/server.zig");
    _ = @import("commands/table.zig");
}

test {
    @import("std").testing.refAllDecls(@This());
}
