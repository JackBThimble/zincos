//! x86_64 SYSCALL / SYSRET Infrastructure
//!
//! Sets up the MSRs required for SYSCALL/SYSRET instruction pair.
//! The actual entry stub is in asm/syscall_entry.s
//!
//! SYSCALL convention (ABI):
//!     RAX = syscall number
//!     RDI, RSI, RDX, R10, R8, R9 = arguments
//!     (RCX and R11 are clobbered by SYSCALL hardware)
//!     Return value in RAX (negative errno on failure)
//!
//! The assembly stub:
//!     1. swapgs               -> get kernel GS (per-CPU data)
//!     2. save user RSP        -> percpu scratch
//!     3. load kernel RSP      -> from percpu
//!     4. push full user frame
//!     5. call syscall_dispatch (frame)
//!     6. pop frame, swapgs, sysretq

const std = @import("std");
const shared = @import("shared");
const log = shared.log;
const percpu = @import("cpu/percpu.zig");

// MSR addresses
const IA32_STAR: u32 = 0xc000_0081;
const IA32_LSTAR: u32 = 0xc000_0082;
const IA32_FMASK: u32 = 0xc000_0084;
const IA32_EFER: u32 = 0xc000_0080;

// Segment selectors (must match GDT)
const KERNEL_CS: u64 = 0x08;
const KERNEL_DS: u64 = 0x10;
const USER_CS: u64 = 0x18; // must be KERNEL_CS + 16 for SYSRET
const USER_DS: u64 = 0x20; // must be USER_CS + 8 for SYSRET

const FMASK_IF: u64 = 1 << 9; // clear IF (disable interrupts)
const FMASK_DF: u64 = 1 << 10; // clear DF (direction flag)
const FMASK_TF: u64 = 1 << 8; // clear TF (trap flag)

extern const syscall_entry_stub: u8;
extern fn kernel_syscall_dispatch(frame: *SyscallFrame) callconv(.c) u64;

/// Frame pushed by syscall_entry.s, passed to dispatch.
pub const SyscallFrame = extern struct {
    // Callee-saved (preserved for sysret)
    r15: u64,
    r14: u64,
    r13: u64,
    r12: u64,
    rbp: u64,
    rbx: u64,
    // Syscall arguments
    r9: u64,
    r8: u64,
    r10: u64, // replaces RCX (clobbered by SYSCALL)
    rdx: u64,
    rsi: u64,
    rdi: u64,
    rax: u64, // syscall number
    // saved by hardware / entry stub
    rcx: u64, // user RIP (saved by SYSCALL hardware)
    r11: u64, // user RFLAGS (saved by SYSCALL hardware)
    user_rsp: u64, // saved from percpu scratch
};

fn writeMsr(msr: u32, value: u64) void {
    const low: u32 = @truncate(value);
    const high: u32 = @truncate(value >> 32);
    asm volatile ("wrmsr"
        :
        : [msr] "{ecx}" (msr),
          [low] "{eax}" (low),
          [high] "{edx}" (high),
    );
}

fn readMsr(msr: u32) u64 {
    var low: u32 = undefined;
    var high: u32 = undefined;
    asm volatile ("rdmsr"
        : [low] "={eax}" (low),
          [high] "={edx}" (high),
        : [msr] "{ecx}" (msr),
    );
    return (@as(u64, high) << 32) | low;
}

/// Initialize SYSCALL/SYSRET on the current CPU.
/// Must be called on each CPU (BSP and all APs)
pub fn init() void {
    // Enable SCE (system call extensions) in EFER
    const efer = readMsr(IA32_EFER);
    writeMsr(IA32_EFER, efer | 1); // bit 0 = SCE

    // STAR: segment selectors for SYSCALL/SYSRET
    //      bits [47:32] = kernel CS (SYSCALL loads CS from here, SS = CS+8)
    //      bits [63:48] = user CS base (SYSRET loads CS = base + 16, SS = base + 8)
    //
    // For SYSRET to work correctly:
    //      User CS = STAR[63:48] + 16
    //      User SS = STAR[63:48] + 8
    const star = (KERNEL_CS << 32) | ((USER_CS - 16) << 48);
    writeMsr(IA32_STAR, star);

    // LSTAR: kernel entry point for SYSCALL
    writeMsr(IA32_LSTAR, @intFromPtr(&syscall_entry_stub));

    // FMASK: RFLAGS bits cleared on SYSCALL entry
    writeMsr(IA32_FMASK, FMASK_IF | FMASK_DF | FMASK_TF);

    log.debug("SYSCALL MSRs configured on CPU{}", .{percpu.getCpuId()});
}

/// Per-CPU offsets into PerCpu struct that the assembly stub needs.
/// These are verified at comptime against the actual struct layout.
pub const PERCPU_SCRATCH0_OFF = @offsetOf(percpu.PerCpu, "scratch0");
pub const PERCPU_KERNEL_STACK_OFF = @offsetOf(percpu.PerCpu, "kernel_stack");

/// Syscall dispatcher called from syscall_entry.s.
pub export fn syscall_dispatch(frame: *SyscallFrame) callconv(.c) u64 {
    return kernel_syscall_dispatch(frame);
}
