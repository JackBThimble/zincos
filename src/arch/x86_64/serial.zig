pub const std = @import("std");
pub const COM1: u16 = 0x3F8;

pub inline fn outb(port: u16, value: u8) void {
    asm volatile (
        \\outb %[value], %[port]
        :
        : [value] "{al}" (value),
          [port] "{dx}" (port),
    );
}

pub inline fn inb(port: u16) u8 {
    return asm volatile (
        \\inb %[port], %[result]
        : [result] "={al}" (-> u8),
        : [port] "{dx}" (port),
    );
}

pub inline fn io_wait() void {
    outb(0x80, 0);
}

pub fn init() void {
    outb(COM1 + 1, 0x00); // Disable interrupts
    outb(COM1 + 3, 0x80); // Enable DLAB
    outb(COM1 + 0, 0x03); // Baud rate divisor lo (38400)
    outb(COM1 + 1, 0x00); // Baud rate divisor hi
    outb(COM1 + 3, 0x03); // 8 bits, no parity, one stop bit
    outb(COM1 + 2, 0xC7); // Enable FIFO
    outb(COM1 + 4, 0x0B); // IRQs enabled, RTS/DSR set
}

pub fn putChar(c: u8) void {
    while (inb(COM1 + 5) & 0x20 == 0) {}
    outb(COM1, c);
}

pub fn print(buf: []const u8) void {
    for (buf) |c| {
        putChar(c);
        if (c == '\n') putChar('\r');
    }
}

pub fn println(buf: []const u8) void {
    print(buf);
    print("\n");
}

pub fn printf(comptime fmt: []const u8, args: anytype) void {
    var buffer: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buffer, fmt, args) catch {
        print("[fmt error]\n");
        return;
    };

    print(msg);
}

pub fn printfln(comptime fmt: []const u8, args: anytype) void {
    printf(fmt, args);
    putChar('\n');
}

pub fn write(bytes: []const u8) void {
    print(bytes);
}
