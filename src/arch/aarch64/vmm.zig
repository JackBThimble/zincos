const std = @import("std");
const mm = @import("mm");
const pmm = mm.pmm;
const vmm = mm.vmm;

// =================================
// AArch64 Mapper Context (stub)
// =================================

pub const MapperCtx = struct {
    ttbr1_base: u64,
    fa: *pmm.FrameAllocator,

    /// Create a vmm.Mapper interface from this context
    pub fn mapper(self: *MapperCtx) vmm.Mapper {
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

    fn map4kImpl(ptr: *anyopaque, virt: u64, phys: u64, flags: vmm.MapFlags) void {
        _ = ptr;
        _ = virt;
        _ = phys;
        _ = flags;
        @panic("AArch64 vmm not implemented");
    }

    fn unmap4kImpl(ptr: *anyopaque, virt: u64) ?u64 {
        _ = ptr;
        _ = virt;
        @panic("AArch64 vmm not implemented");
    }

    fn allocFrameImpl(ptr: *anyopaque) ?u64 {
        _ = ptr;
        @panic("AArch64 vmm not implemented");
    }

    fn freeFrameImpl(ptr: *anyopaque, phys: u64) void {
        _ = ptr;
        _ = phys;
        @panic("AArch64 vmm not implemented");
    }
};
