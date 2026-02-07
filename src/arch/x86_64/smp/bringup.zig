const std = @import("std");
const apic = @import("../interrupt/apic.zig");
const percpu = @import("../cpu/percpu.zig");
const boot = @import("shared").boot;

const ap_entry = @import("ap_entry.zig");
const manager = @import("manager.zig");
const trampoline = @import("trampoline.zig");

const AP_STACK_SIZE: usize = 32 * 1024;

pub fn setupBsp(cpu_mgr: *manager.CpuManager) !void {
    const bsp = cpu_mgr.getBsp() orelse return error.NoBsp;

    bsp.gdt.setTss(&bsp.tss);
    bsp.gdt.load();
    bsp.gdt.loadTss();
    percpu.setGsBase(bsp);
    cpu_mgr.markOnline(bsp);
}

pub fn bootAps(
    lapic: *apic.LocalApic,
    cpu_mgr: *manager.CpuManager,
    allocator: std.mem.Allocator,
) !void {
    try trampoline.setup();
    const pml4 = asm volatile ("movq %%cr3, %[pt]"
        : [pt] "=r" (-> u64),
    );

    // Boot each AP
    for (0..cpu_mgr.cpu_count) |i| {
        const cpu = cpu_mgr.getCpu(@intCast(i)) orelse continue;
        if (cpu.is_bsp) continue;

        try bootOne(lapic, cpu_mgr, allocator, cpu, pml4);
    }
}

fn bootOne(
    lapic: *apic.LocalApic,
    cpu_mgr: *manager.CpuManager,
    allocator: std.mem.Allocator,
    cpu: *percpu.PerCpu,
    pml4: u64,
) !void {
    const stack = try allocator.alignedAlloc(u8, std.mem.Alignment.@"16", AP_STACK_SIZE);
    cpu.kernel_stack = @intFromPtr(stack.ptr) + stack.len;
    cpu.tss.rsp0 = cpu.kernel_stack;
    cpu.gdt.setTss(&cpu.tss);

    const mb = trampoline.mailbox();
    mb.pml4 = pml4;
    mb.stack = cpu.kernel_stack;
    mb.gs_base = @intFromPtr(&cpu.cpu_id);
    mb.lapic_ptr = @intFromPtr(lapic);
    mb.cpu_mgr_ptr = @intFromPtr(cpu_mgr);
    mb.cpu_ptr = @intFromPtr(cpu);
    mb.entry = @intFromPtr(&ap_entry.apEntry);
    mb.started = 0;

    // send INIT IPI
    lapic.sendIpi(
        @truncate(cpu.apic_id),
        0,
        .init,
        .assert,
        .level,
    );
    busyWaitMs(10);

    const vec: u8 = @truncate(trampoline.TRAMPOLINE_ADDR >> 12);
    lapic.sendIpi(
        @truncate(cpu.apic_id),
        vec,
        .sipi,
        .assert,
        .edge,
    );
    busyWaitMs(200);
    lapic.sendIpi(
        @truncate(cpu.apic_id),
        vec,
        .sipi,
        .assert,
        .edge,
    );

    // wait for ap to start (max 1 second)
    const timeout_us: u64 = 1_000_000;
    var elapsed: u64 = 0;
    while (@atomicLoad(u32, &mb.started, .acquire) == 0) {
        busyWaitUs(100);
        elapsed += 100;
        if (elapsed > timeout_us) {
            return error.ApStartupTimeout;
        }
    }
}

fn busyWaitMs(ms: u64) void {
    busyWaitUs(ms * 1000);
}

fn busyWaitUs(us: u64) void {
    const start = readTsc();
    const cycles = us * 2500; // 2.5GHz guestimate
    while (readTsc() - start < cycles) {
        std.atomic.spinLoopHint();
    }
}

fn readTsc() u64 {
    var low: u32 = undefined;
    var high: u32 = undefined;

    asm volatile ("rdtsc"
        : [low] "={eax}" (low),
          [high] "={edx}" (high),
    );
    return (@as(u64, high) << 32) | low;
}
