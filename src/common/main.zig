const boot_info = @import("boot_info.zig");

pub var g_boot_info: ?*const BootInfo = null;
pub const FramebufferInfo = boot_info.FramebufferInfo;
pub const MemoryKind = boot_info.MemoryKind;
pub const MemoryRegion = boot_info.MemoryRegion;
pub const PixelFormat = boot_info.PixelFormat;
pub const BootInfo = boot_info.BootInfo;
pub const BOOT_MAGIC = boot_info.BOOT_MAGIC;

pub const cpu = @import("cpu.zig");
pub const MAX_CPUS = cpu.MAX_CPUS;
pub const ApEntryFn = cpu.ApEntryFn;
pub const ArchCpuData = cpu.ArchCpuData;
pub const CpuLocal = cpu.CpuLocal;

pub const log = @import("log.zig");
