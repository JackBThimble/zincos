const percpu = @import("cpu/percpu.zig");

extern fn context_switch_asm(old_sp_ptr: *u64, new_sp: u64) callconv(.c) void;
extern fn load_context_asm(new_sp: u64) callconv(.c) noreturn;
extern fn enter_user_mode(user_rip: u64, user_rsp: u64) callconv(.c) noreturn;

/// Opaque interrupt state. rflags for x64
pub const IrqFlags = u64;

/// Task entry point signature
pub const TaskEntryFn = *const fn (arg: usize) callconv(.c) noreturn;

/// MSR addresses
pub const IA32_KERNEL_GS_BASE: u32 = 0xc000_0102;
pub const IA32_GS_BASE: u32 = 0xc000_0101;

/// Context switch - callee-saved registers, swap stack pointer, restore
pub inline fn switchContext(old_sp_ptr: *u64, new_sp: u64) void {
    context_switch_asm(old_sp_ptr, new_sp);
}

pub inline fn loadContext(new_sp: u64) noreturn {
    load_context_asm(new_sp);
}

pub inline fn disableIrq() IrqFlags {
    var flags: u64 = undefined;
    asm volatile (
        \\pushfq
        \\pop %[flags]
        \\cli
        : [flags] "=r" (flags),
        :
        : .{ .memory = true });
    return flags;
}

pub inline fn restoreIrq(flags: IrqFlags) void {
    if ((flags & (1 << 9)) != 0) {
        asm volatile ("sti" ::: .{ .memory = true });
    }
}

pub inline fn getCpuId() u32 {
    return percpu.getCpuId();
}

pub inline fn haltUntilInterrupt() void {
    asm volatile ("sti; hlt" ::: .{ .memory = true });
}

fn taskEntryTrampoline() callconv(.naked) noreturn {
    asm volatile (
        \\sti
        \\mov %%rbx, %%rdi
        \\call *%%r12
        \\ud2
    );
}

pub fn prepareContext(
    stack_base: u64,
    stack_size: usize,
    entry: TaskEntryFn,
    arg: usize,
) u64 {
    const stack_top = stack_base + stack_size;
    const frame_start = stack_top - (8 * 8);
    const frame = @as([*]u64, @ptrFromInt(frame_start));

    // Must match load_context_asm restore order:
    // popfq, r15, r14, r13, r12, rbx, rbp, ret
    frame[0] = 0x202; // rflags: IF=1
    frame[1] = 0; // r15
    frame[2] = 0; // r14
    frame[3] = 0; // r13
    frame[4] = @intFromPtr(entry); // r12 = task entry fn
    frame[5] = arg; // rbx = arg
    frame[6] = 0; // rbp
    frame[7] = @intFromPtr(&taskEntryTrampoline); // return addr

    return frame_start;
}

/// Architecture-specific per-task state for user-mode support.
/// Stored in Task.arch_state and managed entirely in arch layer.
pub const ArchTaskState = struct {
    /// Saved IA32_KERNEL_GS_BASE for user-mode tasks.
    /// When a user task is interrupted, swapgs in the ISR entry moves the
    /// user's GS value into KERNEL_GS_BASE. During context switch we save
    /// it here and restore it when this task is next scheduled.
    /// For kernel tasks this field is unused (always 0).
    saved_kernel_gs_base: u64 = 0,
};

/// Save arch-specific state when switching away from a user task.
/// Called by the core scheduler during context switch for outgoing
/// user tasks. Captures any CPU state that is per-task and must survive
/// being switched out.
pub fn saveUserState(state: *ArchTaskState) void {
    state.saved_kernel_gs_base = readMsr(IA32_KERNEL_GS_BASE);
}

/// Restore arch-specific state when switching to a user task.
/// Called by the core scheduler during context switch for incoming
/// user tasks. Configures the CPU so that privelege transitions
/// (interrupts, syscalls from user mode) work correctly.
pub fn loadUserState(state: *const ArchTaskState, kernel_stack_top: u64) void {
    // Point the CPU at this task's kernel stack for privelege transitions
    // On x86_64, TSS.rsp0 is loaded by hardware on ring 3 -> ring 0.
    updateKernelStack(kernel_stack_top);

    // Restore this task's saved user GS value into KERNEL_GS_BASE.
    // The ISR exit swapgs will move it into GS_BASE when returning
    // to user mode.
    writeMsr(IA32_KERNEL_GS_BASE, state.saved_kernel_gs_base);
}

/// Perform the initial transition from kernel mode to user mode.
/// Called once per user task on its first schedule. The address space
/// must already be activated by the caller.
///
/// This configures the CPU for privilege transitions, then drops to
/// user mode via iretq. Never returns.
pub fn enterInitialUserMode(
    kernel_stack_top: u64,
    user_entry_addr: u64,
    user_stack: u64,
) noreturn {
    // Set up kernel stack for interrupts from user mode
    updateKernelStack(kernel_stack_top);

    // User's initial GS value is 0. WHen enter_user_mode does swapgs:
    //      GS_BASE (per-CPU pointer)   -> KERNEL_GS_BASE (saved for ISR entry)
    //      KERNEL_GS_BASE (0)          -> GS_BASE (user sees 0)
    writeMsr(IA32_KERNEL_GS_BASE, 0);

    // Build iretq frame and drop to ring 3
    enter_user_mode(user_entry_addr, user_stack);
}

/// Read a Model-Specific Register.
inline fn readMsr(msr: u32) u64 {
    var low: u32 = undefined;
    var high: u32 = undefined;

    asm volatile ("rdmsr"
        : [low] "={eax}" (low),
          [high] "={edx}" (high),
        : [msr] "{ecx}" (msr),
    );
    return (@as(u64, high) << 32) | low;
}

/// Write a Model-Specific Register.
inline fn writeMsr(msr: u32, value: u64) void {
    const low: u32 = @truncate(value);
    const high: u32 = @truncate(value >> 32);
    asm volatile ("wrmsr"
        :
        : [msr] "{ecx}" (msr),
          [low] "{eax}" (low),
          [high] "{edx}" (high),
    );
}

/// Update the CPU's kernel stack pointer for privilege transitions.
/// On x86_64, this sets TSS.rsp0 (loaded by hardware on ring 3 -> ring 0)
/// and the per-CPU kernel_stack field.
pub fn updateKernelStack(kernel_stack_top: u64) void {
    const p = percpu.getPerCpu();
    p.tss.rsp0 = kernel_stack_top;
    p.kernel_stack = kernel_stack_top;
}
