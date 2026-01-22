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

pub fn writeByte(c: u8) void {
    while (inb(COM1 + 5) & 0x20 == 0) {}
    outb(COM1, c);
}

pub fn write(buf: []const u8) void {
    for (buf) |c| {
        writeByte(c);
        if (c == '\n') writeByte('\r');
    }
}

pub fn writeHex(value: u64) void {
    const hex = "0123456789ABCDEF";
    write("0x");
    const v = value;
    var started = false;
    var i: u6 = 60;
    while (true) {
        const nibble: u4 = @truncate(v >> i);
        if (nibble != 0 or started or i == 0) {
            writeByte(hex[nibble]);
            started = true;
        }
        if (i == 0) break;
        i -= 4;
    }
}

pub fn writeDec(value: u64) void {
    var v = value;
    if (v == 0) {
        writeByte('0');
        return;
    }

    var buf: [20]u8 = undefined;
    var i: usize = buf.len;
    while (v > 0) : (v /= 10) {
        i -= 1;
        buf[i] = @as(u8, '0' + @as(u8, @truncate(v % 10)));
    }
    write(buf[i..]);
}
