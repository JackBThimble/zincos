pub const gdt = @import("gdt.zig");
pub const idt = @import("interrupts/idt.zig");
pub const apic = @import("apic.zig");
pub const syscall = @import("syscall.zig");
pub const serial = @import("serial.zig");
pub const msr = @import("msr.zig");

pub fn halt() noreturn {
    asm volatile ("cli");
    while (true) {
        asm volatile ("hlt");
    }
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
