const apic = @import("../interrupt/apic.zig");
const manager = @import("manager.zig");
const percpu = @import("../cpu/percpu.zig");
const trampoline = @import("trampoline.zig");
const idle = @import("idle.zig");
const log = @import("shared").log;
const idt = @import("../interrupt/idt.zig");

extern fn kernel_ap_scheduler_start() callconv(.c) void;

pub export fn apEntry(lapic_ptr: usize, cpu_mgr_ptr: usize, cpu_ptr: usize) callconv(.c) noreturn {
    const mb = trampoline.mailbox();
    if (lapic_ptr == 0 or cpu_mgr_ptr == 0 or cpu_ptr == 0) {
        mb.err = trampoline.Error.bad_args;
        mb.stage = 0xee;
        while (true) asm volatile ("hlt");
    }

    const lapic: *apic.LocalApic = @ptrFromInt(lapic_ptr);
    const cpu_mgr: *manager.CpuManager = @ptrFromInt(cpu_mgr_ptr);
    const cpu: *percpu.PerCpu = @ptrFromInt(cpu_ptr);

    percpu.setGsBase(cpu);
    mb.stage = trampoline.Stage.gs_base_set;

    // Load this CPU's GDT/TSS
    cpu.gdt.load();
    cpu.gdt.loadTss();
    mb.stage = trampoline.Stage.gdt_loaded;

    // Enable local APIC
    lapic.enable();
    mb.stage = trampoline.Stage.lapic_enabled;

    // Load IDT
    idt.load();
    kernel_ap_scheduler_start();

    // Setup syscalls
    @import("../syscall.zig").init();

    // AP reached kernel entry with resolved per-CPU identity.
    cpu_mgr.markOnline(cpu);
    mb.stage = trampoline.Stage.marked_online;
    asm volatile ("sti" ::: .{ .memory = true });
    log.info("AP online: cpu_id={} apic_id={}", .{ cpu.cpu_id, cpu.apic_id });

    mb.stage = trampoline.Stage.idle;

    idle.run();
}
