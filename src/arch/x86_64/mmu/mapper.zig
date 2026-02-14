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

/// First PML4 index of the kernel half.
/// 0xffff_8000_0000_0000 >> 39 & 0x1ff = 256
const KERNEL_PML4_START: usize = 256;

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

/// Flags for intermediate (non-leaf) page table entries.
/// Must be permissive because x86_64 ANDs permissions down the hierarchy.
/// Actual access control happens at the leaf PTE.
fn intermediateFlags(flags: vmm.MapFlags) u64 {
    var pte: u64 = PTE_PRESENT | PTE_WRITABLE;
    if (flags.user) pte |= PTE_USER;
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
    asm volatile ("movq %%cr3, %[x]"
        : [x] "=r" (cr3),
    );
    return cr3;
}

fn writeCr3(phys: u64) void {
    asm volatile ("movq %[x], %%cr3"
        :
        : [x] "r" (phys),
        : .{ .memory = true });
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

/// Ensure an intermediate page table entry exists. Allocates and
/// zeroes a new table frame if needed. Sets intermediate PTE flags
/// based on the mapping flags (propagates USER bit for user mappings).
///
/// Returns the physical address of the child table, or null on OOM.
fn ensureTable(fa: *pmm.FrameAllocator, hhdm_base: u64, entry: *volatile u64, flags: vmm.MapFlags) ?u64 {
    if ((entry.* & PTE_PRESENT) != 0) {
        // Entry already exists. If USER bit is needed and missing, upgrade in place.
        // This handles the case where a kernel mapping created the intermediate
        // entry without USER, and now a user mapping needs to share this part of the
        // tree.
        if (flags.user and (entry.* & PTE_USER) == 0) {
            entry.* |= PTE_USER;
        }
        return ptePhys(entry.*);
    }

    const new_phys = fa.allocFrame() orelse return null;

    const new_virt = hhdm_base + new_phys;
    const ptr: [*]u64 = @ptrFromInt(@as(usize, @intCast(new_virt)));
    @memset(ptr[0..512], 0);

    entry.* = (new_phys & PTE_ADDR_MASK) | intermediateFlags(flags);
    return new_phys;
}

/// Walk page tables rooted at an arbitrary PML4 to find a PTE slot.
fn pteSlotIn(hhdm_base: u64, pml4_phys: u64, virt: u64) ?*volatile u64 {
    const pml4 = tableVirt(hhdm_base, pml4_phys);

    const pml4_i: usize = @intCast((virt >> 39) & 0x1ff);
    const pml4e = pml4[pml4_i];
    if ((pml4e & PTE_PRESENT) == 0) return null;

    const pdpt = tableVirt(hhdm_base, ptePhys(pml4e));
    const pdpt_i: usize = @intCast((virt >> 30) & 0x1ff);
    const pdpte = pdpt[pdpt_i];
    if ((pdpte & PTE_PRESENT) == 0) return null;
    if ((pdpte & PTE_HUGE) != 0) return null;

    const pd = tableVirt(hhdm_base, ptePhys(pdpte));
    const pd_i: usize = @intCast((virt >> 21) & 0x1ff);
    const pde = pd[pd_i];
    if ((pde & PTE_PRESENT) == 0) return null;
    if ((pde & PTE_HUGE) != 0) return null;

    const pt = tableVirt(hhdm_base, ptePhys(pde));
    const pt_i: usize = @intCast((virt >> 12) & 0x1ff);

    return &pt[pt_i];
}

// =================================
// x86_64 Mapper Context
// =================================

/// Alias for cross-arch compatibility
pub const X64Mapper = struct {
    hhdm_base: u64,
    fa: *pmm.FrameAllocator,
    kernel_pml4_phys: u64 = 0,

    pub fn init(frame_allocator: *pmm.FrameAllocator, hhdm_base: u64) X64Mapper {
        return .{
            .fa = frame_allocator,
            .hhdm_base = hhdm_base,
            .kernel_pml4_phys = readCr3() & ~@as(u64, 0xfff),
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
        .create_root = createRootImpl,
        .destroy_root = destroyRootImpl,
        .activate = activateImpl,
        .active_root = activeRootImpl,
        .kernel_root = kernelRootImpl,
        .hhdm_base = hhdmBaseImpl,
    };

    /// Map a 4K page in the address space identified by `root`.
    /// Returns false on OOM (couldn't allocate intermediate page tables).
    fn map4kImpl(ptr: *anyopaque, root: u64, virt: u64, phys_addr: u64, flags: vmm.MapFlags) bool {
        const self: *X64Mapper = @ptrCast(@alignCast(ptr));
        std.debug.assert(std.mem.isAligned(virt, std.options.page_size_min.?));
        std.debug.assert(std.mem.isAligned(phys_addr, std.options.page_size_min.?));
        assertCanonical(virt);

        const pte_flags = flagsToPte(flags);
        const pml4 = tableVirt(self.hhdm_base, root);

        const pml4_i: usize = @intCast((virt >> 39) & 0x1ff);
        const pdpt_phys = ensureTable(self.fa, self.hhdm_base, &pml4[pml4_i], flags) orelse return false;

        const pdpt = tableVirt(self.hhdm_base, pdpt_phys);
        const pdpt_i: usize = @intCast((virt >> 30) & 0x1ff);
        const pd_phys = ensureTable(self.fa, self.hhdm_base, &pdpt[pdpt_i], flags) orelse return false;

        const pd = tableVirt(self.hhdm_base, pd_phys);
        const pd_i: usize = @intCast((virt >> 21) & 0x1ff);
        const pt_phys = ensureTable(self.fa, self.hhdm_base, &pd[pd_i], flags) orelse return false;

        const pt = tableVirt(self.hhdm_base, pt_phys);
        const pt_i: usize = @intCast((virt >> 12) & 0x1ff);

        pt[pt_i] = (phys_addr & PTE_ADDR_MASK) | pte_flags;

        // Only flush TLB if this address space is currently active
        if ((readCr3() & ~@as(u64, 0xfff)) == root) {
            invlpg(virt);
        }

        return true;
    }

    /// Unmap a 4K page from the address space identified by `root`.
    fn unmap4kImpl(ptr: *anyopaque, root: u64, virt: u64) ?u64 {
        const self: *X64Mapper = @ptrCast(@alignCast(ptr));
        std.debug.assert(std.mem.isAligned(virt, std.options.page_size_min.?));
        assertCanonical(virt);

        const slot = pteSlotIn(self.hhdm_base, root, virt) orelse return null;
        const old = slot.*;

        if ((old & PTE_PRESENT) == 0) return null;

        const old_phys = ptePhys(old);
        slot.* = 0;

        if ((readCr3() & ~@as(u64, 0xfff)) == root) {
            invlpg(virt);
        }

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

    /// Create a new PML4 with kernel half cloned from the boot PML4.
    fn createRootImpl(ptr: *anyopaque) ?u64 {
        const self: *X64Mapper = @ptrCast(@alignCast(ptr));

        const pml4_frame = self.fa.allocFrame() orelse return null;

        const pml4 = tableVirt(self.hhdm_base, pml4_frame);
        const pml4_slice: [*]u64 = @ptrFromInt(@intFromPtr(pml4));
        @memset(pml4_slice[0..512], 0);

        const kernel_pml4 = tableVirt(self.hhdm_base, self.kernel_pml4_phys);
        for (KERNEL_PML4_START..512) |i| {
            pml4[i] = kernel_pml4[i];
        }

        return pml4_frame;
    }

    /// Free all user-half page table structures (indices 0-255).
    /// Does NOT free leaf pages - caller must unmap those first.
    fn destroyRootImpl(ptr: *anyopaque, root: u64) void {
        const self: *X64Mapper = @ptrCast(@alignCast(ptr));
        const pml4 = tableVirt(self.hhdm_base, root);

        for (0..KERNEL_PML4_START) |pml4_i| {
            const pml4e = pml4[pml4_i];
            if ((pml4e & PTE_PRESENT) == 0) continue;

            const pdpt_phys = ptePhys(pml4e);
            const pdpt = tableVirt(self.hhdm_base, pdpt_phys);

            for (0..512) |pdpt_i| {
                const pdpte = pdpt[pdpt_i];
                if ((pdpte & PTE_PRESENT) == 0) continue;
                if ((pdpte & PTE_HUGE) != 0) continue;

                const pd_phys = ptePhys(pdpte);
                const pd = tableVirt(self.hhdm_base, pd_phys);

                for (0..512) |pd_i| {
                    const pde = pd[pd_i];
                    if ((pde & PTE_PRESENT) == 0) continue;
                    if ((pde & PTE_HUGE) != 0) continue;

                    self.fa.freeFrame(ptePhys(pde));
                }
                self.fa.freeFrame(pd_phys);
            }
            self.fa.freeFrame(pdpt_phys);
        }
        self.fa.freeFrame(root);
    }

    fn activateImpl(_: *anyopaque, root: u64) void {
        const current = readCr3() & ~@as(u64, 0xfff);
        if (current == root) return;
        writeCr3(root);
    }

    fn activeRootImpl(_: *anyopaque) u64 {
        return readCr3() & ~@as(u64, 0xfff);
    }

    fn kernelRootImpl(ptr: *anyopaque) u64 {
        const self: *X64Mapper = @ptrCast(@alignCast(ptr));
        return self.kernel_pml4_phys;
    }

    fn hhdmBaseImpl(ptr: *anyopaque) u64 {
        const self: *X64Mapper = @ptrCast(@alignCast(ptr));
        return self.hhdm_base;
    }
};
