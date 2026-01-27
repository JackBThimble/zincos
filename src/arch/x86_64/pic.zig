const serial = @import("serial.zig");

const PIC1_DATA: u16 = 0x21;
const PIC2_DATA: u16 = 0xa1;

pub fn disable() void {
    // mask all irqs
    serial.outb(PIC1_DATA, 0xff);
    serial.outb(PIC2_DATA, 0xff);
}
