const std = @import("std");
const arch = @import("arch");
const shared = @import("shared");
const log = @import("shared").log;
const mm = @import("mm");

pub const std_options: std.Options = .{
    .page_size_min = 4096,
    .page_size_max = 4096,
};

var pmm_global: mm.pmm.FrameAllocator = undefined;
var vmm_mapper_global: arch.vmm.X64Mapper = undefined;
var kheap_global: mm.heap.KHeap = undefined;

export fn _start(boot_info: *shared.boot.BootInfo) callconv(.c) noreturn {
    log.setWriter(arch.serial.write);
    log.setTscFn(arch.rdtsc);
    // Initialize serial for debug output
    if (boot_info.magic != shared.boot.BOOT_MAGIC) {
        log.err("ERROR: Invalid boot magic!\n", .{});
        halt();
    }

    log.info("Boot magic validated\n", .{});

    // Print boot info
    log.info("Framebuffer address: 0x{X}", .{boot_info.framebuffer.base_address});

    log.info("Resolution: {d}x{d}", .{ boot_info.framebuffer.width, boot_info.framebuffer.height });

    log.info("Memory regions: {d}", .{boot_info.memory_map_entries});

    log.info("RSDP: 0x{X}", .{boot_info.rsdp_address});

    // Initialize framebuffer
    var fb = @import("framebuffer.zig").Framebuffer.init_framebuffer(boot_info.framebuffer.base_address, boot_info.framebuffer.width, boot_info.framebuffer.height, boot_info.framebuffer.pitch, boot_info.framebuffer.pixel_format);

    // Clear screen to a nice dark blue
    fb.clear_screen(0x10, 0x20, 0x40);

    // Draw some stuff to prove we're alive
    // White border
    fb.fill_rect(0, 0, fb.width, 4, 0xFF, 0xFF, 0xFF);
    fb.fill_rect(0, fb.height - 4, fb.width, 4, 0xFF, 0xFF, 0xFF);
    fb.fill_rect(0, 0, 4, fb.height, 0xFF, 0xFF, 0xFF);
    fb.fill_rect(fb.width - 4, 0, 4, fb.height, 0xFF, 0xFF, 0xFF);

    // Title bar
    fb.fill_rect(0, 0, fb.width, 32, 0x30, 0x50, 0x80);

    // Draw text
    fb.draw_string(16, 10, "Zig Kernel v0.1 - Booted successfully!", 0xFF, 0xFF, 0xFF);
    fb.draw_string(16, 50, "Boot info received from bootloader:", 0xC0, 0xC0, 0xC0);

    // Draw some colored boxes as a test pattern
    const y: u32 = 100;
    fb.fill_rect(16, y, 100, 40, 0xFF, 0x00, 0x00);
    fb.draw_string(20, y + 16, "RED", 0xFF, 0xFF, 0xFF);

    fb.fill_rect(136, y, 100, 40, 0x00, 0xFF, 0x00);
    fb.draw_string(140, y + 16, "GREEN", 0x00, 0x00, 0x00);

    fb.fill_rect(256, y, 100, 40, 0x00, 0x00, 0xFF);
    fb.draw_string(260, y + 16, "BLUE", 0xFF, 0xFF, 0xFF);

    pmm_global = mm.pmm.FrameAllocator.init(boot_info);
    vmm_mapper_global = arch.vmm.X64Mapper.init(&pmm_global, boot_info.hhdm_base);

    const heap_base: u64 = 0xffff_c000_0000_0000;
    const heap_size: u64 = 1024 * 1024 * 1024;
    kheap_global = mm.heap.KHeap.init(
        vmm_mapper_global.mapper(),
        heap_base,
        heap_size,
    );

    mm.debug.heap_stress_test(&kheap_global);

    const allocator = kheap_global.allocator();
    _ = allocator;

    // try arch.smp.init(allocator, boot_info);

    log.info("\nKernel initialization complete. Halting.\n", .{});

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
    arch.serial.write("KERNEL PANIC: ");
    arch.serial.write(msg);
    arch.serial.write("\n");
    halt();
}
