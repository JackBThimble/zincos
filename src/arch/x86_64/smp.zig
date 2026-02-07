const std = @import("std");
const acpi = @import("acpi.zig");
const apic = @import("apic.zig");
const percpu = @import("cpu/percpu.zig");
const smp_manager = @import("smp/manager.zig");
const boot = @import("shared").boot;
const log = @import("shared").log;

const TRAMPOLINE_ADDR: u64 = 0x8000;
const AP_STACK_SIZE: usize = 32 * 1024;

pub var local_apic: apic.LocalApic = undefined;
pub var cpu_manager: smp_manager.SmpManager = undefined;

pub fn init(allocator: std.mem.Allocator, boot_info: *const boot.BootInfo) !void {
    // Parse ACPI to find CPUs in MADT
    const acpi_tables = try acpi.AcpiTables.init(boot_info.rsdp_address);
    const madt = acpi_tables.madt orelse return error.NoMadt;

    // Initialize local APIC
    const apic_base = apic.getApicBase() & ~@as(u64, 0xfff);
    local_apic = apic.LocalApic.init(apic_base);
    local_apic.enable();

    // Count CPUs first
    const cpu_count = try countCpus(madt);

    // Initialize CPU manager
    cpu_manager = try smp_manager.Manager.init(allocator, cpu_count);

    // Discover and allocate CPUs
    try discoverCpus(allocator, madt);

    // Set up BSP's per-CPU data
    // const bsp = cpu_manager.getCpu(0) orelse return error.NoBsp;

    var bsp: ?*percpu.PerCpu = undefined;
    for (cpu_manager.cpus) |cpu| {
        if (cpu.?.is_bsp) {
            bsp = cpu;
        }
    }

    try setupBspPerCpu(bsp.?);

    // Boot APs
    try bootApplicationProcessors(allocator, boot_info);

    // Wait for all CPUs to come online
    try cpu_manager.waitForOnline(cpu_count, 5000); // 5 second timeout
}

fn countCpus(madt: *const acpi.Madt) !u32 {
    var count: u32 = 0;
    const entries = madt.getEntries();
    var offset: usize = 0;

    while (offset < entries.len) {
        const header = @as(*const acpi.Madt.EntryHeader, @ptrCast(@alignCast(&entries[offset])));

        if (@as(acpi.Madt.EntryType, @enumFromInt(header.entry_type)) == .local_apic) {
            const lapic = @as(
                *const acpi.Madt.LocalApic,
                @ptrCast(@alignCast(header)),
            );
            if (lapic.isEnabled()) count += 1;
        }

        offset += header.length;
    }

    return count;
}

fn discoverCpus(allocator: std.mem.Allocator, madt: *const acpi.Madt) !void {
    _ = allocator;
    const bsp_apic_id = local_apic.getId();

    const entries = madt.getEntries();
    var offset: usize = 0;

    while (offset < entries.len) {
        const header = @as(*const acpi.Madt.EntryHeader, @ptrCast(@alignCast(&entries[offset])));

        if (@as(acpi.Madt.EntryType, @enumFromInt(header.entry_type)) == .local_apic) {
            const lapic = @as(
                *const acpi.Madt.LocalApic,
                @ptrCast(@alignCast(header)),
            );

            if (lapic.isEnabled()) {
                const is_bsp = lapic.apic_id == bsp_apic_id;
                _ = try cpu_manager.allocateCpu(lapic.apic_id, is_bsp);
            }
        }

        offset += header.length;
    }
}

fn setupBspPerCpu(cpu: *percpu.PerCpu) !void {
    // Set up GDT with TSS
    cpu.gdt.setTss(&cpu.tss);
    cpu.gdt.load();
    cpu.gdt.loadTss();

    // Set GS_BASE to point to this per-CPU structure
    percpu.setGsBase(cpu);

    // Mark BSP as online
    cpu_manager.markOnline(cpu);
}

fn bootApplicationProcessors(allocator: std.mem.Allocator, boot_info: *const boot.BootInfo) !void {
    // Copy trampoline to low memory
    try setupTrampoline();

    // Get current page table
    const pml4 = asm volatile ("movq %%cr3, %[pt]"
        : [pt] "=r" (-> u64),
    );

    // Boot each AP
    for (0..cpu_manager.cpu_count) |i| {
        const cpu = cpu_manager.getCpu(@intCast(i)) orelse continue;
        if (cpu.is_bsp) continue;

        try bootAp(allocator, cpu, pml4, boot_info);
    }
}

const TrampolineMailbox = extern struct {
    pml4: u64,
    stack: u64,
    percpu: u64,
    entry: u64,
    started: u32,
};

fn trampolineMailbox() *volatile TrampolineMailbox {
    const tramp_data_off = @intFromPtr(&ap_trampoline_data) - @intFromPtr(&ap_trampoline_start);
    const tramp_data_base = TRAMPOLINE_ADDR + tramp_data_off;
    return @ptrFromInt(tramp_data_base);
}

extern const ap_trampoline_start: u8;
extern const ap_trampoline_data: u8;

fn setupTrampoline() !void {
    // TODO:
    // Link ap_trampoline.s and copy it here
    // For now, assume external symbols

    const trampoline_size = @intFromPtr(&ap_trampoline_data) - @intFromPtr(&ap_trampoline_start);
    const trampoline_code = @as([*]const u8, @ptrCast(&ap_trampoline_start))[0..trampoline_size];
    const dest = @as([*]u8, @ptrFromInt(TRAMPOLINE_ADDR));

    @memcpy(dest[0..trampoline_code.len], trampoline_code);
}

fn bootAp(
    allocator: std.mem.Allocator,
    cpu: *percpu.PerCpu,
    pml4: u64,
    boot_info: *const boot.BootInfo,
) !void {
    _ = boot_info;

    const stack = try allocator.alignedAlloc(u8, std.mem.Alignment.@"16", AP_STACK_SIZE);
    cpu.kernel_stack = @intFromPtr(stack.ptr) + stack.len;
    cpu.tss.rsp0 = cpu.kernel_stack;

    cpu.gdt.setTss(&cpu.tss);

    const trampoline = trampolineMailbox();
    trampoline.pml4 = pml4;
    trampoline.stack = cpu.kernel_stack;
    trampoline.percpu = @intFromPtr(&cpu.cpu_id);
    trampoline.entry = @intFromPtr(&apEntry);
    trampoline.started = 0;

    // send INIT IPI
    local_apic.sendIpi(
        @truncate(cpu.apic_id),
        0,
        .init,
        .assert,
        .level,
    );

    busyWaitMs(10);

    // Send SIPI #1
    const startup_vector: u8 = @truncate(TRAMPOLINE_ADDR >> 12);
    local_apic.sendIpi(
        @truncate(cpu.apic_id),
        startup_vector,
        .sipi,
        .assert,
        .edge,
    );

    busyWaitMs(200);

    // Send SIPI #2 (Intel requirement)
    local_apic.sendIpi(
        @truncate(cpu.apic_id),
        startup_vector,
        .sipi,
        .assert,
        .edge,
    );

    // wait for ap to start (max 1 second)
    const timeout_us: u64 = 1_000_000;
    var elapsed: u64 = 0;
    while (@atomicLoad(u32, &trampoline.started, .acquire) == 0) {
        busyWaitUs(100);
        elapsed += 100;
        if (elapsed > timeout_us) {
            return error.ApStartupTimeout;
        }
    }
}

export fn apEntry() callconv(.c) noreturn {
    const apic_id: u32 = @as(u32, local_apic.getId());
    const cpu = cpu_manager.getCpuByApicId(apic_id) orelse @panic("Invalid APIC ID in apEntry");
    percpu.setGsBase(cpu);

    // Load this CPU's GDT/TSS
    cpu.gdt.load();
    cpu.gdt.loadTss();

    // Enable local APIC
    local_apic.enable();

    // AP reached kernel entry with resolved per-CPU identity.
    log.info("AP online: cpu_id={} apic_id={}", .{ cpu.cpu_id, cpu.apic_id });

    // Mark CPU as online
    cpu_manager.markOnline(cpu);

    while (true) {
        asm volatile ("hlt");
    }
}

fn busyWaitUs(us: u64) void {
    const start = readTsc();
    const cycles = us * 2500;
    while (readTsc() - start < cycles) {
        std.atomic.spinLoopHint();
    }
}

fn busyWaitMs(ms: u64) void {
    busyWaitUs(ms * 1000);
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
