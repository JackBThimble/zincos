const std = @import("std");
const common = @import("common");
const log = common.log;
const arch = @import("arch_impl.zig");
const lapic = @import("lapic.zig");
const gdt = @import("gdt.zig");

// Trampoline binary embedded at compile time (flat binary, no relocations)
const trampoline_bin = @import("smp_trampoline_bin").data;

// Fixed low memory location for trampoline + params.
// Must be identity-mapped in VMM.
const TRAMPOLINE_PHYS: usize = 0x7000;
const PARAMS_PHYS: usize = 0x7800;

// Trampoline parameter block (read by ASM)
// Layout must match offsets in smp_trampoline.asm EXACTLY
// Using packed struct to avoid C ABI padding
const TrampolineParams = packed struct {
    cr3: u64, // offset 0
    // GDTR embedded: limit (2 bytes) + base (8 bytes) = 10 bytes at offset 8
    gdtr_limit: u16, // offset 8
    gdtr_base: u64, // offset 10
    // entry at offset 24, so we need 6 bytes padding (offset 18 to 24)
    _pad0: u8,
    _pad1: u8,
    _pad2: u8,
    _pad3: u8,
    _pad4: u8,
    _pad5: u8,
    entry: u64, // offset 24
    stack_top: u64, // offset 32
};

comptime {
    // Verify offsets match ASM expectations
    if (@offsetOf(TrampolineParams, "cr3") != 0) @compileError("cr3 offset wrong");
    if (@offsetOf(TrampolineParams, "gdtr_limit") != 8) @compileError("gdtr_limit offset wrong");
    if (@offsetOf(TrampolineParams, "gdtr_base") != 10) @compileError("gdtr_base offset wrong");
    if (@offsetOf(TrampolineParams, "entry") != 24) @compileError("entry offset wrong");
    if (@offsetOf(TrampolineParams, "stack_top") != 32) @compileError("stack_top offset wrong");
}

// Simple stack pool for APs (works early).
// TODO: Replace with real allocator later
const STACK_SIZE: usize = 32 * 1024;
var ap_stacks: [common.MAX_CPUS][STACK_SIZE]u8 align(16) = undefined;

// AP online tracking
var ap_online_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
var ap_parked: [common.MAX_CPUS]std.atomic.Value(bool) = blk: {
    var arr: [common.MAX_CPUS]std.atomic.Value(bool) = undefined;
    for (&arr) |*v| v.* = std.atomic.Value(bool).init(false);
    break :blk arr;
};

// Signal for APs to unpark (set by scheduler when ready)
var ap_release: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

fn stackTopForApic(apic_id: u32) usize {
    const idx: usize = @intCast(apic_id);
    const base = @intFromPtr(&ap_stacks[idx][0]);
    return base + STACK_SIZE;
}

// Exported entry called by trampoline after switching to long mode
// Must be C ABI so ASM can call it.
export fn ap_main(stack_top: usize) callconv(.c) noreturn {
    // Write magic to indicate we got here (useful for debugging)
    const magic_ptr: *volatile u64 = @ptrFromInt(AP_MAGIC_ADDR);
    magic_ptr.* = AP_MAGIC_VALUE;

    // Per-CPU arch init for AP (GDT, IDT, LAPIC)
    arch.cpu_init_ap();

    const cpu_id = lapic.id();

    // Increment online count
    _ = ap_online_count.fetchAdd(1, .seq_cst);

    // Mark this AP as parked
    ap_parked[cpu_id].store(true, .seq_cst);

    log.info("[AP{}] Online, stack=0x{x}, parking...", .{ cpu_id, stack_top });

    // Park: spin until released by scheduler
    while (!ap_release.load(.seq_cst)) {
        asm volatile ("pause");
    }

    // Once released, call the kernel's AP entry
    const entry = arch.smp_get_ap_entry();
    entry(stack_top);
}

/// Get number of APs currently online and parked
pub fn getOnlineApCount() u32 {
    return ap_online_count.load(.seq_cst);
}

/// Release all parked APs to enter scheduler
pub fn releaseAps() void {
    ap_release.store(true, .seq_cst);
}

// Magic marker to detect AP execution - written by AP after successful boot
const AP_MAGIC_ADDR: usize = 0x7FF0;
const AP_MAGIC_VALUE: u64 = 0xDEAD_a400_b007_ed;

// Copy trampoline bytes from embedded binary to low memory (0x7000).
fn copyTrampoline() void {
    const src = trampoline_bin;
    const dst: [*]u8 = @ptrFromInt(TRAMPOLINE_PHYS);

    @memcpy(dst[0..src.len], src);

    // Clear the magic marker
    const magic_ptr: *volatile u64 = @ptrFromInt(AP_MAGIC_ADDR);
    magic_ptr.* = 0;
}

// Write trampoline params into low memory.
// Must provide CR3 and GDTR.
fn writeParams(apic_id: u32) void {
    const params: *TrampolineParams = @ptrFromInt(PARAMS_PHYS);

    // Read CR3
    var cr3: u64 = 0;
    asm volatile ("mov %%cr3, %[cr3]"
        : [cr3] "=r" (cr3),
    );

    // Copy GDTR from BSP's GDT
    const bsp_gdtr = gdt.gdt_ptr();

    params.* = .{
        .cr3 = cr3,
        .gdtr_limit = bsp_gdtr.limit,
        .gdtr_base = bsp_gdtr.base,
        ._pad0 = 0,
        ._pad1 = 0,
        ._pad2 = 0,
        ._pad3 = 0,
        ._pad4 = 0,
        ._pad5 = 0,
        .entry = @intFromPtr(&ap_main),
        .stack_top = stackTopForApic(apic_id),
    };
}

pub fn init() void {
    const bsp_id: u32 = lapic.id();
    log.info("[SMP] BSP APIC ID: {}", .{bsp_id});

    // Copy trampoline into low memory
    copyTrampoline();
    log.debug("[SMP] Trampoline copied to 0x{x}, size={}", .{ TRAMPOLINE_PHYS, trampoline_bin.len });

    // Verify trampoline was copied correctly
    const dst: [*]const u8 = @ptrFromInt(TRAMPOLINE_PHYS);
    log.debug("[SMP] Trampoline first bytes: 0x{x:0>2} 0x{x:0>2} 0x{x:0>2} 0x{x:0>2}", .{ dst[0], dst[1], dst[2], dst[3] });

    // Enumerate APs (APIC IDs)
    // TODO: Replace with ACPI MADT parsing
    const apic_ids = lapic.enumerate_apic_ids();
    log.info("[SMP] Found {} CPUs", .{apic_ids.len});

    var ap_count: u32 = 0;
    for (apic_ids) |apic_id| {
        if (apic_id == bsp_id) continue;
        ap_count += 1;

        log.debug("[SMP] Waking AP {}", .{apic_id});
        writeParams(apic_id);

        // Debug: print params
        const params: *const TrampolineParams = @ptrFromInt(PARAMS_PHYS);
        log.debug("[SMP]   CR3=0x{x}, entry=0x{x}, stack=0x{x}", .{ params.cr3, params.entry, params.stack_top });

        // INIT IPI
        log.debug("[SMP]   Sending INIT IPI...", .{});
        lapic.sendInit(apic_id);
        lapic.udelay(10_000); // 10ms delay after INIT

        // SIPI - vector is physical page number of trampoline
        const vector: u8 = @intCast(TRAMPOLINE_PHYS >> 12);
        log.debug("[SMP]   Sending SIPI vector=0x{x}...", .{vector});
        lapic.sendStartup(apic_id, vector);
        lapic.udelay(200); // 200us

        // Second SIPI (required by spec)
        log.debug("[SMP]   Sending second SIPI...", .{});
        lapic.sendStartup(apic_id, vector);
        lapic.udelay(200);
        log.debug("[SMP]   Done sending IPIs for AP {}", .{apic_id});

        // Wait a bit and check if AP reached ap_main
        lapic.udelay(1000); // 1ms
        const magic_ptr: *volatile u64 = @ptrFromInt(AP_MAGIC_ADDR);
        const magic_val = magic_ptr.*;
        if (magic_val == AP_MAGIC_VALUE) {
            log.debug("[SMP]   AP {} reached ap_main!", .{apic_id});
        } else {
            log.debug("[SMP]   AP {} did NOT reach ap_main (magic=0x{x})", .{ apic_id, magic_val });
        }
    }

    // Wait for all APs to come online (with timeout)
    log.info("[SMP] Waiting for {} APs to come online...", .{ap_count});

    var timeout: u32 = 1000; // 1 second timeout (1000 * 1ms)
    while (getOnlineApCount() < ap_count and timeout > 0) : (timeout -= 1) {
        lapic.udelay(1000); // 1ms
    }

    const online = getOnlineApCount();
    if (online == ap_count) {
        log.info("[SMP] All {} APs online and parked", .{online});
    } else {
        log.warn("[SMP] Only {}/{} APs came online (timeout)", .{ online, ap_count });
    }
}
