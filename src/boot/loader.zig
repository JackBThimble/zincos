// ELF kernel loader

const std = @import("std");
const elf = std.elf;
const uefi = std.os.uefi;
const BootServices = uefi.tables.BootServices;

const console = @import("console.zig");

pub const LoadError = error{
    InvalidElf,
    Not64Bit,
    NotX86_64,
    NotExecutable,
    OutOfMemory,
    NoLoadableSegments,
    TooManySegments,
};

pub const LoadedSegment = struct {
    vaddr: u64,
    paddr: u64,
    memsz: u64,
};

pub const LoadResult = struct {
    entry_point: u64,
    physical_base: u64,
    virtual_base: u64,
    size: u64,
    segments: []const LoadedSegment,
};

const MAX_SEGMENTS: usize = 16;
var loaded_segments: [MAX_SEGMENTS]LoadedSegment = undefined;

// =============================================================================
// ELF Loading
// =============================================================================

pub fn load(boot_services: *BootServices, elf_data: []const u8) LoadError!LoadResult {
    console.println("[*] Parsing ELF kernel...");

    if (elf_data.len < @sizeOf(std.elf.Elf64.Ehdr)) {
        console.println("[!] File too small for ELF header");
        return LoadError.InvalidElf;
    }

    const header: *const std.elf.Elf64.Ehdr = @ptrCast(@alignCast(elf_data.ptr));

    // // validate elf magic
    // if (!std.mem.eql(u8, &header.ident, &elf.MAGIC)) {
    //     console.println("[!] Invalid ELF Magic");
    //     return LoadError.InvalidElf;
    // }

    if (header.ident[elf.EI.CLASS] != @intFromEnum(elf.CLASS.@"64")) {
        console.println("[!] Not a 64-bit ELF");
        return LoadError.Not64Bit;
    }

    if (header.machine != .X86_64) {
        console.println("[!] Not x86_64 architecture");
        return LoadError.NotX86_64;
    }

    if (header.type != .EXEC and header.type != .DYN) {
        console.println("[!] Not an executable ELF");
        return LoadError.NotExecutable;
    }

    console.printfln("[*] Entry point: 0x{x}", .{header.entry});

    console.printfln("[*] Program headers: {d} at offset 0x{x}", .{
        header.phnum,
        header.phoff,
    });

    var load_base: u64 = std.math.maxInt(u64);
    var load_end: u64 = 0;
    var virt_base: u64 = std.math.maxInt(u64);
    var segments_loaded: usize = 0;

    var i: u16 = 0;
    while (i < header.phnum) : (i += 1) {
        const ph_offset = header.phoff + @as(u64, i) * header.phentsize;
        if (ph_offset + @sizeOf(std.elf.Elf64.Phdr) > elf_data.len) {
            console.println("[!] Program header out of bounds");
            return LoadError.InvalidElf;
        }

        const phdr: *const elf.Elf64.Phdr =
            @ptrCast(@alignCast(elf_data.ptr + ph_offset));

        if (phdr.type != elf.PT.LOAD) continue;

        console.printfln("[*] LOAD segment: vaddr=0x{x} paddr=0x{x} memsz=0x{x}", .{
            phdr.vaddr,
            phdr.paddr,
            phdr.memsz,
        });

        if (segments_loaded >= MAX_SEGMENTS) {
            console.println("[!] Too many loadable segments");
            return LoadError.TooManySegments;
        }

        const mem_type: uefi.tables.MemoryType = if (phdr.flags.X)
            .loader_code
        else
            .loader_data;

        const page_count = (phdr.memsz + 0xfff) / 0x1000;

        const segment_pages = boot_services.allocatePages(
            .any,
            mem_type,
            @intCast(page_count),
        ) catch {
            console.println("[!] Failed to allocate pages");
            return LoadError.OutOfMemory;
        };

        const segment_base: u64 = @intFromPtr(segment_pages.ptr);

        // Zero memory for .bss segment
        const dest: [*]u8 = @ptrFromInt(segment_base);
        @memset(dest[0..@intCast(phdr.memsz)], 0);

        if (phdr.filesz > 0) {
            const src = elf_data.ptr + @as(usize, @intCast(phdr.offset));
            @memcpy(dest[0..@intCast(phdr.filesz)], src[0..@intCast(phdr.filesz)]);
        }

        if (segment_base < load_base) load_base = segment_base;
        if (segment_base + phdr.memsz > load_end) load_end = segment_base + phdr.memsz;
        if (phdr.vaddr < virt_base) virt_base = phdr.vaddr;
        loaded_segments[segments_loaded] = .{
            .vaddr = phdr.vaddr,
            .paddr = segment_base,
            .memsz = phdr.memsz,
        };
        segments_loaded += 1;
    }

    if (segments_loaded == 0) {
        console.println("[!] No loadable segments found");
        return LoadError.NoLoadableSegments;
    }

    console.printfln("[+] Kernel loaded at: 0x{x} - 0x{x}", .{
        load_base,
        load_end,
    });

    return LoadResult{
        .entry_point = header.entry,
        .physical_base = load_base,
        .virtual_base = virt_base,
        .size = load_end - load_base,
        .segments = loaded_segments[0..segments_loaded],
    };
}
