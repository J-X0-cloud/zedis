//! zedis: a Redis-protocol compatible in-memory data server.

pub const sys = @import("sys.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
