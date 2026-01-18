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
var kernel_boot_info: boot_info.BootInfo = .{
    .framebuffer = undefined,
    .memory_map_addr = 0,
    .memory_map_entries = 0,
    .kernel_physical_base = 0,
    .kernel_virtual_base = 0,
    .kernel_size = 0,
    .rsdp_address = 0,
};

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

    if (graphics.setup(boot_services)) |fb_info| {
        kernel_boot_info.framebuffer = fb_info;
    } else |_| {
        console.println("[!] Graphics setup failed, continuing without framebuffer");
        kernel_boot_info.framebuffer = std.mem.zeroes(boot_info.FramebufferInfo);
    }

    kernel_boot_info.rsdp_address = acpi.find_rsdp() orelse 0;

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

    kernel_boot_info.kernel_physical_base = load_result.physical_base;
    kernel_boot_info.kernel_virtual_base = load_result.virtual_base;
    kernel_boot_info.kernel_size = load_result.size;

    memory.process_memory_map(boot_services) catch {
        console.println("[!] FATAL: Cannot get memory map");

        halt();
    };

    kernel_boot_info.memory_map_addr = @intFromPtr(memory.get_regions().ptr);
    kernel_boot_info.memory_map_entries = memory.get_region_count();

    console.printfln(
        "[+] Boot info prepared at 0x{x}",
        .{@intFromPtr(&kernel_boot_info)},
    );
    console.printfln(
        "[*] Jumping to kernel entry at 0x{x}",
        .{load_result.entry_point},
    );

    exit_boot_services_and_jump(load_result.entry_point);
}

fn exit_boot_services_and_jump(entry_point: u64) noreturn {
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

    const kernel_entry: *const fn (*boot_info.BootInfo) callconv(.c) noreturn = @ptrFromInt(entry_point);
    kernel_entry(&kernel_boot_info);

    unreachable;
}

fn halt() noreturn {
    console.println("\r\n[!] System halted. Press reset to reboot.");
    while (true) {
        asm volatile ("hlt");
    }
}
