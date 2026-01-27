const std = @import("std");

const common = @import("common");

const gdt = @import("gdt.zig");
const idt = @import("interrupts/idt.zig");
const lapic = @import("lapic.zig");
const smp = @import("smp.zig");
const pic = @import("pic.zig");
const serial = @import("serial.zig");
const tsc = @import("tsc");

// --- CPU + init ---

pub fn cpu_init_bsp() void {
    gdt.init();
    idt.init();
    pic.disable();
    lapic.init();
}

pub fn cpu_init_ap() void {
    gdt.init();
    idt.init();
    lapic.init();
}

pub fn cpu_id() usize {
    // Use APIC ID as kernel CPU index (0..255)
    return @as(usize, lapic.id());
}

// Pack arch-specific CPU data into the opaque blob.
// Kernel never interprets it; only stores it.
pub fn cpu_arch_data() common.ArchCpuData {
    // Layout is private to x86 arch code. Kernel doesn't care.
    const Packed = extern struct {
        apic_id: u32,
        _pad: u32 = 0,
        tss_ptr: usize,
    };

    var data: common.ArchCpuData = .{};
    const p = Packed{
        .apic_id = lapic.readId(),
        .tss_ptr = @intFromPtr(gdt.get_tss()),
    };

    const src: [*]const u8 = @ptrCast(&p);
    const dst: [*]u8 = @ptrCast(&data);
    @memcpy(dst[0..@sizeOf(Packed)], src[0..@sizeOf(Packed)]);

    return data;
}

// ---- SMP ----
/// AP Entry callback provided by kernel.
var ap_entry_fn: ?common.ApEntryFn = null;

pub fn smp_init() void {
    smp.init();
}

pub fn smp_set_ap_entry(entry: common.ApEntryFn) void {
    ap_entry_fn = entry;
}

pub fn smp_get_ap_entry() common.ApEntryFn {
    return ap_entry_fn orelse @panic("[arch] AP entry not set");
}

pub fn smp_send_ipi(cpu: usize) void {
    lapic.sendIPI(@intCast(cpu));
}

// ---- IRQ control ----
pub fn enable_interrupts() void {
    asm volatile ("sti");
}

pub fn disable_interrupts() void {
    asm volatile ("cli");
}

// ---- Timers ----
pub fn timer_init() void {
    // TODO: add timers
}

// ---- Halt ----
pub fn halt_catch_fire() noreturn {
    while (true) asm volatile ("hlt");
}

pub fn halt() void {
    asm volatile ("hlt");
}

pub fn dumpCpuState() void {
    var rip: u64 = 0;
    var rsp: u64 = 0;
    var rflags: u64 = 0;

    asm volatile (
        \\leaq 0(%%rip), %[rip]
        : [rip] "=r" (rip),
        :
        : .{});
    asm volatile (
        \\movq %%rsp, %[rsp]
        : [rsp] "=r" (rsp),
        :
        : .{});
    asm volatile (
        \\pushfq
        \\popq %[rflags]
        : [rflags] "=r" (rflags),
        :
        : .{});

    serial.println("\nCPU State: ");
    serial.printfln("    RIP: 0x{x}", .{rip});
    serial.printfln("    RSP: 0x{x}", .{rsp});
    serial.printfln("    RFLAGS: 0x{x}", .{rflags});
}

pub fn now() usize {
    return @import("tsc.zig").rdtsc();
}

pub fn set_deadline(delta_ticks: u64) void {
    lapic.timer_set_oneshot(@truncate(delta_ticks));
}
