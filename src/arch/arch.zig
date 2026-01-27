const builtin = @import("builtin");
const common = @import("common");

pub const serial = @import("serial.zig");

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

/// Initializes bootstrap processor
/// x86_64 - IDT, GDT, PIC, LAPIC, etc.
pub fn cpu_init_bsp() void {
    return Impl.cpu_init_bsp();
}

/// Initializes single AP
/// x86_64 - IDT, GDT, PIC, per-cpu stack, etc.
pub fn cpu_init_ap() void {
    return Impl.cpu_init_ap();
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

/// SIPI for SMP
pub fn smp_send_ipi(cpu: usize) void {
    Impl.smp_send_ipi(cpu);
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
