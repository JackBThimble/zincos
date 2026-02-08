pub const serial = @import("serial.zig");
pub const builtin = @import("builtin");
pub const vmm = @import("mmu/mapper.zig");
pub const smp = @import("smp/mod.zig");
pub const percpu = @import("cpu/percpu.zig");
pub const sched = @import("sched.zig");
pub const idt = @import("interrupt/idt.zig");
pub const timer = @import("interrupt/timer.zig");

comptime {
    _ = idt.interrupt_dispatch;
    _ = idt.sched_check_preempt;
}

pub fn hcf() noreturn {
    while (true) {
        asm volatile ("hlt");
    }
}

pub fn enableInterrupts() void {
    asm volatile ("sti" ::: .{ .memory = true });
}

pub fn disableInterrupts() void {
    asm volatile ("cli");
}
pub fn rdtsc() u64 {
    var low: u32 = undefined;
    var high: u32 = undefined;

    asm volatile (
        \\lfence
        \\rdtsc
        : [low] "={eax}" (low),
          [high] "={edx}" (high),
        :
        : .{ .memory = true });
    return (@as(u64, high) << 32) | low;
}

pub fn getCpuId() usize {
    return @as(usize, asm volatile ("movl %%gs:0, %[id]"
        : [id] "=r" (-> u32),
    ));
}
