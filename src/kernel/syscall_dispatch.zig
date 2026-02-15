const std = @import("std");
const arch = @import("arch");
const shared = @import("shared");

const ipc = @import("ipc/mod.zig");
const process = @import("process/mod.zig");
const sched = @import("sched/core.zig");
const IpcHandle = ipc.handles.Handle;

const sc = shared.syscall;
const SyscallFrame = arch.syscall.SyscallFrame;

const SERIAL_STDIN_FD: u64 = 0;
const SERIAL_STDOUT_FD: u64 = 1;
const SERIAL_STDERR_FD: u64 = 2;

fn retErr(code: sc.Errno) u64 {
    return sc.encodeErrno(code);
}

fn parseHandle(raw: u64) ?IpcHandle {
    return std.math.cast(IpcHandle, raw);
}

fn parseMsgPtr(raw: u64) ?*ipc.Message {
    if (raw == 0) return null;
    return @ptrFromInt(raw);
}

fn parseMsgPtrConst(raw: u64) ?*const ipc.Message {
    if (raw == 0) return null;
    return @ptrFromInt(raw);
}

fn mapCreateError(err: anyerror) sc.Errno {
    return switch (err) {
        error.NotInitialized => .NODEV,
        error.OutOfMemory => .NOMEM,
        error.OutOfEndpoints => .AGAIN,
        error.PermissionDenied => .BADF,
        error.InvalidEndpoint => .BADF,
        error.OutOfHandles => .AGAIN,
        else => .INVAL,
    };
}

fn mapEndpointError(err: anyerror) sc.Errno {
    return switch (err) {
        error.InvalidEndpoint => .INVAL,
        error.EndpointClosed => .PIPE,
        else => .INVAL,
    };
}

fn badFd(fd: u64, for_read: bool) bool {
    if (for_read) return fd != SERIAL_STDIN_FD;
    return fd != SERIAL_STDOUT_FD and fd != SERIAL_STDERR_FD;
}

/// Kernel-side syscall implementation.
/// Called indirectly from arch.syscall.syscall_dispatch.
pub export fn kernel_syscall_dispatch(frame: *SyscallFrame) callconv(.c) u64 {
    switch (frame.rax) {
        @intFromEnum(sc.Number.nop) => return 0,
        @intFromEnum(sc.Number.get_cpu_id) => return @as(u64, arch.percpu.getCpuId()),
        @intFromEnum(sc.Number.sched_yield) => {
            sched.yield();
            return 0;
        },
        @intFromEnum(sc.Number.get_pid) => return @as(u64, process.currentPid()),
        @intFromEnum(sc.Number.sys_read) => {
            const fd = frame.rdi;
            const buf_ptr = frame.rsi;
            const len: usize = std.math.cast(usize, frame.rdx) orelse return retErr(.INVAL);

            if (badFd(fd, true)) return retErr(.BADF);
            if (buf_ptr == 0) return retErr(.FAULT);

            const out: [*]u8 = @ptrFromInt(buf_ptr);
            if (len == 0) return 0;

            // TODO: wire real keyboard/console input. For now return EOF.
            _ = out;
            return 0;
        },
        @intFromEnum(sc.Number.sys_write) => {
            const fd = frame.rdi;
            const buf_ptr = frame.rsi;
            const len: usize = std.math.cast(usize, frame.rdx) orelse return retErr(.INVAL);
            if (badFd(fd, false)) return retErr(.BADF);
            if (buf_ptr == 0 and len != 0) return retErr(.FAULT);

            const bytes: []const u8 = @as([*]const u8, @ptrFromInt(buf_ptr))[0..len];
            arch.serial.write(bytes);
            return @as(u64, @intCast(len));
        },
        @intFromEnum(sc.Number.ipc_create_endpoint) => {
            const pid = process.currentPid();
            const ep = ipc.createEndpoint(pid) catch |err| return retErr(mapCreateError(err));
            const handle = ipc.handles.installEndpoint(pid, ep) catch |err| return switch (err) {
                error.NotInitialized => retErr(.NODEV),
                error.OutOfMemory => retErr(.NOMEM),
                error.OutOfHandles => retErr(.AGAIN),
                error.PermissionDenied, error.InvalidEndpoint => retErr(.BADF),
            };
            return @as(u64, handle);
        },
        @intFromEnum(sc.Number.ipc_send) => {
            const endpoint_handle = parseHandle(frame.rdi) orelse return retErr(.INVAL);
            const msg = parseMsgPtrConst(frame.rsi) orelse return retErr(.FAULT);
            const pid = process.currentPid();
            const ep_id = ipc.handles.resolveEndpoint(pid, endpoint_handle, ipc.handles.Rights.send) orelse return retErr(.BADF);

            ipc.send(ep_id, msg) catch |err| return retErr(mapEndpointError(err));
            return 0;
        },
        @intFromEnum(sc.Number.ipc_receive) => {
            const endpoint_handle = parseHandle(frame.rdi) orelse return retErr(.INVAL);
            const out_msg = parseMsgPtr(frame.rsi) orelse return retErr(.FAULT);
            const pid = process.currentPid();
            const ep_id = ipc.handles.resolveEndpoint(pid, endpoint_handle, ipc.handles.Rights.receive) orelse return retErr(.BADF);

            const res = ipc.receive(ep_id) catch |err| return retErr(mapEndpointError(err));
            out_msg.* = res.msg;

            if (frame.rdx != 0) {
                const out_caller: *u64 = @ptrFromInt(frame.rdx);
                if (res.caller) |caller| {
                    const caller_handle = ipc.handles.installCaller(pid, caller) catch |err| return switch (err) {
                        error.OutOfMemory => retErr(.NOMEM),
                        error.OutOfHandles => retErr(.AGAIN),
                        else => retErr(.INVAL),
                    };
                    out_caller.* = caller_handle;
                } else {
                    out_caller.* = 0;
                }
            }

            return 0;
        },
        @intFromEnum(sc.Number.ipc_call) => {
            const endpoint_handle = parseHandle(frame.rdi) orelse return retErr(.INVAL);
            const req = parseMsgPtrConst(frame.rsi) orelse return retErr(.FAULT);
            const reply = parseMsgPtr(frame.rdx) orelse return retErr(.FAULT);
            const pid = process.currentPid();
            const ep_id = ipc.handles.resolveEndpoint(pid, endpoint_handle, ipc.handles.Rights.call) orelse return retErr(.BADF);

            ipc.call(ep_id, req, reply) catch |err|
                return retErr(mapEndpointError(err));
            return 0;
        },
        @intFromEnum(sc.Number.ipc_reply) => {
            const caller_handle = parseHandle(frame.rdi) orelse return retErr(.INVAL);
            const reply = parseMsgPtrConst(frame.rsi) orelse return retErr(.FAULT);
            const pid = process.currentPid();
            const caller = ipc.handles.consumeCaller(pid, caller_handle) orelse return retErr(.BADF);

            ipc.reply(caller, reply);
            return 0;
        },
        else => return retErr(.NOSYS),
    }
}
