const std = @import("std");
const mm = @import("mm");
const elf = std.elf;
const Ehdr = std.elf.Elf64.Ehdr;
const Phdr = std.elf.Elf64.Phdr;

const PAGE_SIZE = mm.PAGE_SIZE;

pub const LoadedElf = struct {
    entry: u64,
};

pub fn loadIntoAddressSpace(as: *mm.address_space.AddressSpace, image: []const u8) !LoadedElf {
    if (image.len < @sizeOf(Ehdr)) return error.InvalidElf;

    const hdr = std.mem.bytesToValue(Ehdr, image[0..@sizeOf(Ehdr)]);
    if (hdr.ident[0] != 0x7f or hdr.ident[3] != 'F') {
        return error.InvalidElf;
    }

    if (hdr.ident[4] != 2 or hdr.ident[5] != 1) return error.UnsupportedElf;

    const phoff: usize = std.math.cast(usize, hdr.phoff) orelse return error.InvalidElf;
    const phentsize: usize = hdr.phentsize;
    const phnum: usize = hdr.phnum;

    if (phentsize < @sizeOf(Phdr)) return error.InvalidElf;

    var i: usize = 0;
    while (i < phnum) : (i += 1) {
        const off = phoff + i * phentsize;
        if (off + @sizeOf(Phdr) > image.len) return error.InvalidElf;

        const ph = std.mem.bytesToValue(Phdr, image[off .. off + @sizeOf(Phdr)]);
        if (ph.type != .LOAD or ph.memsz == 0) continue;

        const seg_start = std.mem.alignBackward(u64, ph.vaddr, PAGE_SIZE);
        const seg_end = std.mem.alignForward(u64, ph.vaddr + ph.memsz, PAGE_SIZE);
        const page_count_u64 = (seg_end - seg_start) / PAGE_SIZE;
        const page_count: usize = std.math.cast(usize, page_count_u64) orelse return error.OutOfMemory;

        var flags = mm.vmm.MapFlags{ .user = true };
        flags.writable = ph.flags.W;
        flags.executable = ph.flags.X;

        try as.mapAnonymous(seg_start, page_count, flags);

        const file_off: usize = std.math.cast(usize, ph.offset) orelse return error.InvalidElf;
        const file_size: usize = std.math.cast(usize, ph.filesz) orelse return error.InvalidElf;
        const mem_size: usize = std.math.cast(usize, ph.memsz) orelse return error.InvalidElf;

        if (file_off + file_size > image.len or file_size > mem_size) return error.InvalidElf;

        as.activate();
        defer mm.address_space.activateKernel();

        const dst: [*]u8 = @ptrFromInt(@as(usize, @intCast(ph.vaddr)));
        @memcpy(dst[0..file_size], image[file_off .. file_off + file_size]);
        @memset(dst[file_size..mem_size], 0);
    }
    return .{ .entry = hdr.entry };
}
