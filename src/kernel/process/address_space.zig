//! Per-process virtual address space.
//!
//! Each AddressSpace owns a PML4. The upper half (entries 256-511) is
//! shared with the kernel by copying PML4 entries from the kernel's
//! page tables at creation time. The lower half (entries 0-255) is
//! per-process user memory.
//!
//! Page table manipulation uses HHDM to access page tables by physical
//! address, so we can map pages into any address space without switching
//! CR3. User address spaces are built from kernel context, not from within
//! the target process.

const std = @import("std");
const shared = @import("shared");
const log = shared.log;
const mm = @import("mm");
const pmm = mm.pmm;
const vmm = mm.vmm;

const PAGE_SIZE: u64 = mm.PAGE_SIZE;

// PTE bits (same as mapper.zig - duplicated here to avoid circular deps)
