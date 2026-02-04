const std = @import("std");
const mm = @import("mm");
const pmm = mm.pmm;
const vmm = mm.vmm;

// =================================
// x86_64 PTE bits (internal to arch)
// =================================
const PTE_PRESENT: u64 = 1 << 0;
const PTE_WRITABLE: u64 = 1 << 1;
const PTE_USER: u64 = 1 << 2;
const PTE_WRITE_THROUGH: u64 = 1 << 3;
const PTE_CACHE_DISABLE: u64 = 1 << 4;
const PTE_ACCESSED: u64 = 1 << 5;
const PTE_DIRTY: u64 = 1 << 6;
const PTE_HUGE: u64 = 1 << 7;
const PTE_GLOBAL: u64 = 1 << 8;
const PTE_PAT: u64 = 1 << 11;
const PTE_NX: u64 = 1 << 63;
const PTE_ADDR_MASK: u64 = 0x000f_ffff_ffff_f000;

/// Translate arch-agnostic MapFlags to x86_64 PTE bits
fn flagsToPte(flags: vmm.MapFlags) u64 {
    var pte: u64 = PTE_PRESENT;

    if (flags.writable) pte |= PTE_WRITABLE;
    if (flags.user) pte |= PTE_USER;
    if (!flags.executable) pte |= PTE_NX;
    if (flags.global) pte |= PTE_GLOBAL;
    if (flags.write_through) pte |= PTE_WRITE_THROUGH;
    if (flags.cache_disable) pte |= PTE_CACHE_DISABLE;

    return pte;
}

inline fn ptePhys(e: u64) u64 {
    return e & PTE_ADDR_MASK;
}

fn assertCanonical(va: u64) void {
    const top = va >> 48;
    if (top != 0 and top != 0xffff) @panic("non-canonical virtual address");
}

fn readCr3() u64 {
    var cr3: u64 = 0;
    asm volatile ("mov %%cr3, %[x]"
        : [x] "=r" (cr3),
    );
    return cr3;
}

fn invlpg(addr: u64) void {
    asm volatile (
        \\mov %[addr], %%rax
        \\invlpg (%%rax)
        :
        : [addr] "r" (addr),
        : .{ .memory = true, .rax = true });
}

fn tableVirt(hhdm_base: u64, table_phys: u64) [*]volatile u64 {
    const v = hhdm_base + table_phys;
    return @ptrFromInt(@as(usize, @intCast(v)));
}

fn ensureTable(ctx: *X64Mapper, entry: *volatile u64) u64 {
    if ((entry.* & PTE_PRESENT) != 0) return ptePhys(entry.*);

    const new_phys = ctx.fa.allocFrame() orelse @panic("out of frames for page tables");

    const new_virt = ctx.hhdm_base + new_phys;
    const ptr: [*]u64 = @ptrFromInt(@as(usize, @intCast(new_virt)));
    @memset(ptr[0..512], 0);

    entry.* = (new_phys & PTE_ADDR_MASK) | PTE_PRESENT | PTE_WRITABLE;
    return new_phys;
}

// =================================
// x86_64 Mapper Context
// =================================

/// Alias for cross-arch compatibility
pub const X64Mapper = struct {
    hhdm_base: u64,
    fa: *pmm.FrameAllocator,

    pub fn init(frame_allocator: *pmm.FrameAllocator, hhdm_base: u64) X64Mapper {
        return .{
            .fa = frame_allocator,
            .hhdm_base = hhdm_base,
        };
    }

    /// Create a vmm.Mapper interface from this context
    pub fn mapper(self: *X64Mapper) vmm.Mapper {
        return vmm.Mapper{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    const vtable = vmm.Mapper.VTable{
        .map4k = map4kImpl,
        .unmap4k = unmap4kImpl,
        .alloc_frame = allocFrameImpl,
        .free_frame = freeFrameImpl,
    };

    fn map4kImpl(ptr: *anyopaque, virt: u64, phys_addr: u64, flags: vmm.MapFlags) void {
        const self: *X64Mapper = @ptrCast(@alignCast(ptr));
        std.debug.assert(std.mem.isAligned(virt, std.options.page_size_min.?));
        std.debug.assert(std.mem.isAligned(phys_addr, std.options.page_size_min.?));
        assertCanonical(virt);

        const pte_flags = flagsToPte(flags);

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

        pt[pt_i] = (phys_addr & PTE_ADDR_MASK) | pte_flags;
        invlpg(virt);
    }

    fn unmap4kImpl(ptr: *anyopaque, virt: u64) ?u64 {
        const self: *X64Mapper = @ptrCast(@alignCast(ptr));
        std.debug.assert(std.mem.isAligned(virt, std.options.page_size_min.?));
        assertCanonical(virt);

        const slot = pteSlot(self, virt) orelse return null;
        const old = slot.*;

        if ((old & PTE_PRESENT) == 0) return null;

        const old_phys = ptePhys(old);
        slot.* = 0;
        invlpg(virt);

        return old_phys;
    }

    fn allocFrameImpl(ptr: *anyopaque) ?u64 {
        const self: *X64Mapper = @ptrCast(@alignCast(ptr));
        return self.fa.allocFrame();
    }

    fn freeFrameImpl(ptr: *anyopaque, phys: u64) void {
        const self: *X64Mapper = @ptrCast(@alignCast(ptr));
        self.fa.freeFrame(phys);
    }

    fn pteSlot(self: *X64Mapper, virt: u64) ?*volatile u64 {
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
};
