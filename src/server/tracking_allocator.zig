//! An allocator wrapper that tracks live bytes so INFO can report
//! `used_memory` without relying on a particular malloc implementation.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

pub const TrackingAllocator = struct {
    child: Allocator,
    used: usize = 0,
    peak: usize = 0,

    pub fn init(child: Allocator) TrackingAllocator {
        return .{ .child = child };
    }

    pub fn allocator(self: *TrackingAllocator) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn grow(self: *TrackingAllocator, n: usize) void {
        self.used += n;
        if (self.used > self.peak) self.peak = self.used;
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        const p = self.child.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.grow(len);
        return p;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        if (!self.child.rawResize(memory, alignment, new_len, ret_addr)) return false;
        self.used -= memory.len;
        self.grow(new_len);
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        const p = self.child.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        self.used -= memory.len;
        self.grow(new_len);
        return p;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        self.child.rawFree(memory, alignment, ret_addr);
        self.used -= memory.len;
    }
};

test "tracks live and peak bytes" {
    var t = TrackingAllocator.init(std.testing.allocator);
    const a = t.allocator();
    const buf = try a.alloc(u8, 100);
    try std.testing.expectEqual(@as(usize, 100), t.used);
    const buf2 = try a.realloc(buf, 300);
    try std.testing.expectEqual(@as(usize, 300), t.used);
    a.free(buf2);
    try std.testing.expectEqual(@as(usize, 0), t.used);
    try std.testing.expect(t.peak >= 300);
}
