// Minimal example kernel for testing the bootloader
// This is a freestanding x86_64 kernel that receives boot info and draws to the framebuffer
//
// Build with:
//   zig build-exe src/kernel.zig -target x86_64-freestanding-none \
//     -fno-red-zone --script linker.ld -O ReleaseSafe

const std = @import("std");
// ============================================================================
// Boot Info Structure - must match bootloader's definition exactly
// ============================================================================

pub const FramebufferInfo = extern struct {
    base_address: u64,
    width: u32,
    height: u32,
    pitch: u32,
    bpp: u16,
    pixel_format: PixelFormat,
    _reserved: u8,
};

pub const PixelFormat = enum(u8) {
    rgb = 0,
    bgr = 1,
    bitmask = 2,
    blt_only = 3,
    unknown = 255,
};

pub const MemoryRegion = extern struct {
    base: u64,
    length: u64,
    kind: MemoryKind,
    _reserved0: u8,
    _reserved1: u8,
    _reserved2: u8,
    _padding: u32,
};

pub const MemoryKind = enum(u8) {
    usable = 0,
    reserved = 1,
    acpi_reclaimable = 2,
    acpi_nvs = 3,
    bad_memory = 4,
    bootloader_reclaimable = 5,
    kernel_and_modules = 6,
    framebuffer = 7,
};

pub const BootInfo = extern struct {
    magic: u64,
    framebuffer: FramebufferInfo,
    memory_map_addr: u64,
    memory_map_entries: u64,
    kernel_physical_base: u64,
    kernel_virtual_base: u64,
    kernel_size: u64,
    rsdp_address: u64,
};

const BOOT_MAGIC: u64 = 0xB007_1AF0_DEAD_BEEF;

// ============================================================================
// Framebuffer Drawing
// ============================================================================

var fb: ?*volatile u8 = null;
var fb_width: u32 = 0;
var fb_height: u32 = 0;
var fb_pitch: u32 = 0;
var fb_bgr: bool = false;

fn init_framebuffer(info: *const FramebufferInfo) void {
    fb = @ptrFromInt(info.base_address);
    fb_width = info.width;
    fb_height = info.height;
    fb_pitch = info.pitch;
    fb_bgr = info.pixel_format == .bgr;
}

fn put_pixel(x: u32, y: u32, r: u8, g: u8, b: u8) void {
    if (fb == null) return;
    if (x >= fb_width or y >= fb_height) return;

    const offset: usize = @intCast(y * fb_pitch + x * 4);
    const pixel: [*]volatile u8 = @ptrFromInt(@intFromPtr(fb.?) + offset);

    if (fb_bgr) {
        pixel[0] = b;
        pixel[1] = g;
        pixel[2] = r;
        pixel[3] = 0xFF;
    } else {
        pixel[0] = r;
        pixel[1] = g;
        pixel[2] = b;
        pixel[3] = 0xFF;
    }
}

fn fill_rect(x: u32, y: u32, w: u32, h: u32, r: u8, g: u8, b: u8) void {
    var py: u32 = y;
    while (py < y + h and py < fb_height) : (py += 1) {
        var px: u32 = x;
        while (px < x + w and px < fb_width) : (px += 1) {
            put_pixel(px, py, r, g, b);
        }
    }
}

fn clear_screen(r: u8, g: u8, b: u8) void {
    fill_rect(0, 0, fb_width, fb_height, r, g, b);
}

// Simple 8x8 bitmap font for basic text
const font_8x8 = @import("font.zig").Font8x8;

fn draw_char(x: u32, y: u32, c: u8, r: u8, g: u8, b: u8) void {
    // const idx: usize = if (c >= 32 and c < 128) c - 32 else 0;
    const glyph = font_8x8.glyph(c);

    for (0..8) |row| {
        const bits = glyph[row];
        for (0..8) |col| {
            if ((bits >> @intCast(7 - col)) & 1 == 1) {
                put_pixel(x + @as(u32, @intCast(col)), y + @as(u32, @intCast(row)), r, g, b);
            }
        }
    }
}

fn draw_string(x: u32, y: u32, str: []const u8, r: u8, g: u8, b: u8) void {
    var cx = x;
    for (str) |c| {
        if (c == '\n') {
            // Handle newline - not implemented in this simple version
            continue;
        }
        draw_char(cx, y, c, r, g, b);
        cx += 8;
    }
}

// ============================================================================
// Serial Output (COM1) - for debugging
// ============================================================================

const COM1: u16 = 0x3F8;

pub inline fn outb(port: u16, value: u8) void {
    return asm volatile (
        \\ outb %[value], %[port]
        :
        : [port] "{dx}" (port),
          [value] "{al}" (value),
    );
}

pub inline fn inb(port: u16) u8 {
    return asm volatile (
        \\ inb %[port], %[value]
        : [value] "={al}" (-> u8),
        : [port] "{dx}" (port),
    );
}
fn init_serial() void {
    outb(COM1 + 1, 0x00); // Disable interrupts
    outb(COM1 + 3, 0x80); // Enable DLAB
    outb(COM1 + 0, 0x03); // Baud rate divisor lo (38400)
    outb(COM1 + 1, 0x00); // Baud rate divisor hi
    outb(COM1 + 3, 0x03); // 8 bits, no parity, one stop bit
    outb(COM1 + 2, 0xC7); // Enable FIFO
    outb(COM1 + 4, 0x0B); // IRQs enabled, RTS/DSR set
}

fn serial_write(c: u8) void {
    while (inb(COM1 + 5) & 0x20 == 0) {}
    outb(COM1, c);
}

fn serial_print(str: []const u8) void {
    for (str) |c| {
        serial_write(c);
        if (c == '\n') serial_write('\r');
    }
}

fn serial_hex(value: u64) void {
    const hex = "0123456789ABCDEF";
    serial_print("0x");
    const v = value;
    var started = false;
    var i: u6 = 60;
    while (true) {
        const nibble: u4 = @truncate(v >> i);
        if (nibble != 0 or started or i == 0) {
            serial_write(hex[nibble]);
            started = true;
        }
        if (i == 0) break;
        i -= 4;
    }
}

// ============================================================================
// Kernel Entry Point
// ============================================================================

export fn _start(boot_info: *BootInfo) callconv(.c) noreturn {
    // Initialize serial for debug output
    init_serial();
    serial_print("\n\n=== Kernel Started ===\n");

    // Validate boot info magic
    if (boot_info.magic != BOOT_MAGIC) {
        serial_print("ERROR: Invalid boot magic!\n");
        halt();
    }

    serial_print("Boot magic validated\n");

    // Print boot info
    serial_print("Framebuffer: ");
    serial_hex(boot_info.framebuffer.base_address);
    serial_print("\n");

    serial_print("Resolution: ");
    serial_hex(boot_info.framebuffer.width);
    serial_print("x");
    serial_hex(boot_info.framebuffer.height);
    serial_print("\n");

    serial_print("Memory regions: ");
    serial_hex(boot_info.memory_map_entries);
    serial_print("\n");

    serial_print("RSDP: ");
    serial_hex(boot_info.rsdp_address);
    serial_print("\n");

    // Initialize framebuffer
    init_framebuffer(&boot_info.framebuffer);

    // Clear screen to a nice dark blue
    clear_screen(0x10, 0x20, 0x40);

    // Draw some stuff to prove we're alive
    // White border
    fill_rect(0, 0, fb_width, 4, 0xFF, 0xFF, 0xFF);
    fill_rect(0, fb_height - 4, fb_width, 4, 0xFF, 0xFF, 0xFF);
    fill_rect(0, 0, 4, fb_height, 0xFF, 0xFF, 0xFF);
    fill_rect(fb_width - 4, 0, 4, fb_height, 0xFF, 0xFF, 0xFF);

    // Title bar
    fill_rect(0, 0, fb_width, 32, 0x30, 0x50, 0x80);

    // Draw text
    draw_string(16, 10, "Zig Kernel v0.1 - Booted successfully!", 0xFF, 0xFF, 0xFF);
    draw_string(16, 50, "Boot info received from bootloader:", 0xC0, 0xC0, 0xC0);

    // Draw some colored boxes as a test pattern
    const y: u32 = 100;
    fill_rect(16, y, 100, 40, 0xFF, 0x00, 0x00);
    draw_string(20, y + 16, "RED", 0xFF, 0xFF, 0xFF);

    fill_rect(136, y, 100, 40, 0x00, 0xFF, 0x00);
    draw_string(140, y + 16, "GREEN", 0x00, 0x00, 0x00);

    fill_rect(256, y, 100, 40, 0x00, 0x00, 0xFF);
    draw_string(260, y + 16, "BLUE", 0xFF, 0xFF, 0xFF);

    serial_print("\nKernel initialization complete. Halting.\n");

    halt();
}

fn halt() noreturn {
    asm volatile ("cli");
    while (true) {
        asm volatile ("hlt");
    }
}

// Panic handler for Zig runtime
pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    serial_print("KERNEL PANIC: ");
    serial_print(msg);
    serial_print("\n");
    halt();
}
