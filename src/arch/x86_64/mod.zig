pub const serial = @import("serial.zig");
pub const builtin = @import("builtin");
pub const vmm = @import("mmu/mapper.zig");
pub const smp = @import("smp/mod.zig");
pub const percpu = @import("cpu/percpu.zig");
pub const sched = @import("sched.zig");
pub const idt = @import("interrupt/idt.zig");
pub const timer = @import("interrupt/timer.zig");
pub const syscall = @import("syscall.zig");
pub const ioapic = @import("interrupt/ioapic.zig");

comptime {
    _ = idt.interrupt_dispatch;
    _ = idt.sched_check_preempt;
}

var hhdm_base: u64 = 0;

pub fn initHhdm(base: u64) void {
    hhdm_base = base;
}

pub inline fn physToVirt(phys: u64) u64 {
    return hhdm_base + phys;
}

pub inline fn virtToPhys(virt: u64) u64 {
    return virt - hhdm_base;
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
