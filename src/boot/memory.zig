const std = @import("std");
const uefi = std.os.uefi;
const BootServices = uefi.tables.BootServices;
const MemoryDescriptor = uefi.tables.MemoryDescriptor;

const console = @import("console.zig");
const boot_info = @import("shared").boot;

pub const MemoryError = error{
    GetMapInfoFailed,
    OutOfMemory,
    GetMapFailed,
};

var memory_regions: [boot_info.MAX_MEMORY_REGIONS]boot_info.MemoryRegion = undefined;
var memory_region_count: usize = 0;

pub fn get_regions() []boot_info.MemoryRegion {
    return memory_regions[0..memory_region_count];
}

pub fn get_region_count() usize {
    return memory_region_count;
}

pub fn process_memory_map(boot_services: *BootServices) MemoryError!void {
    console.println("[*] Retrieving UEFI memory map...");

    const mmap_info = boot_services.getMemoryMapInfo() catch {
        console.println("[!] Failed to get memory map info");
        return MemoryError.GetMapInfoFailed;
    };

    const buffer_size = (mmap_info.len + 4) * mmap_info.descriptor_size;
    const mmap_buffer = boot_services.allocatePool(
        .loader_data,
        buffer_size,
    ) catch {
        console.println("[!] Failed to allocate memory map buffer");
        return MemoryError.GetMapFailed;
    };

    const aligned_buffer: []align(@alignOf(MemoryDescriptor)) u8 =
        @alignCast(mmap_buffer);
    const mmap_slice = boot_services.getMemoryMap(aligned_buffer) catch {
        console.println("[!] Failed to get memory map");
        return MemoryError.GetMapFailed;
    };

    console.printfln("[*] Memory map entries: {d}", .{mmap_slice.info.len});

    memory_region_count = 0;
    var iter = mmap_slice.iterator();
    while (iter.next()) |desc| {
        if (memory_region_count >= boot_info.MAX_MEMORY_REGIONS) break;

        const kind: boot_info.MemoryKind = switch (desc.type) {
            .conventional_memory, .boot_services_code, .boot_services_data => .usable,
            .loader_code, .loader_data => .bootloader_reclaimable,
            .acpi_memory_nvs => .acpi_nvs,
            .unusable_memory => .bad_memory,
            else => .reserved,
        };

        memory_regions[memory_region_count] = .{
            .base = desc.physical_start,
            .length = desc.number_of_pages * 0x1000,
            .kind = kind,
            ._reserved0 = 0,
            ._reserved1 = 0,
            ._reserved2 = 0,
            ._padding = 0,
        };
        memory_region_count += 1;
    }

    console.printfln("[+] Processed {d} memory regions", .{memory_region_count});
}
