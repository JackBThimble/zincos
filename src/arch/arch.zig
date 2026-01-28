const builtin = @import("builtin");
const common = @import("common");
const vmm = @import("mm").vmm;

pub const serial = @import("serial.zig");
pub const mm = @import("mem.zig");

pub const Impl = switch (builtin.cpu.arch) {
    .x86_64 => @import("x86_64/arch_impl.zig"),
    .aarch64 => @import("aarch64/arch_impl.zig"),
    else => @compileError("Unsupported architecture"),
};

// ---- CPU ----
/// Gets the LAPIC id of the current cpu
pub fn cpu_id() usize {
    return Impl.cpu_id();
}

/// Initializes bootstrap processor (early init: GDT, IDT, etc.)
/// Does NOT initialize interrupt controllers - call mmio_init() for that.
pub fn cpu_init_bsp() void {
    return Impl.cpu_init_bsp();
}

/// Map architecture-specific MMIO regions and initialize hardware.
/// x86_64: LAPIC, IOAPIC, HPET
/// AArch64: GIC, timers
/// Must be called after creating the Mapper.
pub fn mmio_init(mapper: vmm.Mapper) void {
    Impl.mmio_init(mapper);
}

/// Initializes single AP
/// x86_64 - IDT, GDT, PIC, per-cpu stack, etc.
pub fn cpu_init_ap(stack_top: usize) void {
    return Impl.cpu_init_ap(stack_top);
}

// ---- Interrupts ----
/// Enable interrupts
pub fn enable_interrupts() void {
    Impl.enable_interrupts();
}

/// Disable interrupts
pub fn disable_interrupts() void {
    Impl.disable_interrupts();
}

// ---- SMP ----
/// Sets the AP entry point for SMP bring-up
pub fn smp_set_ap_entry(entry: common.ApEntryFn) void {
    Impl.smp_set_ap_entry(entry);
}

/// Gets the AP entry point  for SMP bring-up
pub fn smp_get_ap_entry() common.ApEntryFn {
    return Impl.smp_get_ap_entry();
}

/// Initialize symmetrical multiprocessing
/// Brings up APs and parks them.
pub fn smp_init() void {
    Impl.smp_init();
}

/// Get number of APs currently online and parked
pub fn smp_ap_count() u32 {
    return Impl.smp_ap_count();
}

/// Release all parked APs to enter scheduler
pub fn smp_release_aps() void {
    Impl.smp_release_aps();
}

/// Send IPI to specific CPU
pub fn smp_send_ipi(cpu: usize, vector: u8) void {
    Impl.smp_send_ipi(cpu, vector);
}

/// Initialize timer (for scheduling)
pub fn timer_init() void {
    Impl.timer_init();
}

/// Single "halt" instruction
pub fn halt() void {
    Impl.halt();
}

/// Infinite halt loop
pub fn halt_catch_fire() noreturn {
    Impl.halt_catch_fire();
}

/// Dump cpu registers to log
pub fn dumpCpuState() void {
    Impl.dumpCpuState();
}

/// Get current timestamp counter value
pub fn now() usize {
    return Impl.now();
}

pub fn set_deadline(delta_ticks: u64) void {
    Impl.set_deadline(delta_ticks);
}
