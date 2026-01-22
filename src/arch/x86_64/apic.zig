const serial = @import("serial.zig");

const PIC1_CMD: u16 = 0x20;
const PIC1_DATA: u16 = 0x21;
const PIC2_CMD: u16 = 0xa0;
const PIC2_DATA: u16 = 0xa1;

const ICW1_ICW4: u8 = 0x01;
const ICW1_INIT: u8 = 0x10;
const ICW4_8086: u8 = 0x01;

pub fn init() void {
    // save masks
    const mask1 = serial.inb(PIC1_DATA);
    const mask2 = serial.inb(PIC2_DATA);

    // start init sequence
    serial.outb(PIC1_CMD, ICW1_INIT | ICW1_ICW4);
    serial.io_wait();
    serial.outb(PIC2_CMD, ICW1_INIT | ICW1_ICW4);
    serial.io_wait();

    // set vector offsets (remap IRQs to 32-47)
    serial.outb(PIC1_DATA, 32); // IRQ 0-7 -> INT 32-39
    serial.io_wait();
    serial.outb(PIC2_DATA, 40); // IRQ 8-15 -> INT 40-47
    serial.io_wait();

    // tell master PIC that slave is at IRQ2
    serial.outb(PIC1_DATA, 4);
    serial.io_wait();

    // tell slave PIC its cascade identity
    serial.outb(PIC2_DATA, 2);
    serial.io_wait();

    // Set 8086 mode
    serial.outb(PIC1_DATA, ICW4_8086);
    serial.io_wait();
    serial.outb(PIC2_DATA, ICW4_8086);
    serial.io_wait();

    // restore saved masks
    serial.outb(PIC1_DATA, mask1);
    serial.outb(PIC2_DATA, mask2);
}

pub fn mask_irq(irq: u8) void {
    const port: u16 = if (irq < 8) PIC1_DATA else PIC2_DATA;
    const value = serial.inb(port) | (@as(u8, 1) << @truncate(irq % 8));
    serial.outb(port, value);
}

pub fn unmask_irq(irq: u8) void {
    const port: u16 = if (irq < 8) PIC1_DATA else PIC2_DATA;
    const value = serial.inb(port) & ~(@as(u8, 1) << @truncate(irq % 8));
    serial.outb(port, value);
}

pub fn disable() void {
    // mask all irqs
    serial.outb(PIC1_DATA, 0xff);
    serial.outb(PIC2_DATA, 0xff);
}
