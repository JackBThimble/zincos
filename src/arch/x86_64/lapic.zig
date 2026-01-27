const msr = @import("msr.zig");
const serial = @import("serial.zig");

pub const TIMER_VECTOR: u8 = 32;
pub const SPURIOUS_VECTOR: u8 = 0xff;

const IA32_APIC_BASE_MSR = 0x1b;
const APIC_ENABLE = 1 << 11;

const LAPIC_ID = 0x020;
const LAPIC_EOI = 0x0b0;
const LAPIC_SVR = 0x0f0;

const LAPIC_LVT_TIMER = 0x320;
const LAPIC_TINITCNT = 0x380;
const LAPIC_TDIV = 0x3e0;

const LVT_MASKED: u32 = 1 << 16;
const LVT_PERIODIC: u32 = 1 << 17;

var lapic_base: usize = 0xfee0_0000;

inline fn read(reg: usize) u32 {
    return @as(*volatile u32, @ptrFromInt(lapic_base + reg)).*;
}

inline fn write(reg: usize, val: u32) void {
    @as(*volatile u32, @ptrFromInt(lapic_base + reg)).* = val;
}

// ------------------------------
// Init LAPIC
// ------------------------------
pub fn init() void {
    // Enable LAPIC via MSR
    const base = msr.rdmsr(IA32_APIC_BASE_MSR);
    msr.wrmsr(IA32_APIC_BASE_MSR, base | APIC_ENABLE);

    lapic_base = @intCast(base & 0xffff0000);

    write(LAPIC_SVR, @as(u32, SPURIOUS_VECTOR) | 0x100);
}

// ----------------------------
// CPU ID
// ----------------------------
pub fn id() u32 {
    return read(LAPIC_ID) >> 24;
}

// ---------------------------
// EOI
// ---------------------------
pub fn eoi() void {
    write(LAPIC_EOI, 0);
}

// ---------------------------
// Timer (periodic for now)
// ---------------------------
pub fn timer_init_periodic(initial_count: u32) void {
    write(LAPIC_TDIV, 0x3);

    // initial count (tune later)
    write(LAPIC_LVT_TIMER, @as(u32, TIMER_VECTOR) | LVT_PERIODIC);

    write(LAPIC_TINITCNT, initial_count);
}

// -------------------------------------
// One-shot timer (for tickless later)
// -------------------------------------
pub fn timer_set_oneshot(initial_count: u32) void {
    write(LAPIC_TDIV, 0x3);
    write(LAPIC_LVT_TIMER, @as(u32, TIMER_VECTOR));
    write(LAPIC_TINITCNT, initial_count);
}

pub fn timer_mask(mask: bool) void {
    var v = read(LAPIC_LVT_TIMER);
    if (mask) v |= LVT_MASKED else v &= ~LVT_MASKED;
    write(LAPIC_LVT_TIMER, v);
}

// ------------------------------------
// Send IPI (for SMP)
// ------------------------------------
const LAPIC_ICR_LOW = 0x300;
const LAPIC_ICR_HIGH = 0x310;

pub fn send_ipi(apic_id: u32, vector: u8) void {
    write(LAPIC_ICR_HIGH, apic_id << 24);
    write(LAPIC_ICR_LOW, vector);
}
