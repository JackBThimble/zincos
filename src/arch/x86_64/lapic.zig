const msr = @import("msr.zig");
const serial = @import("serial.zig");

pub const TIMER_VECTOR: u8 = 32;
pub const SPURIOUS_VECTOR: u8 = 0xff;

const IA32_APIC_BASE_MSR = 0x1b;
const APIC_ENABLE = 1 << 11;

/// Default LAPIC physical base address (can be relocated via MSR)
pub const LAPIC_BASE: u64 = 0xfee0_0000;

const REG_ID = 0x020;
const REG_EOI = 0x0b0;
const REG_SVR = 0x0f0;

const REG_LVT_TIMER = 0x320;
const REG_TINITCNT = 0x380;
const REG_TCCNT = 0x390; // Timer current count
const REG_TDIV = 0x3e0;

const LVT_MASKED: u32 = 1 << 16;
const LVT_PERIODIC: u32 = 1 << 17;

/// Virtual address of LAPIC registers (set after MMIO mapping)
var lapic_virt: usize = LAPIC_BASE; // Default to identity-mapped for early boot

inline fn read(reg: usize) u32 {
    return @as(*volatile u32, @ptrFromInt(lapic_virt + reg)).*;
}

inline fn write(reg: usize, val: u32) void {
    @as(*volatile u32, @ptrFromInt(lapic_virt + reg)).* = val;
}

// ------------------------------
// Init LAPIC
// ------------------------------
/// Initialize the LAPIC. Must be called AFTER mmio_init() has mapped the LAPIC region.
pub fn init() void {
    // Enable LAPIC via MSR
    const base = msr.rdmsr(IA32_APIC_BASE_MSR);
    msr.wrmsr(IA32_APIC_BASE_MSR, base | APIC_ENABLE);

    // Use identity-mapped virtual address (same as physical for LAPIC)
    lapic_virt = @intCast(base & 0xffff_f000);

    write(REG_SVR, @as(u32, SPURIOUS_VECTOR) | 0x100);
}

// ----------------------------
// CPU ID
// ----------------------------
pub fn id() u32 {
    return read(REG_ID) >> 24;
}

// ---------------------------
// EOI
// ---------------------------
pub fn eoi() void {
    write(REG_EOI, 0);
}

// ---------------------------
// Timer (periodic for now)
// ---------------------------
pub fn timer_init_periodic(initial_count: u32) void {
    write(REG_TDIV, 0x3);

    // initial count (tune later)
    write(REG_LVT_TIMER, @as(u32, TIMER_VECTOR) | LVT_PERIODIC);

    write(REG_TINITCNT, initial_count);
}

// -------------------------------------
// One-shot timer (for tickless later)
// -------------------------------------
pub fn timer_set_oneshot(initial_count: u32) void {
    write(REG_TDIV, 0x3);
    write(REG_LVT_TIMER, @as(u32, TIMER_VECTOR));
    write(REG_TINITCNT, initial_count);
}

pub fn timer_mask(mask: bool) void {
    var v = read(REG_LVT_TIMER);
    if (mask) v |= LVT_MASKED else v &= ~LVT_MASKED;
    write(REG_LVT_TIMER, v);
}

// ------------------------------------
// IPI / SMP Support
// ------------------------------------
const REG_ICR_LOW = 0x300;
const REG_ICR_HIGH = 0x310;

// ICR delivery modes
const ICR_INIT: u32 = 0x500;
const ICR_STARTUP: u32 = 0x600;
const ICR_LEVEL_ASSERT: u32 = 0x4000;
const ICR_LEVEL_DEASSERT: u32 = 0x0000;
const ICR_TRIGGER_LEVEL: u32 = 0x8000;

/// Wait for ICR to be ready (delivery status bit clear)
fn icrWait() void {
    while ((read(REG_ICR_LOW) & (1 << 12)) != 0) {
        asm volatile ("pause");
    }
}

/// Send a generic IPI
pub fn sendIpi(apic_id: u32, vector: u8) void {
    icrWait();
    write(REG_ICR_HIGH, apic_id << 24);
    write(REG_ICR_LOW, vector);
}

/// Send INIT IPI to target AP
pub fn sendInit(apic_id: u32) void {
    icrWait();
    write(REG_ICR_HIGH, apic_id << 24);
    // INIT, level triggered, assert
    write(REG_ICR_LOW, ICR_INIT | ICR_LEVEL_ASSERT | ICR_TRIGGER_LEVEL);

    icrWait();

    // INIT, level triggered, deassert
    write(REG_ICR_HIGH, apic_id << 24);
    write(REG_ICR_LOW, ICR_INIT | ICR_LEVEL_DEASSERT | ICR_TRIGGER_LEVEL);

    icrWait();
}

/// Send Startup IPI (SIPI) to target AP with vector (physical page number of trampoline)
pub fn sendStartup(apic_id: u32, vector: u8) void {
    icrWait();
    write(REG_ICR_HIGH, apic_id << 24);
    write(REG_ICR_LOW, ICR_STARTUP | @as(u32, vector));
    icrWait();
}

// ------------------------------------
// Delay Functions
// ------------------------------------
const tsc = @import("tsc.zig");

/// TSC ticks per microsecond (calibrated at boot)
var tsc_ticks_per_us: u64 = 2000; // Default guess ~2GHz, will be calibrated

/// Calibrate TSC frequency using LAPIC timer and known PIT frequency
/// Call this after LAPIC is initialized
pub fn calibrateTsc() void {
    // Use LAPIC timer with divide-by-16 and a known count
    // This gives us a rough calibration without needing PIT
    // For now, use a simple busy-loop calibration approach

    // Set divider to 16
    write(REG_TDIV, 0x3);

    // Set initial count to max
    write(REG_TINITCNT, 0xFFFFFFFF);

    // Read TSC start
    const tsc_start = tsc.rdtsc();

    // Wait for LAPIC timer to count down some amount
    // Read current count register
    const count_start = read(REG_TCCNT);

    // Busy wait for ~10ms worth of LAPIC ticks (rough estimate)
    // LAPIC timer typically runs at bus frequency / divider
    var dummy: u32 = 0;
    for (0..1000000) |_| {
        dummy +%= 1;
        asm volatile ("" ::: "memory");
    }

    const count_end = read(REG_TCCNT);
    const tsc_end = tsc.rdtsc();

    const lapic_ticks = count_start - count_end;
    const tsc_ticks = tsc_end - tsc_start;

    // Rough calibration: assume ~100MHz bus, divide by 16 = ~6.25MHz LAPIC timer
    // This is very approximate - proper calibration would use PIT or HPET
    if (lapic_ticks > 0 and tsc_ticks > lapic_ticks) {
        // tsc_ticks / lapic_ticks gives ratio
        // If LAPIC runs at ~6.25MHz, each LAPIC tick is 160ns
        // tsc_ticks_per_us = tsc_ticks * 1000000 / (lapic_ticks * 160)
        // Simplified: just use the ratio and assume ~1GHz TSC as baseline
        tsc_ticks_per_us = tsc_ticks / 1000; // Very rough
    }

    // Clamp to reasonable range (500MHz - 5GHz)
    if (tsc_ticks_per_us < 500) tsc_ticks_per_us = 500;
    if (tsc_ticks_per_us > 5000) tsc_ticks_per_us = 5000;
}

/// Microsecond delay using TSC
pub fn udelay(us: u32) void {
    const start = tsc.rdtsc();
    const wait_ticks = @as(u64, us) * tsc_ticks_per_us;
    while (tsc.rdtsc() - start < wait_ticks) {
        asm volatile ("pause");
    }
}

// ------------------------------------
// CPU Enumeration (temporary hardcoded)
// ------------------------------------
/// Enumerate APIC IDs - TODO: Replace with ACPI MADT parsing
/// For now, return a fixed list for testing (typical QEMU setup)
pub fn enumerate_apic_ids() []const u32 {
    // QEMU typically assigns sequential APIC IDs starting from 0
    // Hardcode 4 CPUs for testing - adjust based on your QEMU -smp setting
    const ids = [_]u32{ 0, 1, 2, 3 };
    return &ids;
}
