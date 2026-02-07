pub const serial = @import("serial.zig");
pub const builtin = @import("builtin");
pub const vmm = @import("mmu/mapper.zig");
pub const smp = @import("smp/mod.zig");
pub const percpu = @import("cpu/percpu.zig");

pub fn rdtsc() u64 {
    var low: u32 = undefined;
    var high: u32 = undefined;

    asm volatile (
        \\lfence
        \\rdtsc
        : [low] "={eax}" (low),
          [high] "={eax}" (high),
        :
        : .{ .memory = true });
    return (@as(u64, high) << 32) | low;
}
