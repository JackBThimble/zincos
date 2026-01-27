const std = @import("std");

const pmm = @import("pmm.zig");

pub const PAGE_SIZE = pmm.PAGE_SIZE;

// =================================
// Page Table Entry Flags
// =================================
pub const PTE_PRESENT = @as(u64, 1) << 0;
pub const PTE_WRITABLE = @as(u64, 1) << 1;
pub const PTE_USER = @as(u64, 1) << 2;
pub const PTE_WRITE_THROUGH = @as(u64, 1) << 3;
pub const PTE_CACHE_DISABLE = @as(u64, 1) << 4;
pub const PTE_ACCESSED = @as(u64, 1) << 5;
pub const PTE_DIRTY = @as(u64, 1) << 6;
pub const PTE_HUGE = @as(u64, 1) << 7; // for PD/PT entries
pub const PTE_GLOBAL = @as(u64, 1) << 8;
pub const PTE_PAT = @as(u64, 1) << 11;
pub const PTE_NX = @as(u64, 1) << 63;

// mask for physical address
pub const PTE_ADDR_MASK = 0x000f_ffff_ffff_f000;

inline fn ptePhys(e: u64) u64 {
    return e & PTE_ADDR_MASK;
}

// =================================
// Mapper
// =================================

pub const Mapper = struct {
    hhdm_base: u64,
    fa: *pmm.FrameAllocator,

    // -------------------------
    // Map one 4K page
    // -------------------------
    pub fn map4k(self: *Mapper, virt: u64, phys_addr: u64, flags: u64) void {
        std.debug.assert((virt & (PAGE_SIZE - 1)) == 0);
        std.debug.assert((phys_addr & (PAGE_SIZE - 1)) == 0);
        assertCanonical(virt);

        const pml4_phys = readCr3() & ~@as(u64, 0xfff);
        const pml4 = tableVirt(self.hhdm_base, pml4_phys);

        const pml4_i: usize = @intCast((virt >> 39) & 0x1ff);
        const pdpt_phys = ensureTable(self, &pml4[pml4_i]);

        const pdpt = tableVirt(self.hhdm_base, pdpt_phys);
        const pdpt_i: usize = @intCast((virt >> 30) & 0x1ff);
        const pd_phys = ensureTable(self, &pdpt[pdpt_i]);

        const pd = tableVirt(self.hhdm_base, pd_phys);
        const pd_i: usize = @intCast((virt >> 21) & 0x1ff);
        const pt_phys = ensureTable(self, &pd[pd_i]);

        const pt = tableVirt(self.hhdm_base, pt_phys);
        const pt_i: usize = @intCast((virt >> 12) & 0x1ff);

        pt[pt_i] = (phys_addr & PTE_ADDR_MASK) | flags;
        invlpg(virt);
    }

    // -----------------------------------------
    // Unmap one 4K page
    // returns old phys addr
    // -----------------------------------------
    pub fn unmap4k(self: *Mapper, virt: u64) ?u64 {
        std.debug.assert((virt & (PAGE_SIZE - 1)) == 0);
        assertCanonical(virt);

        const slot = self.pteSlot(virt) orelse return null;
        const old = slot.*;

        if ((old & PTE_PRESENT) == 0) return null;

        const old_phys = ptePhys(old);
        slot.* = 0;
        invlpg(virt);

        return old_phys;
    }

    // -----------------------------------------
    // Walk to PTE slot
    // -----------------------------------------
    fn pteSlot(self: *Mapper, virt: u64) ?*volatile u64 {
        const pml4_phys = readCr3() & ~@as(u64, 0xfff);
        const pml4 = tableVirt(self.hhdm_base, pml4_phys);

        const pml4_i: usize = @intCast((virt >> 39) & 0x1ff);
        const pml4e = pml4[pml4_i];
        if ((pml4e & PTE_PRESENT) == 0) return null;

        const pdpt = tableVirt(self.hhdm_base, ptePhys(pml4e));
        const pdpt_i: usize = @intCast((virt >> 30) & 0x1ff);
        const pdpte = pdpt[pdpt_i];
        if ((pdpte & PTE_PRESENT) == 0) return null;
        if ((pdpte & PTE_HUGE) != 0) return null;

        const pd = tableVirt(self.hhdm_base, ptePhys(pdpte));
        const pd_i: usize = @intCast((virt >> 21) & 0x1ff);
        const pde = pd[pd_i];
        if ((pde & PTE_PRESENT) == 0) return null;
        if ((pde & PTE_HUGE) != 0) return null;

        const pt = tableVirt(self.hhdm_base, ptePhys(pde));
        const pt_i: usize = @intCast((virt >> 12) & 0x1ff);

        return &pt[pt_i];
    }

    fn mapRange4k(self: *Mapper, virt: u64, phys_base: u64, len: u64, flags: u64) void {
        var v = alignDown(virt);
        var p = alignDown(phys_base);
        const end = alignUp(virt + len);

        while (v < end) : ({
            v += pmm.PAGE_SIZE;
            p += pmm.PAGE_SIZE;
        }) {
            self.map4k(v, p, flags);
        }
    }
};

fn ensureTable(self: *Mapper, entry: *volatile u64) u64 {
    if ((entry.* & PTE_PRESENT) != 0) return ptePhys(entry.*);

    const new_phys = self.fa.allocFrame() orelse @panic("out of frames for page tables");

    const new_virt = self.hhdm_base + new_phys;
    const ptr: [*]u64 = @ptrFromInt(@as(usize, @intCast(new_virt)));
    @memset(ptr[0..512], 0);

    entry.* = (new_phys & PTE_ADDR_MASK) | PTE_PRESENT | PTE_WRITABLE;
    return new_phys;
}

fn assertCanonical(va: u64) void {
    const top = va >> 48;
    if (top != 0 and top != 0xffff) @panic("non-canonical virtual address");
}

fn tableVirt(hhdm_base: u64, table_phys: u64) [*]volatile u64 {
    const v = hhdm_base + table_phys;
    return @ptrFromInt(@as(usize, @intCast(v)));
}

fn readCr3() u64 {
    var cr3: u64 = 0;
    asm volatile ("mov %%cr3, %[x]"
        : [x] "=r" (cr3),
        :
        : .{});
    return cr3;
}

fn invlpg(addr: u64) void {
    // const p: *volatile u8 = @ptrFromInt(@as(usize, @intCast(addr)));
    asm volatile (
        \\mov %[addr], %%rax
        \\invlpg (%%rax)
        :
        : [addr] "r" (addr),
        : .{ .memory = true, .rax = true });
}

fn alignDown(x: u64) u64 {
    return x & ~(@as(u64, pmm.PAGE_SIZE - 1));
}
fn alignUp(x: u64) u64 {
    return (x + pmm.PAGE_SIZE - 1) & ~(@as(u64, pmm.PAGE_SIZE - 1));
}
