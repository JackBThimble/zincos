//! Kernel Entry and Initialization
//!
//! - Reads boot info
//! - Sets up serial logger
//! - Sets up framebuffer instance
//! - Memory mapping
//! - Kernel heap initialization
//! - SMP bringup
//!
//! Notes:
//! - setGsBase must be called on BSP before any allocations are made
//!
const std = @import("std");
const arch = @import("arch");
const shared = @import("shared");
const log = @import("shared").log;
const mm = @import("mm");
const keyboard = @import("keyboard.zig");
const sched = @import("sched/core.zig");
const ipc = @import("ipc/mod.zig");
const process = @import("process/mod.zig");
const shm = @import("shm.zig");
const syscall_dispatch = @import("syscall_dispatch.zig");
const initrd_boot = @import("initrd_boot.zig");
const console = @import("console.zig");

pub const std_options: std.Options = .{
    .page_size_min = 4096,
    .page_size_max = 4096,
};

comptime {
    _ = syscall_dispatch.kernel_syscall_dispatch;
}

var pmm_global: mm.pmm.FrameAllocator = undefined;
var vmm_mapper_global: arch.vmm.X64Mapper = undefined;
var kheap_global: mm.heap.KHeap = undefined;
var fb_global: @import("framebuffer.zig").Framebuffer = undefined;

pub export fn kernel_ap_scheduler_start() callconv(.c) void {
    sched.startOnAp();
}

pub extern const __boot_stack_top: u8;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\lea __boot_stack_top(%%rip), %%rsp
        \\
        \\// Ensure 16-byte alignment before calling into SysV code.
        \\andq $-16, %%rsp
        \\
        \\//RDI = boot_info, untouched
        \\call kernel_main
        \\ud2
    );
}

pub export fn kernel_main(boot_info: *shared.boot.BootInfo) callconv(.c) noreturn {
    log.setEmergencyWriter(arch.serial.write);
    log.setWriter(arch.serial.write);
    log.setTscFn(arch.rdtsc);
    // Initialize serial for debug output
    if (boot_info.magic != shared.boot.BOOT_MAGIC) {
        log.err("ERROR: Invalid boot magic!\n", .{});
        arch.hcf();
    }

    arch.initHhdm(boot_info.hhdm_base);

    log.info("Boot magic validated\n", .{});
    log.info("Framebuffer address: 0x{X}", .{boot_info.framebuffer.base_address});
    log.info("Resolution: {d}x{d}", .{ boot_info.framebuffer.width, boot_info.framebuffer.height });
    log.info("Memory regions: {d}", .{boot_info.memory_map_entries});
    log.info("RSDP: 0x{X}", .{boot_info.rsdp_address});

    const fb_base = if (boot_info.framebuffer.base_address == 0)
        0
    else if (boot_info.framebuffer.base_address >= boot_info.hhdm_base)
        boot_info.framebuffer.base_address
    else
        arch.physToVirt(boot_info.framebuffer.base_address);

    fb_global = @import("framebuffer.zig").Framebuffer.init_framebuffer(
        fb_base,
        boot_info.framebuffer.width,
        boot_info.framebuffer.height,
        boot_info.framebuffer.pitch,
        boot_info.framebuffer.pixel_format,
    );
    fb_global.clear_screen(0x10, 0x20, 0x40);
    fb_global.fill_rect(0, 0, fb_global.width, 4, 0xFF, 0xFF, 0xFF);
    fb_global.fill_rect(0, fb_global.height - 4, fb_global.width, 4, 0xFF, 0xFF, 0xFF);
    fb_global.fill_rect(0, 0, 4, fb_global.height, 0xFF, 0xFF, 0xFF);
    fb_global.fill_rect(fb_global.width - 4, 0, 4, fb_global.height, 0xFF, 0xFF, 0xFF);
    fb_global.fill_rect(0, 0, fb_global.width, 32, 0x30, 0x50, 0x80);
    fb_global.draw_string(16, 10, "Zig Kernel v0.1 - Booted successfully!", 0xFF, 0xFF, 0xFF);
    fb_global.draw_string(16, 50, "Boot info received from bootloader:", 0xC0, 0xC0, 0xC0);
    const y: u32 = 100;
    fb_global.fill_rect(16, y, 100, 40, 0xFF, 0x00, 0x00);
    fb_global.draw_string(20, y + 16, "RED", 0xFF, 0xFF, 0xFF);
    fb_global.fill_rect(136, y, 100, 40, 0x00, 0xFF, 0x00);
    fb_global.draw_string(140, y + 16, "GREEN", 0x00, 0x00, 0x00);
    fb_global.fill_rect(256, y, 100, 40, 0x00, 0x00, 0xFF);
    fb_global.draw_string(260, y + 16, "BLUE", 0xFF, 0xFF, 0xFF);
    log.info("Framebuffer initialization succeeded", .{});

    console.init(&fb_global);
    log.setWriter(console.combinedWrite);

    pmm_global.init(boot_info);
    log.info("Frame allocator initialized", .{});
    vmm_mapper_global = arch.vmm.X64Mapper.init(&pmm_global, boot_info.hhdm_base);
    log.info("Virtual memory mapper initialized", .{});

    const heap_base: u64 = 0xffff_c000_0000_0000;
    const heap_size: u64 = 1024 * 1024 * 1024;
    kheap_global.init(
        vmm_mapper_global.mapper(),
        heap_base,
        heap_size,
    );
    log.info("Kernel heap initialized", .{});

    mm.address_space.init(vmm_mapper_global.mapper());
    log.info("Address space initialized", .{});

    mm.debug.heap_stress_test(&kheap_global);

    const allocator = kheap_global.allocator();
    ipc.init(allocator);
    shm.init(allocator);
    process.init(allocator);

    var smp_service: arch.smp.Service = undefined;

    log.info("Initializing SMP", .{});

    smp_service.init(allocator, boot_info) catch |err| {
        log.err("SMP initialization failed: {any}", .{err});
        @panic("Cannot continue without SMP");
    };
    log.setCpuId(arch.getCpuId);

    const cpu_count = smp_service.getCpuCount();

    sched.init(allocator, cpu_count) catch |err| {
        log.err("Scheduler init failed: {any}", .{err});
        @panic("Scheduler init failed");
    };

    const idt_hooks: arch.idt.IDTHooks = .{
        .tick = sched.tick,
        .needs_resched = sched.needsResched,
        .schedule = sched.schedule,
        .request_resched = sched.requestResched,
        .keyboard = keyboard.handleIrq,
        .user_exception = sched.onUserException,
    };

    arch.idt.installHooks(idt_hooks);

    arch.idt.init();
    arch.ioapic.init(boot_info.rsdp_address);

    keyboard.init();

    const bsp_apic_id: u8 = @truncate(arch.percpu.getPerCpu().apic_id);
    arch.ioapic.routeIrq(1, arch.idt.KEYBOARD_VECTOR, bsp_apic_id);

    if (boot_info.initrd_addr == 0 or boot_info.initrd_size == 0) {
        log.err("initrd missing from boot info", .{});
        @panic("initrd missing");
    }

    const initrd_size: usize = std.math.cast(usize, boot_info.initrd_size) orelse {
        log.err("initrd size too large for this build: {d}", .{boot_info.initrd_size});
        @panic("initrd size invalid");
    };
    const initrd_addr = if (boot_info.initrd_addr >= boot_info.hhdm_base)
        boot_info.initrd_addr
    else
        arch.physToVirt(boot_info.initrd_addr);

    initrd_boot.setInitrd(@ptrFromInt(initrd_addr), initrd_size);
    _ = initrd_boot.bootstrap(allocator) catch |err| {
        log.err("initrd bootstrap failed: {any}", .{err});
        @panic("initrd bootstrap failed");
    };
    _ = initrd_boot.bootstrapShell(allocator) catch |err| {
        log.err("shell bootstrap failed: {any}", .{err});
        @panic("shell bootstrap failed");
    };

    arch.timer.calibrate();
    smp_service.bootAps(allocator) catch |err| {
        log.err("AP boot failed: {any}", .{err});
    };
    sched.startOnBsp() catch |err| {
        log.err("Scheduler BSP start failed: {any}", .{err});
        @panic("Scheduler BSP start failed");
    };

    arch.enableInterrupts();

    const online_count = smp_service.cpu_mgr.online_count.load(.acquire);
    log.info("SMP initialized: {} CPUs discovered, {} online", .{ cpu_count, online_count });
    const current_cpu_id = smp_service.getCurrentCpuId();
    log.info("Running on CPU {}", .{current_cpu_id});

    log.info("\nKernel initialization complete. Idling.\n", .{});
    while (true) {
        arch.sched.haltUntilInterrupt();
    }
}

// Panic handler for Zig runtime
pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    arch.serial.write("KERNEL PANIC: ");
    arch.serial.write(msg);
    arch.serial.write("\n");
    arch.hcf();
}
