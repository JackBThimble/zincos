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
const sched = @import("sched/core.zig");
const ipc = @import("ipc/mod.zig");
const process = @import("process/mod.zig");
const shm = @import("shm.zig");
const syscall_dispatch = @import("syscall_dispatch.zig");

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
    log.setWriter(arch.serial.write);
    log.setTscFn(arch.rdtsc);
    // Initialize serial for debug output
    if (boot_info.magic != shared.boot.BOOT_MAGIC) {
        log.err("ERROR: Invalid boot magic!\n", .{});
        arch.hcf();
    }
    log.info("Boot magic validated\n", .{});
    log.info("Framebuffer address: 0x{X}", .{boot_info.framebuffer.base_address});
    log.info("Resolution: {d}x{d}", .{ boot_info.framebuffer.width, boot_info.framebuffer.height });
    log.info("Memory regions: {d}", .{boot_info.memory_map_entries});
    log.info("RSDP: 0x{X}", .{boot_info.rsdp_address});
    var fb = @import("framebuffer.zig").Framebuffer.init_framebuffer(boot_info.framebuffer.base_address, boot_info.framebuffer.width, boot_info.framebuffer.height, boot_info.framebuffer.pitch, boot_info.framebuffer.pixel_format);
    fb.clear_screen(0x10, 0x20, 0x40);
    fb.fill_rect(0, 0, fb.width, 4, 0xFF, 0xFF, 0xFF);
    fb.fill_rect(0, fb.height - 4, fb.width, 4, 0xFF, 0xFF, 0xFF);
    fb.fill_rect(0, 0, 4, fb.height, 0xFF, 0xFF, 0xFF);
    fb.fill_rect(fb.width - 4, 0, 4, fb.height, 0xFF, 0xFF, 0xFF);
    fb.fill_rect(0, 0, fb.width, 32, 0x30, 0x50, 0x80);
    fb.draw_string(16, 10, "Zig Kernel v0.1 - Booted successfully!", 0xFF, 0xFF, 0xFF);
    fb.draw_string(16, 50, "Boot info received from bootloader:", 0xC0, 0xC0, 0xC0);
    const y: u32 = 100;
    fb.fill_rect(16, y, 100, 40, 0xFF, 0x00, 0x00);
    fb.draw_string(20, y + 16, "RED", 0xFF, 0xFF, 0xFF);
    fb.fill_rect(136, y, 100, 40, 0x00, 0xFF, 0x00);
    fb.draw_string(140, y + 16, "GREEN", 0x00, 0x00, 0x00);
    fb.fill_rect(256, y, 100, 40, 0x00, 0x00, 0xFF);
    fb.draw_string(260, y + 16, "BLUE", 0xFF, 0xFF, 0xFF);
    log.info("Framebuffer initialization succeeded", .{});

    arch.initHhdm(boot_info.hhdm_base);

    pmm_global.init(boot_info);
    log.info("Frame allocator initialized", .{});
    vmm_mapper_global = arch.vmm.X64Mapper.init(&pmm_global, boot_info.hhdm_base);
    log.info("Virtual memory mapper intialized", .{});

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

    const cpu_count = smp_service.getCpuCount();

    sched.init(allocator, cpu_count) catch |err| {
        log.err("Scheduler init failed: {any}", .{err});
        @panic("Scheduler init failed");
    };

    arch.idt.installSchedHooks(
        sched.tick,
        sched.needsResched,
        sched.schedule,
        sched.requestResched,
        sched.onUserException,
    );
    arch.idt.init();

    // Spawn test userspace only after IDT is live so faults are diagnosable.
    @import("user.zig").spawnDemoUserProcess(allocator) catch |err| {
        log.err("User process error: {any}", .{err});
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
