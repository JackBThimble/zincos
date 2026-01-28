// Minimal example kernel for testing the bootloader
// This is a freestanding x86_64 kernel that receives boot info and draws to the framebuffer
//
// Build with:
//   zig build-exe src/kernel.zig -target x86_64-freestanding-none \
//     -fno-red-zone --script linker.ld -O ReleaseSafe

const std = @import("std");
const arch = @import("arch");
const serial = arch.serial;
const tsc = arch.tsc;
const halt = arch.halt_catch_fire;
const builtin = @import("std").builtin;
pub const panic = @import("panic.zig").panic;

const common = @import("common");
const FramebufferInfo = common.FramebufferInfo;
const MemoryKind = common.MemoryKind;
const PixelFormat = common.PixelFormat;
const MemoryRegion = common.MemoryRegion;
const BootInfo = common.BootInfo;
const BOOT_MAGIC = common.BOOT_MAGIC;
const log = common.log;

const mm = @import("mm");
const pmm = mm.pmm;
const vmm = mm.vmm;
const kheap = mm.heap;
const mem_dbg = mm.debug;
const cpu_local = @import("cpu_local.zig");

const fb = @import("graphics/framebuffer.zig");

// ============================================================================
// AP Entry Point (called when APs are released from parking)
// ============================================================================
fn apEntry(stack_top: usize) callconv(.c) noreturn {
    const cpu_id = arch.cpu_id();
    log.info("[AP{}] Entered scheduler, stack=0x{x}", .{ cpu_id, stack_top });

    // TODO: Enter scheduler loop
    // For now, just halt
    arch.halt_catch_fire();
}

// ============================================================================
// Kernel Entry Point
// ============================================================================

export fn _start(boot_info: *BootInfo) callconv(.{ .x86_64_sysv = .{} }) noreturn {
    common.g_boot_info = boot_info;
    const g_boot_info = common.g_boot_info.?;

    arch.cpu_init_bsp();
    arch.serial.init();

    log.setWriter(serial.write);
    log.setCpuId(arch.cpu_id);
    log.setTscFn(arch.now);

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

    log.debug("GDT Initialization: CS=0x{x}  SS=0x{x}", .{ cs, ss });
    // Validate boot info magic
    if (common.g_boot_info.?.magic != BOOT_MAGIC) {
        log.err("ERROR: Invalid boot magic!", .{});
        halt();
    }

    log.debug("Bootloader info: ", .{});
    log.debug("\tBOOT_MAGIC: 0x{x}", .{g_boot_info.magic});

    log.debug("\tKernel physical base: 0x{x}", .{
        g_boot_info.kernel_physical_base,
    });

    log.debug("\tKernel virtual base: 0x{x}", .{
        g_boot_info.kernel_virtual_base,
    });

    log.debug("\tKernel size: 0x{x}", .{
        g_boot_info.kernel_size,
    });

    // Print boot info
    log.debug("\tFramebuffer: 0x{x}", .{g_boot_info.framebuffer.base_address});

    log.debug("\tResolution: {d}x{d}", .{ g_boot_info.framebuffer.width, g_boot_info.framebuffer.height });

    log.debug("\tMemory regions: {d}", .{g_boot_info.memory_map_entries});

    log.debug("\tRSDP: 0x{x}", .{g_boot_info.rsdp_address});

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
    log.debug("PMM: frames total={} used={} free={}", .{
        fa.frame_count,
        fa.used_frames,
        fa.frame_count - fa.used_frames,
    });

    // Create arch-specific mapper context
    var mapper_ctx = arch.mm.MapperCtx{
        .hhdm_base = g_boot_info.hhdm_base,
        .fa = &fa,
    };
    const mapper = mapper_ctx.mapper();

    // Map arch-specific MMIO regions and initialize hardware (LAPIC/GIC, etc.)
    arch.mmio_init(mapper);

    // Kernel heap: 512MB virtual region starting at 0xFFFFC00000000000
    const HEAP_BASE: u64 = 0xFFFF_C000_0000_0000;
    const HEAP_SIZE: u64 = 512 * 1024 * 1024;
    var heap = kheap.KHeap.init(mapper, HEAP_BASE, HEAP_SIZE);
    log.debug("Heap initialized at 0x{x}, size {} MB", .{ HEAP_BASE, HEAP_SIZE / (1024 * 1024) });

    // Run stress test to validate allocator
    mem_dbg.heap_stress_test(&heap);

    // Verify heap integrity and dump statistics
    heap.dumpStats();

    // =========================================================================
    // SMP Bring-up
    // =========================================================================
    // Set AP entry point (called when APs are released from parking)
    arch.smp_set_ap_entry(apEntry);

    // Bring up APs and park them
    arch.smp_init();

    log.info("Kernel initialization complete. {} APs parked.", .{arch.smp_ap_count()});
    log.info("Halting BSP.", .{});

    halt();
}

pub const std_options: std.Options = .{
    .page_size_max = 4096,
    .page_size_min = 4096,
};
