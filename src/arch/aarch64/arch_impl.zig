const common = @import("common");
const vmm = @import("mm").vmm;

var ap_entry_fn: ?common.ApEntryFn = null;

pub fn smp_set_ap_entry(entry: common.ApEntryFn) void {
    ap_entry_fn = entry;
}

pub fn smp_get_ap_entry() ?common.ApEntryFn {
    return ap_entry_fn orelse @panic("[arch] AP Entry not set");
}

pub fn cpu_init_bsp() void {
    // TODO: exception vectors, MMU, GIC init
}

pub fn cpu_init_ap() void {
    // TODO: per-core init
}

pub fn cpu_id() usize {
    // Minimal MPIDR_EL1 based ID (low 8 bits is commonly core ID)
    var mpidr: u64 = 0;
    asm volatile ("mrs %0, mpidr_el1"
        : [_] "=r" (mpidr),
    );
    return @as(usize, @intCast(mpidr & 0xFF));
}

pub fn cpu_arch_data() common.ArchCpuData {
    const Packed = extern struct {
        mpidr: u64,
    };

    var data: common.ArchCpuData = .{};
    var mpidr: u64 = 0;
    asm volatile ("mrs %0, mpidr_el1"
        : [_] "=r" (mpidr),
    );

    const p = Packed{ .mpidr = mpidr };

    const src: [*]const u8 = @ptrCast(&p);
    const dst: [*]u8 = @ptrCast(&data);
    @memcpy(dst[0..@sizeOf(Packed)], src[0..@sizeOf(Packed)]);

    return data;
}

pub fn smp_init() void {
    // TODO: PSCI CPU_ON or platform method.
    // When implemented, you'll call ap_entry_fn once AP is in EL1 with stack.
}

pub fn smp_ap_count() u32 {
    return 0; // TODO
}

pub fn smp_release_aps() void {
    // TODO
}

pub fn smp_send_ipi(_: usize, _: u8) void {
    // TODO: GIC SGI
}

pub fn enable_interrupts() void {
    // Clear I-bit (DAIF)
    asm volatile ("msr daifclr, #2");
}

pub fn disable_interrupts() void {
    asm volatile ("msr daifset, #2");
}

pub fn halt() void {
    asm volatile ("wfi");
}

pub fn halt_catch_fire() noreturn {
    while (true) asm volatile ("wfi");
}

/// Map architecture-specific MMIO regions and initialize hardware.
/// On AArch64: maps and initializes GIC, timers, etc.
pub fn mmio_init(mapper: vmm.Mapper) void {
    _ = mapper;
    // TODO: Map GIC distributor/redistributor MMIO regions
    // TODO: Initialize GIC
    // TODO: Map and init ARM generic timer
}

pub fn timer_init() void {
    // TODO: ARM generic timer init
}

pub fn dumpCpuState() void {
    // TODO: dump ARM registers
}

pub fn now() usize {
    // Read CNTPCT_EL0 (physical counter)
    var cnt: u64 = 0;
    asm volatile ("mrs %0, cntpct_el0"
        : [_] "=r" (cnt),
    );
    return @intCast(cnt);
}

pub fn set_deadline(delta_ticks: u64) void {
    _ = delta_ticks;
    // TODO: Set CNTP_TVAL_EL0 for timer interrupt
}
