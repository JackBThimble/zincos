const msr = @import("msr.zig");
const serial = @import("serial.zig");

const MSR_EFER: u32 = 0xc0000080;
const MSR_STAR: u32 = 0xc0000081;
const MSR_LSTAR: u32 = 0xc0000082;
const MSR_CSTAR: u32 = 0xc0000083; // compat mode (unused in 64-bit)
const MSR_SFMASK: u32 = 0xc0000084;

// EFER flags
const EFER_SCE: u64 = 1 << 0; // System call extensions

// RFLAGS to mask during syscall
const RFLAGS_IF: u64 = 1 << 9; // interrupt flag
const RFLAGS_TF: u64 = 1 << 8; // trap flag
const RFLAGS_DF: u64 = 1 << 10; // direction flag

// Syscall numbers
pub const Syscall = enum(u64) {
    exit = 0,
    write = 1,
    read = 2,
    open = 3,
    close = 4,
    mmap = 5,
    munmap = 6,
    fork = 7,
    exec = 8,
    wait = 9,
};

// Syscall arguments are passed in: rdi, rsi, rdx, r10, r8, r9
// return value in rax
// rcx and r11 are clobbered by syscall instruction (save rip and rflags)

pub fn init() void {
    // enable syscall/sysret in EFER
    var efer = msr.rdmsr(MSR_EFER);
    efer |= EFER_SCE;
    msr.wrmsr(MSR_EFER, efer);

    // Set up STAR register
    // bits 63:48 = kernel cs (0x08) and ss (0x10)
    // bits 47:32 = user cs (0x1b-16) and ss (0x23-8) <- Note: sysret adds 16 to this value for CS
    const star: u64 = (@as(u64, 0x08) << 32) | (@as(u64, 0x18 - 16) << 48);
    msr.wrmsr(MSR_STAR, star);

    msr.wrmsr(MSR_LSTAR, @intFromPtr(&syscall_entry));

    msr.wrmsr(MSR_SFMASK, RFLAGS_IF | RFLAGS_TF | RFLAGS_DF);
}

export fn syscall_entry() callconv(.naked) void {
    // syscall instruction:
    // - save rip to rcx
    // - saves rflags to r11
    // - loads cs from star
    // - loads rip from lstar
    // - clears rflags bits according to sfmask

    asm volatile (
        \\swapgs                    // Swap GS base for kernel per-CPU data
        \\movq %%rsp, %%gs:8        // Save user RSP in per-CPU area
        \\movq %%gs:0, %%rsp        // Load kernel RSP from per-CPU area
        \\
        \\push %%rcx                // save user rip
        \\push %%r11                // save user rflags
        \\ 
        \\push %%rax                // save user rip
        \\push %%rbx
        \\push %%rdx
        \\push %%rsi
        \\push %%rdi
        \\push %%rbp
        \\push %%r8
        \\push %%r9
        \\push %%r10
        \\push %%r12
        \\push %%r13
        \\push %%r14
        \\push %%r15
        \\
        \\mov %%rsp, %%rdi          // pass frame pointer to handler
        \\callq %[syscall_handler:P]
        \\ 
        \\pop %%r15
        \\pop %%r14
        \\pop %%r13
        \\pop %%r12
        \\pop %%r10
        \\pop %%r9
        \\pop %%r8
        \\pop %%rbp
        \\pop %%rdi
        \\pop %%rsi
        \\pop %%rdx
        \\pop %%rbx
        \\addq $8, %%rsp            // Skip saved syscall number (rax has return value)
        \\
        \\pop %%r11                 // restore rflags
        \\pop %%rcx                 // restore rip
        \\
        \\movq %%gs:8, %%rsp        // restore user rsp
        \\swapgs                    // restore user gs
        \\sysretq                   // return to userspace
        :
        : [syscall_handler] "X" (&syscall_handler),
    );
}

const SyscallFrame = packed struct {
    r15: u64,
    r14: u64,
    r13: u64,
    r12: u64,
    r10: u64,
    r9: u64,
    r8: u64,
    rbp: u64,
    rdi: u64, // arg 1
    rsi: u64, // arg 2
    rdx: u64, // arg 3
    rbx: u64,
    rax: u64, // syscall number
    rflags: u64,
    rip: u64,
};

// main syscall dispatcher
export fn syscall_handler(frame: *SyscallFrame) callconv(.c) u64 {
    const syscall_num = frame.rax;

    return switch (syscall_num) {
        0 => sys_exit(frame.rdi),
        1 => sys_write(@truncate(frame.rdi), frame.rsi, frame.rdx),
        2 => sys_read(@truncate(frame.rdi), frame.rsi, frame.rdx),
        // TODO: add syscalls
        else => blk: {
            serial.printfln("Unknown syscall: {d}", .{syscall_num});
            break :blk @as(u64, @bitCast(@as(i64, -1))); // -ENOSYS
        },
    };
}

fn sys_exit(code: u64) u64 {
    serial.printfln("Process exiting with code: {d}", .{code});
    while (true) asm volatile ("hlt");
}

fn sys_write(fd: u32, buf: u64, count: u64) u64 {
    if (fd == 1 or fd == 2) {
        // stdout or stderr
        // TODO: validate buffer is in user space
        const data = @as([*]const u8, @ptrFromInt(buf))[0..count];
        // TODO: Write to console/serial
        serial.printfln("WRITE: {}", .{data});
        return count;
    }
    return @as(u64, @bitCast(@as(i64, -1))); // - EBADF
}

fn sys_read(fd: u32, buf: u64, count: u64) u64 {
    _ = fd;
    _ = buf;
    _ = count;
    // TODO: implement
    return 0;
}
