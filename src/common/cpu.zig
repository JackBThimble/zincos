pub const MAX_CPUS: usize = 256;
pub const ApEntryFn = *const fn (stack_top: usize) callconv(.c) noreturn;

pub const ArchCpuData = extern struct {
    storage: [64]u8 = [_]u8{0} ** 64,
};

pub const CpuLocal = struct {
    present: bool = false,

    // This is the "CPU index" used by the kernel.
    id: usize,

    // Top of kernel stack for this CPU (virtual address)
    stack_top: usize,

    // TODO: Scheduler threads
    current_thread: ?*anyopaque = null,
    irq_depth: usize = 0,

    arch: ArchCpuData = .{},
};
