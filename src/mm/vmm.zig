//! Virtual Memory Mapping Interface
//!
//! Vtable for page table operations - kernel mappings, user address space management,
//! lifecycle, and activation. Every map/unmap takes an explicit page table root.
//!
//! An address space root is identified by an opaque u64 handle. On x86_64 this
//! is the physical address of the PML4. On aarch64 it would be TTBR0. The mm layer
//! never interprets this value - it just passes it through.
//!
//! Consumers decide their own failure policy:
//!     - KHeap: calls mapKernel4k convenience method (panics on failure)
//!     - AddressSpace: calls map4k directly, bubbles error to caller

const std = @import("std");
const pmm = @import("pmm.zig");

pub const PAGE_SIZE: u64 = pmm.PAGE_SIZE;

/// Arch-agnostic page mapping flags.
/// The arch implementation translates these to PTE bits / MAIR attrs / etc.
pub const MapFlags = struct {
    /// Allow writes to this page
    writable: bool = false,

    /// Allow execution from this page (if false, map NX on x64 or PXN/UXN on aarch64)
    executable: bool = false,

    /// Allow user-mode access
    user: bool = false,

    /// Device/MMIO mapping (strongly ordered / nGnRnE / UC, etc.)
    device: bool = false,

    /// Prefer global mapping if supported (x86_64 PGE)
    global: bool = false,

    /// Cache policy: write-through
    write_through: bool = false,

    /// Cache policy: disable caching
    cache_disable: bool = false,

    /// Convenience constructors
    pub const kernel_code = MapFlags{ .executable = true, .global = true };
    pub const kernel_data = MapFlags{ .writable = true, .global = true };
    pub const kernel_rodata = MapFlags{ .global = true };
    pub const user_code = MapFlags{ .user = true, .executable = true };
    pub const user_data = MapFlags{ .user = true, .writable = true };
    pub const user_rodata = MapFlags{ .user = true };
    pub const user_stack = MapFlags{ .user = true, .writable = true };
    pub const mmio = MapFlags{ .writable = true, .device = true, .cache_disable = true };
};

pub const PageInfo = struct {
    phys: u64,
    writable: bool,
    user: bool,
    executable: bool,
};

/// A dynamic interface (vtable) for arch-specific page manipulation.
/// mm module calls through this interface without knowing arch details.
pub const Mapper = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Map a single 4K page in the given address space.
        /// Returns true on success, false on failure (e.g. OOM
        /// for intermediate page table frames)
        map4k: *const fn (ptr: *anyopaque, root: u64, virt: u64, phys: u64, flags: MapFlags) bool,
        /// Unmap a single 4K page from the given address space.
        /// Returns the physical address that was mapped, or null
        /// if nothing was mapped at that virtual address.
        unmap4k: *const fn (ptr: *anyopaque, root: u64, virt: u64) ?u64,
        /// Allocate a physical frame. Return null on OOM.
        alloc_frame: *const fn (ptr: *anyopaque) ?u64,
        /// Free a physical frame.
        free_frame: *const fn (ptr: *anyopaque, phys: u64) void,
        /// Create a new page table root with the kernel half pre-populated.
        /// Returns an opaque handle, or null on allocation failure.
        create_root: *const fn (ptr: *anyopaque) ?u64,
        /// Destroy a page table root. Frees all user-half page table
        /// structures (but NOT the mapped leaf pages - caller must unmap
        /// those first). The handle is invalid after this call.
        destroy_root: *const fn (ptr: *anyopaque, root: u64) void,
        /// Make the given address space active on the current CPU.
        /// Skips the switch (and TLB flush) if already active.
        activate: *const fn (ptr: *anyopaque, root: u64) void,
        /// Return the handle currently active on this CPU.
        active_root: *const fn (ptr: *anyopaque) u64,
        /// Return the kernel address space handle.
        kernel_root: *const fn (ptr: *anyopaque) u64,
        /// Query page info
        query_4k: *const fn (ptr: *anyopaque, root: u64, virt: u64) ?PageInfo,
        /// Return the HHDM base for accessing physical memory.
        /// Used by the mm layer for zeroing newly allocated frames.
        hhdm_base: *const fn (ptr: *anyopaque) u64,
    };

    // =========================================================================
    // Inline wrappers
    // =========================================================================

    /// Map a single 4K page
    /// Returns true on success, false on failure.
    pub inline fn map4k(self: Mapper, root: u64, virt: u64, phys: u64, flags: MapFlags) bool {
        return self.vtable.map4k(self.ptr, root, virt, phys, flags);
    }

    /// Unmap a single 4K page, returns the old physical address, or null.
    pub inline fn unmap4k(self: Mapper, root: u64, virt: u64) ?u64 {
        return self.vtable.unmap4k(self.ptr, root, virt);
    }

    /// Allocate a physical frame
    pub inline fn allocFrame(self: Mapper) ?u64 {
        return self.vtable.alloc_frame(self.ptr);
    }

    /// Free a physical frame
    pub inline fn freeFrame(self: Mapper, phys: u64) void {
        self.vtable.free_frame(self.ptr, phys);
    }

    /// Create a new address space root with kernel mappings cloned.
    pub inline fn createRoot(self: Mapper) ?u64 {
        return self.vtable.create_root(self.ptr);
    }

    /// Destroy an address space root (free page table structures only).
    pub inline fn destroyRoot(self: Mapper, root: u64) void {
        self.vtable.destroy_root(self.ptr, root);
    }

    /// Activate an address space on the current CPU.
    pub inline fn activate(self: Mapper, root: u64) void {
        self.vtable.activate(self.ptr, root);
    }

    /// Get the currently active root handle.
    pub inline fn activeRoot(self: Mapper) u64 {
        return self.vtable.active_root(self.ptr);
    }

    /// Get the kernel root handle.
    pub inline fn kernelRoot(self: Mapper) u64 {
        return self.vtable.kernel_root(self.ptr);
    }

    /// Query page info
    pub inline fn query4k(self: Mapper, root: u64, virt: u64) ?PageInfo {
        return self.vtable.query_4k(self.ptr, root, virt);
    }

    /// Get the HHDM base address.
    pub inline fn hhdmBase(self: Mapper) u64 {
        return self.vtable.hhdm_base(self.ptr);
    }

    // =========================================================================
    // Convenience methods
    // =========================================================================

    /// Map a single 4K page in the kernel address space.
    /// Panics on failure - kernel mappings are non-negotiable.
    pub fn mapKernel4k(self: Mapper, virt: u64, phys: u64, flags: MapFlags) void {
        if (!self.map4k(self.kernelRoot(), virt, phys, flags)) {
            @panic("mapKernel4k: out of page table frames");
        }
    }

    /// Unmap a single 4K page from the kernel address space.
    pub fn unmapKernel4k(self: Mapper, virt: u64) ?u64 {
        return self.unmap4k(self.kernelRoot(), virt);
    }

    /// Map a contiguous range of 4K pages in the kernel address space
    /// Panics on failure.
    pub fn mapRange4k(self: Mapper, virt: u64, phys: u64, len: u64, flags: MapFlags) void {
        const root = self.kernelRoot();
        var v = std.mem.alignBackward(u64, virt, PAGE_SIZE);
        var p = std.mem.alignBackward(u64, phys, PAGE_SIZE);
        const end = std.mem.alignForward(u64, virt + len, PAGE_SIZE);

        while (v < end) : ({
            v += PAGE_SIZE;
            p += PAGE_SIZE;
        }) {
            if (!self.map4k(root, v, p, flags)) {
                @panic("mapRange4k: out of page table frames");
            }
        }
    }

    /// Activate the kernel address space.
    pub fn activateKernel(self: Mapper) void {
        self.activate(self.kernelRoot());
    }
};
