const std = @import("std");
const sc = @import("shared").syscall;
const ipc = @import("shared").ipc_message;
const vfs = @import("shared").vfs_protocol;

const Handle = u64;

pub const Number = sc.Number;
pub const encodeErrno = sc.encodeErrno;
pub const Errno = sc.Errno;

pub fn sysRead(fd: u64, buf: [*]u8, len: usize) usize {
    const ret = asm volatile ("syscall"
        : [ret] "={rax}" (-> u64),
        : [num] "{rax}" (@intFromEnum(sc.Number.sys_read)),
          [fd_] "{rdi}" (fd),
          [buf_] "{rsi}" (@as(u64, @intFromPtr(buf))),
          [len] "{rdx}" (@as(u64, @intCast(len))),
        : .{ .rcx = true, .r11 = true, .memory = true });

    if (isSysErr(ret)) return 0;
    return @intCast(ret);
}

pub fn sysWrite(fd: u64, buf: [*]const u8, len: usize) void {
    _ = asm volatile ("syscall"
        : [ret] "={rax}" (-> u64),
        : [num] "{rax}" (@intFromEnum(sc.Number.sys_write)),
          [fd_] "{rdi}" (fd),
          [buf_] "{rsi}" (@as(u64, @intFromPtr(buf))),
          [len_] "{rdx}" (@as(u64, @intCast(len))),
        : .{ .rcx = true, .r11 = true, .memory = true });
}

pub fn sysIpcCall(endpoint: Handle, req: *const ipc.Message, reply: *ipc.Message) u64 {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> u64),
        : [num] "{rax}" (@intFromEnum(sc.Number.ipc_call)),
          [ep] "{rdi}" (endpoint),
          [req] "{rsi}" (@as(u64, @intCast(@intFromPtr(req)))),
          [reply] "{rdx}" (@as(u64, @intCast(@intFromPtr(reply)))),
        : .{ .rcx = true, .r11 = true, .memory = true });
}

pub fn sysIpcReply(caller: Handle, msg: *const ipc.Message) u64 {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> u64),
        : [num] "{rax}" (@intFromEnum(sc.Number.ipc_reply)),
          [caller] "{rdi}" (caller),
          [msg] "{rsi}" (@as(u64, @intCast(@intFromPtr(msg)))),
        : .{ .rcx = true, .r11 = true, .memory = true });
}

pub fn sysIpcReceive(endpoint: Handle, out_msg: *ipc.Message, out_caller: *Handle) u64 {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> u64),
        : [num] "{rax}" (@intFromEnum(sc.Number.ipc_receive)),
          [ep] "{rdi}" (endpoint),
          [msg] "{rsi}" (@as(u64, @intCast(@intFromPtr(out_msg)))),
          [caller] "{rdx}" (@as(u64, @intCast(@intFromPtr(out_caller)))),
        : .{ .rcx = true, .r11 = true, .memory = true });
}

pub fn sysIpcDestroyEndpoint(endpoint: Handle) u64 {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> u64),
        : [num] "{rax}" (@intFromEnum(sc.Number.ipc_destroy_endpoint)),
          [ep] "{rdi}" (endpoint),
        : .{ .rcx = true, .r11 = true, .memory = true });
}

pub fn sysSchedYield() void {
    _ = asm volatile ("syscall"
        : [ret] "={rax}" (-> u64),
        : [num] "{rax}" (@intFromEnum(sc.Number.sched_yield)),
        : .{ .rcx = true, .r11 = true, .memory = true });
}

pub fn sysExit(code: u64) noreturn {
    _ = asm volatile ("syscall"
        : [ret] "={rax}" (-> u64),
        : [num] "{rax}" (@intFromEnum(sc.Number.sys_exit)),
          [code] "{rdi}" (code),
        : .{ .rcx = true, .r11 = true, .memory = true });

    unreachable;
}

pub fn sysVfsGetBootstrapEndpoint() u64 {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> u64),
        : [num] "{rax}" (@intFromEnum(sc.Number.vfs_get_bootstrap_endpoint)),
        : .{ .rcx = true, .r11 = true, .memory = true });
}

pub fn sysGetPid() u64 {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> u64),
        : [num] "{rax}" (@intFromEnum(sc.Number.get_pid)),
        : .{ .rcx = true, .r11 = true, .memory = true });
}

pub fn sysGetCpuId() u64 {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> u64),
        : [num] "{rax}" (@intFromEnum(sc.Number.get_cpu_id)),
        : .{ .rcx = true, .r11 = true, .memory = true });
}

pub fn isSysErr(ret: u64) bool {
    return @as(i64, @bitCast(ret)) < 0;
}

pub fn hang() noreturn {
    while (true) {
        sysSchedYield();
    }
}
