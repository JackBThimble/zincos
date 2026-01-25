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
const heap = @import("mm/heap.zig");

const fb = @import("graphics/framebuffer.zig");

const kalloc = @import("mm/kalloc.zig");
const stress = @import("mm/kalloc_stress.zig");

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

    var fa = pmm.FrameAllocator.init(g_boot_info);

    var mapper = vmm.Mapper{
        .hhdm_base = g_boot_info.hhdm_base,
        .fa = &fa,
    };

    var h = heap.Heap.init(&mapper, 0xffff_ffff_c000_0000, 256 * 1024 * 1024);

    serial.printf("frames total={} used={} free={}\n", .{ fa.frame_count, fa.used_frames, fa.frame_count - fa.used_frames });

    const p = h.alloc(4096, 16) orelse @panic("heap alloc failed");
    serial.printf("heap alloc ok: {x}\n", .{@intFromPtr(p)});
    const TEST_VA: u64 = 0xffff_ffff_d000_0000;
    const flags = vmm.PTE_PRESENT | vmm.PTE_WRITABLE | vmm.PTE_NX;

    const p1 = fa.allocFrame() orelse @panic("no frame");
    mapper.map4k(TEST_VA, p1, flags);

    const ptr1: *volatile u64 = @ptrFromInt(@as(usize, @intCast(TEST_VA)));
    serial.printfln("mapped {x} -> {x}, wrote {x}", .{ TEST_VA, p1, ptr1.* });

    const old = mapper.unmap4k(TEST_VA) orelse @panic("unmap failed");
    serial.printfln("unmapped {x} old_phys={x}\n", .{ TEST_VA, old });

    fa.freeFrame(old);
    serial.printfln("freed frame {x}", .{old});

    const p2 = fa.allocFrame() orelse @panic("no frame after free");
    serial.printfln("realloc frame {x}", .{p2});

    mapper.map4k(TEST_VA, p2, flags);
    const ptr2: *volatile u64 = @ptrFromInt(@as(usize, @intCast(TEST_VA)));
    ptr2.* = 0xaabb_ccdd_eeff_0011;

    serial.printfln("remapped {x} -> {x}, wrote {x}", .{ TEST_VA, p2, ptr2.* });

    const a = h.alloc(1, 1) orelse @panic("heap alloc (a) failed");
    const b = h.alloc(64, 64) orelse @panic("heap alloc (b) failed");
    const c = h.alloc(4096, 4096) orelse @panic("heap alloc (c) failed");

    _ = a;
    _ = b;
    _ = c;

    var h2 = heap.Heap.init(&mapper, 0xffff_ffff_d000_0000, 512 * 1024 * 1024);
    var ka = kalloc.KAlloc.init(&h2);

    const p3 = ka.kmalloc(64) orelse @panic("kamlloc failed");
    @memset(p3[0..64], 0xab);

    ka.free(p3);

    const q = ka.kmallocAligned(4096, 4096) orelse @panic("kamlloc aligned failed");
    ka.free(q);

    const r = ka.kmalloc(128) orelse @panic("kmalloc (r) failed");
    const s = ka.kmalloc(128) orelse @panic("kmalloc (s) failed");
    ka.free(r);
    ka.free(s);

    const t = ka.kmalloc(200) orelse @panic("kmalloc (t) failed");
    ka.free(t);

    stress.run(&ka, 1000);
    serial.println("\nKernel initialization complete. Halting.\n");

    halt();
}
