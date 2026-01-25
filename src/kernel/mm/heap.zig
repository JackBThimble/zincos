const std = @import("std");
const pmm = @import("pmm.zig");
const vm = @import("vmm.zig");

pub const Heap = struct {
    base: u64,
    size: u64,
    cur: u64,
    mapped_end: u64,

    mapper: *vm.Mapper,

    pub fn init(mapper: *vm.Mapper, base: u64, size: u64) Heap {
        std.debug.assert((base & (pmm.PAGE_SIZE - 1)) == 0);
        std.debug.assert((size & (pmm.PAGE_SIZE - 1)) == 0);

        return .{
            .base = base,
            .size = size,
            .cur = base,
            .mapped_end = base,
            .mapper = mapper,
        };
    }

    pub fn alloc(self: *Heap, size: usize, alignment: usize) ?[*]u8 {
        const a = @as(u64, @intCast(@max(alignment, 16)));
        const p = alignUp(self.cur, a);
        const end = std.math.add(u64, p, @as(u64, @intCast(size))) catch return null;

        if (end > self.base + self.size) return null;

        while (self.mapped_end < end) : (self.mapped_end += pmm.PAGE_SIZE) {
            const frame = self.mapper.fa.allocFrame() orelse return null;

            var flags: u64 = 0;
            flags |= vm.PTE_PRESENT;
            flags |= vm.PTE_WRITABLE;
            flags |= vm.PTE_NX;

            self.mapper.map4k(self.mapped_end, frame, flags);
        }

        self.cur = end;
        return @ptrFromInt(@as(usize, @intCast(p)));
    }
};

fn alignUp(x: u64, a: u64) u64 {
    return (x + a - 1) & ~(a - 1);
}
