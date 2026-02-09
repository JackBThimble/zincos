const std = @import("std");
const arch = @import("arch");
const shared = @import("shared");

const ipc = @import("ipc/mod.zig");
const sched = @import("sched/core.zig");
const Task = @import("sched/task.zig").Task;

const sc = shared.syscall;
const SyscallFrame = arch.syscall.SyscallFrame;

fn retErr(code: sc.Errno) u64 {
    return sc.encodeErrno(code);
}

fn parseEndpointId(raw: u64) ?ipc.EndpointId {
    return std.math.cast(ipc.EndpointId, raw);
}

fn parseTaskPtr(raw: u64) ?*Task {
    if (raw == 0) return null;
    return @ptrFromInt(raw);
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
        @intFromEnum(sc.Number.ipc_create_endpoint) => {
            const ep = ipc.createEndpoint() catch |err| return retErr(mapCreateError(err));
            return @as(u64, ep);
        },
        @intFromEnum(sc.Number.ipc_send) => {
            const ep_id = parseEndpointId(frame.rdi) orelse return retErr(.INVAL);
            const msg = parseMsgPtrConst(frame.rsi) orelse return retErr(.FAULT);

            ipc.send(ep_id, msg) catch |err| return retErr(mapEndpointError(err));
            return 0;
        },
        @intFromEnum(sc.Number.ipc_receive) => {
            const ep_id = parseEndpointId(frame.rdi) orelse return retErr(.INVAL);
            const out_msg = parseMsgPtr(frame.rsi) orelse return retErr(.FAULT);

            const res = ipc.receive(ep_id) catch |err| return retErr(mapEndpointError(err));
            out_msg.* = res.msg;

            if (frame.rdx != 0) {
                const out_caller: *u64 = @ptrFromInt(frame.rdx);
                out_caller.* = if (res.caller) |caller| @intFromPtr(caller) else 0;
            }

            return 0;
        },
        @intFromEnum(sc.Number.ipc_call) => {
            const ep_id = parseEndpointId(frame.rdi) orelse return retErr(.INVAL);
            const req = parseMsgPtrConst(frame.rsi) orelse return retErr(.FAULT);
            const reply = parseMsgPtr(frame.rdx) orelse return retErr(.FAULT);

            ipc.call(ep_id, req, reply) catch |err| return retErr(mapEndpointError(err));
            return 0;
        },
        @intFromEnum(sc.Number.ipc_reply) => {
            const caller = parseTaskPtr(frame.rdi) orelse return retErr(.FAULT);
            const reply = parseMsgPtrConst(frame.rsi) orelse return retErr(.FAULT);

            ipc.reply(caller, reply);
            return 0;
        },
        else => return retErr(.NOSYS),
    }
}
