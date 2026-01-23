// UEFI Bootloader

const std = @import("std");
const uefi = std.os.uefi;

const BootServices = uefi.tables.BootServices;
const MemoryDescriptor = uefi.tables.MemoryDescriptor;

const boot_info = @import("boot_info.zig");
const console = @import("console.zig");
const graphics = @import("graphics.zig");
const filesystem = @import("filesystem.zig");
const loader = @import("loader.zig");
const memory = @import("memory.zig");
const paging = @import("paging.zig");
const acpi = @import("acpi.zig");

pub const BootInfo = boot_info.BootInfo;
pub const FramebufferInfo = boot_info.FramebufferInfo;
pub const MemoryRegion = boot_info.MemoryRegion;
pub const MemoryKind = boot_info.MemoryKind;
pub const PixelFormat = boot_info.PixelFormat;
pub const BOOT_MAGIC = boot_info.BOOT_MAGIC;

const L = std.unicode.utf8ToUtf16LeStringLiteral;
const KERNEL_PATH = L("\\efi\\ZincOS");

var boot_services: *BootServices = undefined;

pub fn main() noreturn {
    const con_out = uefi.system_table.con_out orelse halt();
    boot_services = uefi.system_table.boot_services orelse halt();
    console.init(con_out);

    console.clear();
    console.println("==========================================");
    console.println("     ZincOS UEFI Bootloader v0.3.0");
    console.println("     For custom kernels, by custom people");
    console.println("=========================================");
    console.println("\r\n");

    var framebuffer: FramebufferInfo = undefined;
    if (graphics.setup(boot_services)) |fb_info| {
        framebuffer = fb_info;
    } else |_| {
        console.println("[!] Graphics setup failed, continuing without framebuffer");
        framebuffer = std.mem.zeroes(boot_info.FramebufferInfo);
    }

    const rsdp_address = acpi.find_rsdp() orelse 0;

    const root = filesystem.open_volume(boot_services) catch {
        console.println("[!] FATAL: Cannot open boot volume");
        halt();
    };

    const kernel_data = filesystem.load_file(boot_services, root, KERNEL_PATH) catch {
        console.println("[!] FATAL: Cannot load kernel");
        console.println("[!] Expected at: \\efi\\ZincOS");
        halt();
    };

    const load_result = loader.load(boot_services, kernel_data) catch {
        console.println("[!] FATAL: Invalid kernel ELF");
        halt();
    };

    const max_phys_end = paging.get_max_physical_address(boot_services) catch {
        console.println("[!] FATAL: Cannot read memory map for paging");
        halt();
    };

    const pml4 = paging.build_page_tables(boot_services, load_result.segments, max_phys_end) catch {
        console.println("[!] FATAL: Cannot build page tables");
        halt();
    };

    memory.process_memory_map(boot_services) catch {
        console.println("[!] FATAL: Cannot get memory map");
        halt();
    };

    // Allocate persistent pages for memory map (bootloader's static array will be reclaimed!)
    const regions = memory.get_regions();
    const memory_map_entries = memory.get_region_count();
    const regions_size = memory_map_entries * @sizeOf(MemoryRegion);
    const regions_pages = (regions_size + 0xfff) / 0x1000;

    const mmap_page = boot_services.allocatePages(
        .any,
        .loader_data,
        @intCast(if (regions_pages == 0) 1 else regions_pages),
    ) catch halt();

    const mmap_dest: [*]MemoryRegion = @ptrCast(@alignCast(mmap_page.ptr));
    @memcpy(mmap_dest[0..memory_map_entries], regions);

    const memory_map_addr = @intFromPtr(mmap_dest);

    // console.printfln(
    //     "[+] Boot info prepared at 0x{x}",
    //     .{@intFromPtr(&kernel_boot_info)},
    // );
    console.printfln(
        "[*] Jumping to kernel entry at 0x{x}",
        .{load_result.entry_point},
    );

    // -------------------------------------------------------------------------
    // Allocate BootInfo in *physical* memory
    // -------------------------------------------------------------------------
    const bootinfo_page = boot_services.allocatePages(
        .any,
        .loader_data,
        1,
    ) catch halt();

    const bootinfo_phys: u64 = @intFromPtr(bootinfo_page.ptr);

    const bootinfo: *boot_info.BootInfo =
        @ptrFromInt(@as(usize, @intCast(bootinfo_phys)));

    bootinfo.* = .{
        .framebuffer = framebuffer,
        .kernel_physical_base = load_result.physical_base,
        .kernel_size = load_result.size,
        .kernel_virtual_base = load_result.virtual_base,
        .magic = BOOT_MAGIC,
        .memory_map_addr = memory_map_addr,
        .memory_map_entries = memory_map_entries,
        .rsdp_address = rsdp_address,
        .hhdm_base = paging.HHDM_BASE,
    };

    exit_boot_services_and_jump(load_result.entry_point, pml4, bootinfo_phys + paging.HHDM_BASE);
}

fn exit_boot_services_and_jump(entry_point: u64, pml4: *paging.PageTable, bootinfo_hhdm: u64) noreturn {
    console.println("[*] Preparing to exit boot services...");

    const mmap_info = boot_services.getMemoryMapInfo() catch {
        console.println("[!] Failed to get final memory map info");
        halt();
    };
    const buffer_size = (mmap_info.len + 8) * mmap_info.descriptor_size;
    const mmap_buffer = boot_services.allocatePool(
        .loader_data,
        buffer_size,
    ) catch {
        console.println("[!] Failed to allocate final memory map buffer");
        halt();
    };

    const aligned_buffer: []align(@alignOf(MemoryDescriptor)) u8 = @alignCast(mmap_buffer);

    var mmap_slice = boot_services.getMemoryMap(aligned_buffer) catch {
        console.println("[!] Failed to get final memory map");
        halt();
    };

    console.println("[*] Exiting boot services");

    boot_services.exitBootServices(uefi.handle, mmap_slice.info.key) catch {
        mmap_slice = boot_services.getMemoryMap(aligned_buffer) catch halt();
        boot_services.exitBootServices(uefi.handle, mmap_slice.info.key) catch halt();
    };

    paging.switch_to(pml4);

    const kernel_entry: *const fn (*boot_info.BootInfo) callconv(.{ .x86_64_sysv = .{} }) noreturn =
        @ptrFromInt(entry_point);
    const bootinfo_ptr: *BootInfo = @ptrFromInt(@as(usize, @intCast(bootinfo_hhdm)));
    kernel_entry(bootinfo_ptr);

    unreachable;
}

fn halt() noreturn {
    console.println("\r\n[!] System halted. Press reset to reboot.");
    while (true) {
        asm volatile ("hlt");
    }
}
