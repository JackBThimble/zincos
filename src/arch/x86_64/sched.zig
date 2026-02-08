const percpu = @import("cpu/percpu.zig");

extern fn context_switch_asm(old_sp_ptr: *u64, new_sp: u64) callconv(.c) void;
extern fn load_context_asm(new_sp: u64) callconv(.c) noreturn;

/// Opaque interrupt state. rflags for x64
pub const IrqFlags = u64;

/// Task entry point signature
pub const TaskEntryFn = *const fn (arg: usize) callconv(.c) noreturn;

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
        \\pop %[rflags]
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
    const frame_start = stack_top - (9 * 8);
    const frame = @as([*]u64, @ptrFromInt(frame_start));

    frame[8] = 0; // alignment
    frame[7] = @intFromPtr(&taskEntryTrampoline); // return addr
    frame[6] = 0x202; // rflags: IF=1
    frame[5] = 0; // r15
    frame[4] = 0; // r14
    frame[3] = 0; // r13
    frame[2] = @intFromPtr(entry); // r12 = entry fn
    frame[1] = arg; // rbx = arg
    frame[0] = 0; // rbp

    return frame_start;
}
