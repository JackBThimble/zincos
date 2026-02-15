//! Address Space Management
//!
//! Each user process gets its own AddressSpace which owns an opaque
//! arch-level handle (e.g. PML4 physical address on x86_64, TTBR0 on
//! aarch64). The arch layer handles all page table manipulation, kernel
//! mapping cloning, and TLB management - all throught the Mapper vtable.
//!
//! This module provides:
//!     - Lifecycle management (create / destroy)
//!     - User page mapping / unmapping
//!     - Anonymous mapping (allocate + zero + map)
//!     - Activation (delegate to arch for CR3/TTBR switch)
//!
//! This module does NOT know about:
//!     - Page table entry formats
//!     - TLB invalidation results
//!     - Register names or inline assembly
//!     - Anything that would change between architectures
//!
//! Lock ordering:
//!     1. AddressSpace.lock
//!     2. Arch page table locks (inside mapper.map4k etc.)
//!     3. Frame allocator lock (inside mapper.allocFrame)

const std = @import("std");
const vmm = @import("vmm.zig");
const log = @import("shared").log;

const PAGE_SIZE: u64 = vmm.PAGE_SIZE;

const SpinLock = struct {
    locked: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn acquire(self: *SpinLock) void {
        while (self.locked.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    pub fn release(self: *SpinLock) void {
        self.locked.store(false, .release);
    }
};

/// Global mapper - set once during init. The same Mapper that KHeap and
/// everyone uses, just with different root handles.
var mapper: ?vmm.Mapper = null;

/// Maximum user-space virtual address (canonical low-half limit)
/// 48-bit virtual addressing: user space is 0 .. 0x0000_7fff_ffff_ffff.
/// This constant is arch-neutral in the sense that any arch with a user/kernel
/// split will define a similar boundary. If you port to an arch with a different split,
/// change this value.
pub const USER_ADDR_MAX: u64 = 0x0000_7fff_ffff_ffff;

/// Allocate a physical frame from the global mapper.
pub fn allocPhysFrame() ?u64 {
    const m = mapper orelse return null;
    return m.allocFrame();
}

/// Free a physical frame back to the global mapper.
pub fn freePhysFrame(phys: u64) void {
    const m = mapper orelse return;
    m.freeFrame(phys);
}

/// Zero one physical frame via HHDM mapping.
pub fn zeroPhysFrame(phys: u64) void {
    const m = mapper orelse return;
    const p: [*]u8 = @ptrFromInt(m.hhdmBase() + phys);
    @memset(p[0..@as(usize, @intCast(PAGE_SIZE))], 0);
}

// =============================================================================
// Initialization
// =============================================================================

/// Called once during kernel init, after the arch mapper is set up.
/// This is the same Mapper that was passed to KHeap - one interface for
/// everything.
pub fn init(m: vmm.Mapper) void {
    mapper = m;
    log.info("Address space subsystem initialized", .{});
}

// =============================================================================
// Address Space
// =============================================================================

pub const AddressSpace = struct {
    /// Opaque arch handle (PML4 phys on x86_64, TTBR0 on aarch64, etc.)
    /// The mm layer never interprets this value.
    handle: u64,

    /// Protects page table modifications through this AddressSpace.
    lock: SpinLock = .{},

    /// Reference count for shared address space (fork / threads).
    refcount: u32 = 1,

    // =========================================================================
    // Creation / Destruction
    // =========================================================================
    pub fn create(allocator: std.mem.Allocator) !*AddressSpace {
        const m = mapper orelse return error.NotInitialized;

        const handle = m.createRoot() orelse return error.OutOfMemory;

        const as = try allocator.create(AddressSpace);
        as.* = .{ .handle = handle };

        log.debug("AddressSpace created: handle=0x{x}", .{handle});
        return as;
    }

    /// Destroy this address space.
    ///
    /// IMPORTANT: The caller must unmap and free all user pages BEFORE
    /// calling destroy. This only frees the page table structures
    /// themselves, not the pages they point to.
    pub fn destroy(self: *AddressSpace, allocator: std.mem.Allocator) void {
        const m = mapper orelse return;

        log.debug("AddressSpace destroying: handle=0x{x}", .{self.handle});

        m.destroyRoot(self.handle);
        allocator.destroy(self);
    }

    // =========================================================================
    // Page Mapping
    // =========================================================================

    /// Map a single 4K page in this address space.
    /// Works regardless of whether this address space is currently active.
    pub fn mapPage(self: *AddressSpace, virt: u64, phys: u64, flags: vmm.MapFlags) !void {
        std.debug.assert(std.mem.isAligned(virt, PAGE_SIZE));
        std.debug.assert(std.mem.isAligned(phys, PAGE_SIZE));
        if (virt > USER_ADDR_MAX) return error.ExceedsMaxUserAddress;

        const m = mapper orelse return error.NotInitialized;

        self.lock.acquire();
        defer self.lock.release();

        if (!m.map4k(self.handle, virt, phys, flags)) {
            return error.OutOfMemory;
        }
    }

    /// Unmap a single 4K page. Returns the physical address that was mapped,
    /// or null if nothing was mapped there.
    pub fn unmapPage(self: *AddressSpace, virt: u64) ?u64 {
        std.debug.assert(std.mem.isAligned(virt, PAGE_SIZE));
        if (virt > USER_ADDR_MAX) return null;

        const m = mapper orelse return null;

        self.lock.acquire();
        defer self.lock.release();

        return m.unmap4k(self.handle, virt);
    }

    /// Map a continuous range of anonymous (zero-filled) pages.
    /// Allocates physical frames, zeroes them, and maps them.
    /// On failure, rolls back all mappings made so far.
    pub fn mapAnonymous(
        self: *AddressSpace,
        virt_start: u64,
        num_pages: usize,
        flags: vmm.MapFlags,
    ) !void {
        const m = mapper orelse return error.NotInitialized;
        const hhdm = m.hhdmBase();

        var mapped: usize = 0;
        errdefer {
            // Rollback: unmap and free everything mapped in this function
            for (0..mapped) |i| {
                const va = virt_start + @as(u64, @intCast(i)) * PAGE_SIZE;
                if (self.unmapPage(va)) |phys| {
                    m.freeFrame(phys);
                }
            }
        }

        for (0..num_pages) |i| {
            const va = virt_start + @as(u64, @intCast(i)) * PAGE_SIZE;

            const frame = m.allocFrame() orelse return error.OutOfMemory;

            // Zero the frame so we don't leak kernel data to userspace
            const frame_ptr: [*]u8 = @ptrFromInt(@as(usize, @intCast(hhdm + frame)));
            @memset(frame_ptr[0..@as(usize, @intCast(PAGE_SIZE))], 0);

            try self.mapPage(va, frame, flags);
            mapped += 1;
        }
    }

    /// Unmap a range and free the underlying physical frames.
    pub fn unmapAndFree(self: *AddressSpace, virt_start: u64, num_pages: usize) void {
        const m = mapper orelse return;

        for (0..num_pages) |i| {
            const va = virt_start + @as(u64, @intCast(i)) * PAGE_SIZE;
            if (self.unmapPage(va)) |phys| {
                m.freeFrame(phys);
            }
        }
    }

    /// Map specific physical pages (not anonymous). Does NOT zero them.
    /// Used for mapping user code from an ELF loader, shared memory, etc.
    pub fn mapPages(
        self: *AddressSpace,
        virt_start: u64,
        phys_start: u64,
        num_pages: usize,
        flags: vmm.MapFlags,
    ) !void {
        var mapped: usize = 0;
        errdefer {
            for (0..mapped) |i| {
                const va = virt_start + @as(u64, @intCast(i)) * PAGE_SIZE;
                _ = self.unmapPage(va);
            }
        }

        for (0..num_pages) |i| {
            const off = @as(u64, @intCast(i)) * PAGE_SIZE;
            try self.mapPage(virt_start + off, phys_start + off, flags);
            mapped += 1;
        }
    }

    // =========================================================================
    // Activation
    // =========================================================================

    /// Make this address space active on the current CPU.
    /// The arch layer handles skipping redundant switches and TLB flushes.
    pub fn activate(self: *const AddressSpace) void {
        const m = mapper orelse return;
        m.activate(self.handle);
    }

    // =========================================================================
    // Queries
    // =========================================================================

    /// Check if this address is active on the current CPU.
    pub fn isActive(self: *const AddressSpace) bool {
        const m = mapper orelse return false;
        return m.activeRoot() == self.handle;
    }
};

// =========================================================================
// Module-level helpers
// =========================================================================

/// Switch to the kernel address space (no user mappings).
/// Used when running pure kernel tasks that have no user address space.
pub fn activateKernel() void {
    const m = mapper orelse return;
    m.activateKernel();
}

/// Get the kernel address space handle (for tasks that need it).
pub fn kernelHandle() u64 {
    const m = mapper orelse return 0;
    return m.kernelRoot();
}
