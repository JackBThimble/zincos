const std = @import("std");
const uefi = std.os.uefi;

const BootServices = uefi.tables.BootServices;
const MemoryDescriptor = uefi.tables.MemoryDescriptor;

const console = @import("console.zig");
const loader = @import("loader.zig");

pub const HHDM_BASE: u64 = 0xffff_8000_0000_0000;

pub const PagingError = error{
    GetMapInfoFailed,
    GetMapFailed,
    OutOfMemory,
    MapFailed,
};

pub const PageTable = [512]u64;

const PAGE_SIZE: u64 = 0x1000;
const PAGE_SIZE_2M: u64 = 0x200000;

const FLAG_PRESENT: u64 = 1 << 0;
const FLAG_WRITE: u64 = 1 << 1;
const FLAG_LARGE: u64 = 1 << 7;

const ADDR_MASK_4K: u64 = 0x000f_ffff_ffff_f000;

fn align_down(addr: u64, alignment: u64) u64 {
    return addr & ~(alignment - 1);
}

fn align_up(addr: u64, alignment: u64) u64 {
    return (addr + alignment - 1) & ~(alignment - 1);
}

fn make_entry(addr: u64, flags: u64) u64 {
    return (addr & ADDR_MASK_4K) | flags;
}

fn alloc_table(boot_services: *BootServices) PagingError!*PageTable {
    const page = boot_services.allocatePages(.any, .loader_data, 1) catch {
        console.println("[!] Failed to allocate page table");
        return PagingError.OutOfMemory;
    };

    const table: *PageTable = @ptrCast(@alignCast(page.ptr));
    const bytes: []u8 = @as([*]u8, @ptrCast(table))[0..@sizeOf(PageTable)];
    @memset(bytes, 0);
    return table;
}

fn get_or_alloc_table(boot_services: *BootServices, entry: *u64) PagingError!*PageTable {
    if ((entry.* & FLAG_PRESENT) != 0) {
        return @ptrFromInt(entry.* & ADDR_MASK_4K);
    }

    const table = try alloc_table(boot_services);
    entry.* = make_entry(@intFromPtr(table), FLAG_PRESENT | FLAG_WRITE);
    return table;
}

fn pml4_index(addr: u64) usize {
    return @intCast((addr >> 39) & 0x1ff);
}

fn pdpt_index(addr: u64) usize {
    return @intCast((addr >> 30) & 0x1ff);
}

fn pd_index(addr: u64) usize {
    return @intCast((addr >> 21) & 0x1ff);
}

fn pt_index(addr: u64) usize {
    return @intCast((addr >> 12) & 0x1ff);
}

fn map_2m(
    boot_services: *BootServices,
    pml4: *PageTable,
    virt: u64,
    phys: u64,
) PagingError!void {
    const pdpt = try get_or_alloc_table(boot_services, &pml4[pml4_index(virt)]);
    const pd = try get_or_alloc_table(boot_services, &pdpt[pdpt_index(virt)]);
    const entry_addr = align_down(phys, PAGE_SIZE_2M);
    pd[pd_index(virt)] = make_entry(entry_addr, FLAG_PRESENT | FLAG_WRITE | FLAG_LARGE);
}

fn map_4k(
    boot_services: *BootServices,
    pml4: *PageTable,
    virt: u64,
    phys: u64,
) PagingError!void {
    const pdpt = try get_or_alloc_table(boot_services, &pml4[pml4_index(virt)]);
    const pd = try get_or_alloc_table(boot_services, &pdpt[pdpt_index(virt)]);
    const pd_entry = &pd[pd_index(virt)];

    var pt: *PageTable = undefined;
    if ((pd_entry.* & FLAG_PRESENT) == 0) {
        pt = try alloc_table(boot_services);
        pd_entry.* = make_entry(@intFromPtr(pt), FLAG_PRESENT | FLAG_WRITE);
    } else {
        if ((pd_entry.* & FLAG_LARGE) != 0) {
            const region_phys = pd_entry.* & ADDR_MASK_4K;
            const split_pt = try alloc_table(boot_services);
            var i: usize = 0;
            while (i < 512) : (i += 1) {
                const page_phys = region_phys + @as(u64, i) * PAGE_SIZE;
                split_pt[i] = make_entry(page_phys, FLAG_PRESENT | FLAG_WRITE);
            }
            pd_entry.* = make_entry(@intFromPtr(split_pt), FLAG_PRESENT | FLAG_WRITE);
            pt = split_pt;
        } else {
            pt = @ptrFromInt(pd_entry.* & ADDR_MASK_4K);
        }
    }

    pt[pt_index(virt)] = make_entry(align_down(phys, PAGE_SIZE), FLAG_PRESENT | FLAG_WRITE);
}

pub fn get_max_physical_address(boot_services: *BootServices) PagingError!u64 {
    const mmap_info = boot_services.getMemoryMapInfo() catch {
        console.println("[!] Failed to get memory map info");
        return PagingError.GetMapInfoFailed;
    };

    const buffer_size = (mmap_info.len + 4) * mmap_info.descriptor_size;
    const mmap_buffer = boot_services.allocatePool(
        .loader_data,
        buffer_size,
    ) catch {
        console.println("[!] Failed to allocate memory map buffer");
        return PagingError.OutOfMemory;
    };

    const aligned_buffer: []align(@alignOf(MemoryDescriptor)) u8 =
        @alignCast(mmap_buffer);
    const mmap_slice = boot_services.getMemoryMap(aligned_buffer) catch {
        console.println("[!] Failed to get memory map");
        return PagingError.GetMapFailed;
    };

    var max_end: u64 = 0;
    var iter = mmap_slice.iterator();
    while (iter.next()) |desc| {
        const end = desc.physical_start + desc.number_of_pages * PAGE_SIZE;
        if (end > max_end) max_end = end;
    }

    return max_end;
}

pub fn build_page_tables(
    boot_services: *BootServices,
    segments: []const loader.LoadedSegment,
    max_phys_end: u64,
) PagingError!*PageTable {
    console.println("[*] Building page tables...");

    const pml4 = try alloc_table(boot_services);

    const identity_end = align_up(max_phys_end, PAGE_SIZE_2M);
    var addr: u64 = 0;
    while (addr < identity_end) : (addr += PAGE_SIZE_2M) {
        try map_2m(boot_services, pml4, addr, addr);
    }

    // HHDM map [0, max_phys_end] at HHDM_BASE
    addr = 0;
    while (addr < identity_end) : (addr += PAGE_SIZE_2M) {
        try map_2m(boot_services, pml4, HHDM_BASE + addr, addr);
    }

    for (segments) |seg| {
        if (seg.vaddr == seg.paddr) {
            continue;
        }

        const vaddr_i: i128 = @as(i128, @intCast(seg.vaddr));
        const paddr_i: i128 = @as(i128, @intCast(seg.paddr));
        const offset: i128 = vaddr_i - paddr_i;
        const end = align_up(seg.vaddr + seg.memsz, PAGE_SIZE);
        var vaddr = align_down(seg.vaddr, PAGE_SIZE);
        while (vaddr < end) : (vaddr += PAGE_SIZE) {
            const paddr_i2: i128 = @as(i128, @intCast(vaddr)) - offset;
            if (paddr_i2 < 0 or paddr_i2 > std.math.maxInt(u64)) {
                console.println("[!] Segment mapping overflow");
                return PagingError.MapFailed;
            }
            const paddr: u64 = @intCast(paddr_i2);
            try map_4k(boot_services, pml4, vaddr, paddr);
        }
    }

    console.println("[+] Page tables ready");
    return pml4;
}

fn enable_large_pages() void {
    var cr4: u64 = 0;
    asm volatile (
        \\ mov %%cr4, %[out]
        : [out] "=r" (cr4),
    );
    cr4 |= 1 << 4;
    asm volatile (
        \\ mov %[in], %%cr4
        :
        : [in] "r" (cr4),
        : "memory");
}

pub fn switch_to(pml4: *PageTable) void {
    enable_large_pages();
    const pml4_phys = @intFromPtr(pml4);
    asm volatile (
        \\ mov %[in], %%cr3
        :
        : [in] "r" (pml4_phys),
        : "memory");
}
