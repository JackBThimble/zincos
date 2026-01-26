// Minimal example kernel for testing the bootloader
// This is a freestanding x86_64 kernel that receives boot info and draws to the framebuffer
//
// Build with:
//   zig build-exe src/kernel.zig -target x86_64-freestanding-none \
//     -fno-red-zone --script linker.ld -O ReleaseSafe

const std = @import("std");
const arch = @import("arch");
const gdt = arch.gdt;
const idt = arch.idt;
const apic = arch.apic;
const syscall = arch.syscall;
const serial = arch.serial;
const halt = arch.halt;
const builtin = @import("std").builtin;
pub const panic = @import("panic.zig").panic;

const common = @import("common");
const FramebufferInfo = common.FramebufferInfo;
const MemoryKind = common.MemoryKind;
const PixelFormat = common.PixelFormat;
const MemoryRegion = common.MemoryRegion;
const BootInfo = common.BootInfo;
const BOOT_MAGIC = common.BOOT_MAGIC;

const pmm = @import("mm/pmm.zig");
const vmm = @import("mm/vmm.zig");
const kheap = @import("mm/kheap.zig");
const stress = @import("mm/kalloc_stress.zig");

const fb = @import("graphics/framebuffer.zig");

// ============================================================================
// Kernel Entry Point
// ============================================================================

export fn _start(boot_info: *BootInfo) callconv(.{ .x86_64_sysv = .{} }) noreturn {
    common.g_boot_info = boot_info;
    const g_boot_info = common.g_boot_info.?;
    // Initialize serial for debug output
    serial.init();
    serial.println("\n\n=== Kernel Started ===");

    idt.init();
    gdt.init();

    var cs: u16 = 0;
    var ss: u16 = 0;

    asm volatile ("mov %%cs, %[v]"
        : [v] "=r" (cs),
        :
        : .{});
    asm volatile ("mov %%ss, %[v]"
        : [v] "=r" (ss),
        :
        : .{});

    serial.printfln("After gdt.init(): CS=0x{x}  SS=0x{x}", .{ cs, ss });
    // Validate boot info magic
    if (common.g_boot_info.?.magic != BOOT_MAGIC) {
        serial.println("ERROR: Invalid boot magic!");
        halt();
    }

    serial.println("Boot magic validated");

    serial.printfln("BOOT_MAGIC: 0x{x}", .{g_boot_info.magic});

    serial.printfln("Kernel physical base: 0x{x}", .{
        g_boot_info.kernel_physical_base,
    });

    serial.printfln("Kernel virtual base: 0x{x}", .{
        g_boot_info.kernel_virtual_base,
    });

    serial.printfln("Kernel size: 0x{x}", .{
        g_boot_info.kernel_size,
    });

    // Print boot info
    serial.printfln("Framebuffer: 0x{x}", .{g_boot_info.framebuffer.base_address});

    serial.printfln("Resolution: {d}x{d}", .{ g_boot_info.framebuffer.width, g_boot_info.framebuffer.height });

    serial.printfln("Memory regions: {d}", .{g_boot_info.memory_map_entries});

    serial.printfln("RSDP: 0x{x}", .{g_boot_info.rsdp_address});

    // Initialize framebuffer
    fb.init_framebuffer(g_boot_info);

    // Clear screen to a nice dark blue
    fb.clear_screen(0x10, 0x20, 0x40);

    // Draw some stuff to prove we're alive
    // White border
    fb.fill_rect(0, 0, g_boot_info.framebuffer.width, 4, 0xFF, 0xFF, 0xFF);
    fb.fill_rect(0, g_boot_info.framebuffer.height - 4, g_boot_info.framebuffer.width, 4, 0xFF, 0xFF, 0xFF);
    fb.fill_rect(0, 0, 4, g_boot_info.framebuffer.width, 0xFF, 0xFF, 0xFF);
    fb.fill_rect(g_boot_info.framebuffer.width - 4, 0, 4, g_boot_info.framebuffer.height, 0xFF, 0xFF, 0xFF);

    // Title bar
    fb.fill_rect(0, 0, g_boot_info.framebuffer.width, 32, 0x30, 0x50, 0x80);

    // Draw text
    fb.draw_string(16, 10, "Zig Kernel v0.1 - Booted successfully!", 0xFF, 0xFF, 0xFF);
    fb.draw_string(16, 50, "Boot info received from bootloader:", 0xC0, 0xC0, 0xC0);
    var buf: [256]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "Base address: 0x{x}", .{g_boot_info.framebuffer.base_address}) catch unreachable;
    fb.draw_string(16, 90, line, 0xc0, 0xc0, 0xc0);

    // Draw some colored boxes as a test pattern
    const y: u32 = 100;
    fb.fill_rect(16, y, 100, 40, 0xFF, 0x00, 0x00);
    fb.draw_string(20, y + 16, "RED", 0xFF, 0xFF, 0xFF);

    fb.fill_rect(136, y, 100, 40, 0x00, 0xFF, 0x00);
    fb.draw_string(140, y + 16, "GREEN", 0x00, 0x00, 0x00);

    fb.fill_rect(256, y, 100, 40, 0x00, 0x00, 0xFF);
    fb.draw_string(260, y + 16, "BLUE", 0xFF, 0xFF, 0xFF);

    // =========================================================================
    // Memory Management Initialization
    // =========================================================================
    var fa = pmm.FrameAllocator.init(g_boot_info);
    serial.printfln("PMM: frames total={} used={} free={}", .{
        fa.frame_count,
        fa.used_frames,
        fa.frame_count - fa.used_frames,
    });

    var mapper = vmm.Mapper{
        .hhdm_base = g_boot_info.hhdm_base,
        .fa = &fa,
    };

    // Kernel heap: 512MB virtual region starting at 0xFFFFC00000000000
    const HEAP_BASE: u64 = 0xFFFF_C000_0000_0000;
    const HEAP_SIZE: u64 = 512 * 1024 * 1024;
    var heap = kheap.KHeap.init(&mapper, HEAP_BASE, HEAP_SIZE);
    serial.printfln("Heap initialized at 0x{x}, size {} MB", .{ HEAP_BASE, HEAP_SIZE / (1024 * 1024) });

    // Run stress test to validate allocator
    stress.heap_stress_test(&heap);

    // Verify heap integrity and dump statistics
    heap.dumpStats();

    // =========================================================================
    // TODO: SMP Bring-up
    // =========================================================================
    // 1. Parse ACPI MADT to find AP processor IDs
    // 2. Allocate per-CPU stacks (e.g., 16KB each)
    // 3. Set up AP trampoline code in low memory
    // 4. Send INIT-SIPI-SIPI sequence to wake APs
    // 5. Each AP initializes its own GDT/IDT/TSS

    serial.println("\nKernel initialization complete. Halting.\n");

    halt();
}

pub const std_options: std.Options = .{
    .page_size_max = 4096,
    .page_size_min = 4096,
};
