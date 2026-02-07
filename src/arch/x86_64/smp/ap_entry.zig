const apic = @import("../interrupt/apic.zig");
const manager = @import("manager.zig");
const percpu = @import("../cpu/percpu.zig");
const log = @import("shared").log;

pub export fn apEntry(lapic_ptr: usize, cpu_mgr_ptr: usize, cpu_ptr: usize) callconv(.c) noreturn {
    const lapic: *apic.LocalApic = @ptrFromInt(lapic_ptr);
    const cpu_mgr: *manager.CpuManager = @ptrFromInt(cpu_mgr_ptr);
    const cpu: *percpu.PerCpu = @ptrFromInt(cpu_ptr);

    percpu.setGsBase(cpu);

    // Load this CPU's GDT/TSS
    cpu.gdt.load();
    cpu.gdt.loadTss();

    // Enable local APIC
    lapic.enable();

    // AP reached kernel entry with resolved per-CPU identity.
    log.info("AP online: cpu_id={} apic_id={}", .{ cpu.cpu_id, cpu.apic_id });

    // Mark CPU as online
    cpu_mgr.markOnline(cpu);

    while (true) {
        asm volatile ("hlt");
    }
}
