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
    pub const mmio = MapFlags{ .writable = true, .device = true, .cache_disable = true };
};

/// A dynamic interface (vtable) for arch-specific page manipulation.
/// mm module calls through this interface without knowing arch details.
pub const Mapper = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        map4k: *const fn (ptr: *anyopaque, virt: u64, phys: u64, flags: MapFlags) void,
        unmap4k: *const fn (ptr: *anyopaque, virt: u64) ?u64,
        alloc_frame: *const fn (ptr: *anyopaque) ?u64,
        free_frame: *const fn (ptr: *anyopaque, phys: u64) void,
    };

    /// Map a single 4K page
    pub inline fn map4k(self: Mapper, virt: u64, phys: u64, flags: MapFlags) void {
        self.vtable.map4k(self.ptr, virt, phys, flags);
    }

    /// Unmap a single 4K page, returns the physical address that was mapped (or null)
    pub inline fn unmap4k(self: Mapper, virt: u64) ?u64 {
        return self.vtable.unmap4k(self.ptr, virt);
    }

    /// Allocate a physical frame
    pub inline fn allocFrame(self: Mapper) ?u64 {
        return self.vtable.alloc_frame(self.ptr);
    }

    /// Free a physical frame
    pub inline fn freeFrame(self: Mapper, phys: u64) void {
        self.vtable.free_frame(self.ptr, phys);
    }

    /// Map a contiguous range of 4K pages
    pub fn mapRange4k(self: Mapper, virt: u64, phys: u64, len: u64, flags: MapFlags) void {
        var v = std.mem.alignBackward(u64, virt, PAGE_SIZE);
        var p = std.mem.alignBackward(u64, phys, PAGE_SIZE);
        const end = std.mem.alignForward(u64, virt + len, PAGE_SIZE);

        while (v < end) : ({
            v += PAGE_SIZE;
            p += PAGE_SIZE;
        }) {
            self.map4k(v, p, flags);
        }
    }
};
