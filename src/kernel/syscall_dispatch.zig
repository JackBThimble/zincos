const std = @import("std");
const arch = @import("arch");
const shared = @import("shared");
const mm = @import("mm");

const ipc = @import("ipc/mod.zig");
const console = @import("console.zig");
const keyboard = @import("keyboard.zig");
const process = @import("process/mod.zig");
const sched = @import("sched/core.zig");
const shm = @import("shm.zig");
const initrd_boot = @import("initrd_boot.zig");
const IpcHandle = ipc.handles.Handle;

const sc = shared.syscall;
const SyscallContext = arch.syscall.SyscallContext;

const SERIAL_STDIN_FD: u64 = 0;
const SERIAL_STDOUT_FD: u64 = 1;
const SERIAL_STDERR_FD: u64 = 2;

const USER_ADDR_MAX: u64 = mm.address_space.USER_ADDR_MAX;

const IPC_MSG_SIZE: usize = @sizeOf(ipc.Message);

fn retErr(code: sc.Errno) u64 {
    return sc.encodeErrno(code);
}

fn parseHandle(raw: u64) ?IpcHandle {
    return std.math.cast(IpcHandle, raw);
}

fn parseShmId(raw: u64) ?shm.ShmId {
    return std.math.cast(shm.ShmId, raw);
}

fn parseMsgPtr(raw: u64) ?*ipc.Message {
    if (!validateUserRange(raw, @sizeOf(ipc.Message))) return null;
    return @ptrFromInt(raw);
}

fn parseMsgPtrConst(raw: u64) ?*const ipc.Message {
    if (!validateUserRange(raw, @sizeOf(ipc.Message))) return null;
    return @ptrFromInt(raw);
}

fn validateUserRange(raw: u64, len: usize) bool {
    if (raw == 0) return len == 0;
    if (raw > USER_ADDR_MAX) return false;
    if (len == 0) return true;

    const last = std.math.add(u64, raw, @as(u64, @intCast(len - 1))) catch return false;
    return last <= USER_ADDR_MAX;
}

fn validateUserBuffer(raw: u64, len: usize, write: bool) bool {
    if (!validateUserRange(raw, len)) return false;
    if (len == 0) return true;

    const task = sched.currentTask() orelse return false;
    const as = task.addr_space orelse return false;
    return as.isUserRangeAccessible(raw, len, write);
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

fn mapShmError(err: anyerror) sc.Errno {
    return switch (err) {
        error.NotInitialized => .NODEV,
        error.OutOfMemory => .NOMEM,
        error.InvalidSegment, error.InvalidSize, error.UnalignedAddress, error.NotMapped, error.MappingCorrupted => .INVAL,
        error.PermissionDenied => .BADF,
        error.OutOfIds, error.OutOfHandles, error.Busy, error.AlreadyMapped => .AGAIN,
        else => .INVAL,
    };
}

fn badFd(fd: u64, for_read: bool) bool {
    if (for_read) return fd != SERIAL_STDIN_FD;
    return fd != SERIAL_STDOUT_FD and fd != SERIAL_STDERR_FD;
}

/// Kernel-side syscall implementation.
/// Called indirectly from arch.syscall.syscall_dispatch.
pub export fn kernel_syscall_dispatch(ctx: *SyscallContext) callconv(.c) u64 {
    const arg0 = arch.syscall.arg(ctx, 0);
    const arg1 = arch.syscall.arg(ctx, 1);
    const arg2 = arch.syscall.arg(ctx, 2);

    switch (arch.syscall.number(ctx)) {
        @intFromEnum(sc.Number.nop) => return 0,
        @intFromEnum(sc.Number.get_cpu_id) => return @as(u64, arch.percpu.getCpuId()),
        @intFromEnum(sc.Number.sched_yield) => {
            sched.yield();
            return 0;
        },
        @intFromEnum(sc.Number.get_pid) => return @as(u64, process.currentPid()),
        @intFromEnum(sc.Number.sys_read) => {
            const fd = arg0;
            const buf_ptr = arg1;
            const len: usize = std.math.cast(usize, arg2) orelse return retErr(.INVAL);

            if (badFd(fd, true)) return retErr(.BADF);
            if (buf_ptr == 0) return retErr(.FAULT);
            if (len == 0) return 0;
            if (!validateUserRange(buf_ptr, len)) return retErr(.FAULT);
            if (!validateUserBuffer(buf_ptr, len, true)) return retErr(.FAULT);

            const out: [*]u8 = @ptrFromInt(buf_ptr);
            const task = sched.currentTask() orelse return retErr(.INVAL);
            return keyboard.readBlocking(out[0..len], task);
        },
        @intFromEnum(sc.Number.sys_write) => {
            const fd = arg0;
            const buf_ptr = arg1;
            const len: usize = std.math.cast(usize, arg2) orelse return retErr(.INVAL);
            if (badFd(fd, false)) return retErr(.BADF);
            if (buf_ptr == 0 and len != 0) return retErr(.FAULT);
            if (!validateUserRange(buf_ptr, len)) return retErr(.FAULT);
            if (!validateUserBuffer(buf_ptr, len, false)) return retErr(.FAULT);

            const bytes: []const u8 = @as([*]const u8, @ptrFromInt(buf_ptr))[0..len];
            arch.serial.write(bytes);
            console.write(bytes);
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
            const endpoint_handle = parseHandle(arg0) orelse return retErr(.INVAL);
            const msg = parseMsgPtrConst(arg1) orelse return retErr(.FAULT);
            if (!validateUserBuffer(@intFromPtr(msg), IPC_MSG_SIZE, false)) return retErr(.FAULT);
            const pid = process.currentPid();
            const ep_id = ipc.handles.resolveEndpoint(pid, endpoint_handle, ipc.handles.Rights.send) orelse return retErr(.BADF);

            ipc.send(ep_id, msg) catch |err| return retErr(mapEndpointError(err));
            return 0;
        },
        @intFromEnum(sc.Number.ipc_receive) => {
            const endpoint_handle = parseHandle(arg0) orelse return retErr(.INVAL);
            const out_msg = parseMsgPtr(arg1) orelse return retErr(.FAULT);
            if (!validateUserBuffer(@intFromPtr(out_msg), IPC_MSG_SIZE, true)) return retErr(.FAULT);
            const pid = process.currentPid();
            const ep_id = ipc.handles.resolveEndpoint(pid, endpoint_handle, ipc.handles.Rights.receive) orelse return retErr(.BADF);

            const res = ipc.receive(ep_id) catch |err| return retErr(mapEndpointError(err));
            out_msg.* = res.msg;

            if (arg2 != 0) {
                if (!validateUserRange(arg2, @sizeOf(u64))) return retErr(.FAULT);
                const out_caller: *u64 = @ptrFromInt(arg2);
                if (!validateUserBuffer(@intFromPtr(out_caller), @sizeOf(u64), true)) return retErr(.FAULT);
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
            const endpoint_handle = parseHandle(arg0) orelse return retErr(.INVAL);
            const req = parseMsgPtrConst(arg1) orelse return retErr(.FAULT);
            if (!validateUserBuffer(@intFromPtr(req), IPC_MSG_SIZE, false)) return retErr(.FAULT);
            const reply = parseMsgPtr(arg2) orelse return retErr(.FAULT);
            if (!validateUserBuffer(@intFromPtr(reply), IPC_MSG_SIZE, true)) return retErr(.FAULT);
            const pid = process.currentPid();
            const ep_id = ipc.handles.resolveEndpoint(pid, endpoint_handle, ipc.handles.Rights.call) orelse return retErr(.BADF);

            ipc.call(ep_id, req, reply) catch |err|
                return retErr(mapEndpointError(err));

            const task = sched.currentTask() orelse return retErr(.INVAL);
            reply.* = task.ipc.msg;
            return 0;
        },
        @intFromEnum(sc.Number.ipc_reply) => {
            const caller_handle = parseHandle(arg0) orelse return retErr(.INVAL);
            const reply = parseMsgPtrConst(arg1) orelse return retErr(.FAULT);
            if (!validateUserBuffer(@intFromPtr(reply), IPC_MSG_SIZE, false)) return retErr(.FAULT);
            const pid = process.currentPid();
            const caller = ipc.handles.consumeCaller(pid, caller_handle) orelse return retErr(.BADF);

            ipc.reply(caller, reply);
            return 0;
        },
        @intFromEnum(sc.Number.ipc_notify) => {
            const endpoint_handle = parseHandle(arg0) orelse return retErr(.INVAL);
            const pid = process.currentPid();
            const ep_id = ipc.handles.resolveEndpoint(pid, endpoint_handle, ipc.handles.Rights.send) orelse return retErr(.BADF);

            ipc.notify(ep_id) catch |err| return retErr(mapEndpointError(err));
            return 0;
        },
        @intFromEnum(sc.Number.shm_create) => {
            const size_bytes: usize = std.math.cast(usize, arg0) orelse return retErr(.INVAL);
            const pid = process.currentPid();
            const id = shm.create(pid, size_bytes) catch |err| return retErr(mapShmError(err));
            return @as(u64, id);
        },
        @intFromEnum(sc.Number.shm_grant) => {
            const id = parseShmId(arg0) orelse return retErr(.INVAL);
            const target_pid: process.ProcessId = std.math.cast(process.ProcessId, arg1) orelse return retErr(.INVAL);

            const pid = process.currentPid();
            shm.grant(id, pid, target_pid) catch |err| return retErr(mapShmError(err));
            return 0;
        },
        @intFromEnum(sc.Number.shm_map) => {
            const id = parseShmId(arg0) orelse return retErr(.INVAL);
            const virt = arg1;
            const pid = process.currentPid();
            const task = sched.currentTask() orelse return retErr(.INVAL);
            const as = task.addr_space orelse return retErr(.INVAL);
            shm.mapCurrent(id, pid, as, virt) catch |err| return retErr(mapShmError(err));
            return 0;
        },
        @intFromEnum(sc.Number.shm_unmap) => {
            const id = parseShmId(arg0) orelse return retErr(.INVAL);
            const virt = arg1;
            const pid = process.currentPid();
            const task = sched.currentTask() orelse return retErr(.INVAL);
            const as = task.addr_space orelse return retErr(.INVAL);
            shm.unmapCurrent(id, pid, as, virt) catch |err| return retErr(mapShmError(err));
            return 0;
        },
        @intFromEnum(sc.Number.shm_destroy) => {
            const id = parseShmId(arg0) orelse return retErr(.INVAL);
            const pid = process.currentPid();
            shm.destroy(id, pid) catch |err| return retErr(mapShmError(err));
            return 0;
        },
        @intFromEnum(sc.Number.vfs_get_bootstrap_endpoint) => {
            const pid = process.currentPid();
            if (pid == 0) return retErr(.NODEV);

            const endpoint = initrd_boot.getBootstrapVfsEndpoint() orelse return retErr(.NODEV);
            const rights = ipc.handles.Rights.call;
            const handle = ipc.handles.installEndpointInto(pid, endpoint, rights) catch |err| return switch (err) {
                error.NotInitialized => retErr(.NODEV),
                error.InvalidEndpoint => retErr(.NODEV),
                error.OutOfMemory => retErr(.NOMEM),
                error.OutOfHandles => retErr(.AGAIN),
            };
            return @as(u64, handle);
        },
        else => return retErr(.NOSYS),
    }
}
