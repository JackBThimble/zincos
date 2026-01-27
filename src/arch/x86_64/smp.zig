const common = @import("common");
const arch = @import("arch_impl.zig");
const lapic = @import("lapic.zig");

// Symbols from trampoline asm
extern const smp_trampoline_start: u8;
extern const smp_trampoline_end: u8;

// Fixed low memory location for trampoline + params.
// Must be identity-mapped in VMM.
const TRAMPOLINE_PHYS: usize = 0x7000;
const PARAMS_PHYS: usize = 0x7800;

// Trampoline parameter block (read by ASM)
const TrampolineParams = extern struct {
    cr3: u64,
    gdt_ptr: u64, // pointer to a 16-byte GDTR struct in memory
    entry: u64, // address of ap_main (64-bit)
    stack_top: u64, // per-AP stack top (virtual)
};

// Simple stack pool for APs (works early).
// TODO: Replace with real allocator later
const STACK_SIZE: usize = 32 * 1024;
var ap_stacks: [common.MAX_CPUS][STACK_SIZE]u8 align(16) = undefined;

fn stackTopForApic(apic_id: u32) usize {
    const idx: usize = @intCast(apic_id);
    const base = @intFromPtr(&ap_stacks[idx][0]);
    return base + STACK_SIZE;
}

// Exported entry called by trampoline after switching to long mode
// Must be C ABI so ASM can call it.
export fn ap_main(stack_top: usize) callconv(.c) noreturn {
    // Per-CPU arch init for AP
    arch.cpu_init_ap();

    const entry = arch.smp_get_ap_entry();
    entry(stack_top);
}

// Copy trampoline bytes into low memory.
fn copyTrampoline() void {
    const start = @intFromPtr(&smp_trampoline_start);
    const end = @intFromPtr(&smp_trampoline_end);
    const len = end - start;

    const src: [*]const u8 = @ptrFromInt(start);
    const dst: [*]u8 = @ptrFromInt(TRAMPOLINE_PHYS);

    @memcpy(dst[0..len], src[0..len]);
}

// Write trampoline params into low memory.
// Must provide CR3 and GDTR.
fn writeParams(apic_id: u32) void {
    const params: *TrampolineParams = @ptrFromInt(PARAMS_PHYS);

    // Read CR3
    var cr3: u64 = 0;
    asm volatile ("mov %%cr3, %0"
        : [_] "=r" (cr3),
    );

    // Provide pointer to a GDTR struct suitable for AP long mode
    const gdtr_ptr = @intFromPtr(@import("gdt.zig").gdt_ptr());

    params.* = .{
        .cr3 = cr3,
        .gdt_ptr = @intCast(gdtr_ptr),
        .entry = @intCast(@intFromPtr(&ap_main)),
        .stack_top = @intCast(stackTopForApic(apic_id)),
    };
}

pub fn init() void {
    // Copy trampoline into low memory
    copyTrampoline();

    // Enumerate APs (APIC IDs)
    // MUST replace with enumeration source
    // - ACPI MADT parser
    // - bootloader provided CPU list
    const apic_ids = lapic.enumerate_apic_ids();

    const bsp_id: u32 = lapic.readId();

    for (apic_ids) |apic_id| {
        if (apic_id == bsp_id) continue;

        writeParams(apic_id);

        // INIT + SIPI(+SIPI)
        lapic.sendInit(apic_id);
        lapic.udelay(10_000); // 10ms

        // SIPI vector is physical page of trampoline
        const vector: u8 = @intCast(TRAMPOLINE_PHYS >> 12);
        lapic.sendStartup(apic_id, vector);
        lapic.udelay(200);
        lapic.sendStartup(apic_id, vector);
        lapic.udelay(200);
    }
}
