pub const gdt = @import("gdt.zig");
pub const idt = @import("interrupts/idt.zig");
pub const pic = @import("pic.zig");
pub const lapic = @import("lapic.zig");
pub const syscall = @import("syscall.zig");
pub const serial = @import("serial.zig");
pub const msr = @import("msr.zig");

pub inline fn pause() void {
    asm volatile ("pause");
}

pub fn halt_catch_fire() noreturn {
    asm volatile ("cli");
    while (true) {
        asm volatile ("hlt");
    }
}

pub fn early_init() void {
    idt.init();
    var rsp: u64 = 0;
    asm volatile ("mov %%rsp, %[out]"
        : [out] "=r" (rsp),
    );
    gdt.init_bsp(lapic.id(), @intCast(rsp));
    pic.disable();
    lapic.init();
    lapic.timer_init_periodic(10_000_000);
}
