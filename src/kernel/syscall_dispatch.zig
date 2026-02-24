const std = @import("std");
const arch = @import("arch");
const shared = @import("shared");

const uaccess = @import("uaccess.zig");
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

fn retErr(code: sc.Errno) u64 {
    return sc.encodeErrno(code);
}

fn parseHandle(raw: u64) ?IpcHandle {
    return std.math.cast(IpcHandle, raw);
}

fn parseShmId(raw: u64) ?shm.ShmId {
    return std.math.cast(shm.ShmId, raw);
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

            const task = sched.currentTask() orelse return retErr(.INVAL);

            var total_read: usize = 0;

            var kbuf: [256]u8 = undefined;

            while (total_read < len) {
                const remaining = len - total_read;
                const chunk_len = @min(remaining, kbuf.len);

                const n = keyboard.readBlocking(kbuf[0..chunk_len], task);

                if (n == 0) break;

                const user_dest = std.math.add(u64, buf_ptr, @as(u64, @intCast(total_read))) catch return retErr(.FAULT);

                if (!uaccess.copyToUser(task, user_dest, kbuf[0..n])) {
                    return retErr(.FAULT);
                }

                total_read += n;
                break;
            }
            return @as(u64, @intCast(total_read));
        },
        @intFromEnum(sc.Number.sys_write) => {
            const fd = arg0;
            const buf_ptr = arg1;
            const len: usize = std.math.cast(usize, arg2) orelse return retErr(.INVAL);
            if (badFd(fd, false)) return retErr(.BADF);
            if (buf_ptr == 0 and len != 0) return retErr(.FAULT);

            const task = sched.currentTask() orelse return retErr(.INVAL);

            var total: usize = 0;
            var kbuf: [256]u8 = undefined;

            while (total < len) {
                const n = @min(len - total, kbuf.len);
                const src_addr = std.math.add(u64, buf_ptr, @as(u64, @intCast(total))) catch return retErr(.FAULT);
                if (!uaccess.copyFromUser(task, kbuf[0..n], src_addr)) return retErr(.FAULT);

                arch.serial.write(kbuf[0..n]);
                console.write(kbuf[0..n]);
                total += n;
            }
            return @as(u64, @intCast(total));
        },
        @intFromEnum(sc.Number.ipc_create_endpoint) => {
            const pid = process.currentPid();
            const ep = ipc.createEndpoint(pid) catch |err| return retErr(mapCreateError(err));
            const handle = ipc.handles.installEndpoint(pid, ep) catch |err| return switch (err) {
                error.NotInitialized => blk: {
                    _ = ipc.destroyEndpoint(ep, pid) catch {};
                    break :blk retErr(.NODEV);
                },
                error.OutOfMemory => blk: {
                    _ = ipc.destroyEndpoint(ep, pid) catch {};
                    break :blk retErr(.NOMEM);
                },
                error.OutOfHandles => blk: {
                    _ = ipc.destroyEndpoint(ep, pid) catch {};
                    break :blk retErr(.AGAIN);
                },
                error.PermissionDenied, error.InvalidEndpoint => blk: {
                    _ = ipc.destroyEndpoint(ep, pid) catch {};
                    break :blk retErr(.BADF);
                },
            };
            return @as(u64, handle);
        },
        @intFromEnum(sc.Number.ipc_send) => {
            const endpoint_handle = parseHandle(arg0) orelse return retErr(.INVAL);
            const pid = process.currentPid();
            const ep_tok = ipc.handles.resolveEndpoint(pid, endpoint_handle, ipc.handles.Rights.send) orelse return retErr(.BADF);

            var req: ipc.Message = undefined;
            const task = sched.currentTask() orelse return retErr(.INVAL);
            if (!uaccess.copyFromUserValue(ipc.Message, task, arg1, &req)) return retErr(.FAULT);
            ipc.send(ep_tok, &req) catch |err| return retErr(mapEndpointError(err));
            return 0;
        },
        @intFromEnum(sc.Number.ipc_receive) => {
            const endpoint_handle = parseHandle(arg0) orelse return retErr(.INVAL);
            const pid = process.currentPid();
            const ep_tok = ipc.handles.resolveEndpoint(pid, endpoint_handle, ipc.handles.Rights.receive) orelse return retErr(.BADF);

            const task = sched.currentTask() orelse return retErr(.INVAL);
            const res = ipc.receive(ep_tok) catch |err| return retErr(mapEndpointError(err));
            if (!uaccess.copyToUserValue(ipc.Message, task, arg1, &res.msg)) {
                if (res.caller) |caller| ipc.abortCaller(caller);
                return retErr(.FAULT);
            }

            var caller_handle_out: u64 = 0;
            if (res.caller) |caller| {
                if (arg2 == 0) {
                    ipc.abortCaller(caller);
                    return retErr(.INVAL);
                }

                const caller_handle = ipc.handles.installCaller(pid, caller) catch |err| return switch (err) {
                    error.OutOfMemory => blk: {
                        ipc.abortCaller(caller);
                        break :blk retErr(.NOMEM);
                    },
                    error.OutOfHandles => blk: {
                        ipc.abortCaller(caller);
                        break :blk retErr(.AGAIN);
                    },
                    else => blk: {
                        ipc.abortCaller(caller);
                        break :blk retErr(.INVAL);
                    },
                };
                caller_handle_out = caller_handle;
                if (!uaccess.copyToUserValue(u64, task, arg2, &caller_handle_out)) {
                    _ = ipc.handles.consumeCaller(pid, caller_handle);
                    ipc.abortCaller(caller);
                    return retErr(.FAULT);
                }
            } else if (arg2 != 0) {
                if (!uaccess.copyToUserValue(u64, task, arg2, &caller_handle_out)) {
                    return retErr(.FAULT);
                }
            }
            return 0;
        },
        @intFromEnum(sc.Number.ipc_call) => {
            const endpoint_handle = parseHandle(arg0) orelse return retErr(.INVAL);
            const pid = process.currentPid();
            const ep_tok = ipc.handles.resolveEndpoint(pid, endpoint_handle, ipc.handles.Rights.call) orelse return retErr(.BADF);
            const task = sched.currentTask() orelse return retErr(.INVAL);
            var req: ipc.Message = undefined;
            if (!uaccess.copyFromUserValue(ipc.Message, task, arg1, &req)) return retErr(.FAULT);

            var reply: ipc.Message = undefined;
            ipc.call(ep_tok, &req, &reply) catch |err| return retErr(mapEndpointError(err));

            const curr = sched.currentTask() orelse return retErr(.INVAL);
            reply = curr.ipc.msg;
            if (!uaccess.copyToUserValue(ipc.Message, task, arg2, &reply)) return retErr(.FAULT);
            return 0;
        },
        @intFromEnum(sc.Number.ipc_reply) => {
            const caller_handle = parseHandle(arg0) orelse return retErr(.INVAL);
            const pid = process.currentPid();
            const task = sched.currentTask() orelse return retErr(.INVAL);

            var reply: ipc.Message = undefined;
            if (!uaccess.copyFromUserValue(ipc.Message, task, arg1, &reply)) return retErr(.FAULT);
            const caller = ipc.handles.consumeCaller(pid, caller_handle) orelse return retErr(.BADF);
            ipc.reply(caller, &reply);
            return 0;
        },
        @intFromEnum(sc.Number.ipc_destroy_endpoint) => {
            const endpoint_handle = parseHandle(arg0) orelse return retErr(.INVAL);
            const pid = process.currentPid();
            const ep_tok = ipc.handles.resolveEndpoint(pid, endpoint_handle, ipc.handles.Rights.send) orelse return retErr(.BADF);

            ipc.destroyEndpoint(ep_tok, pid) catch |err| return switch (err) {
                error.InvalidEndpoint => retErr(.BADF),
                error.PermissionDenied => retErr(.BADF),
                error.NotInitialized => retErr(.NODEV),
            };
            return 0;
        },
        @intFromEnum(sc.Number.ipc_notify) => {
            const endpoint_handle = parseHandle(arg0) orelse return retErr(.INVAL);
            const pid = process.currentPid();
            const ep_tok = ipc.handles.resolveEndpoint(pid, endpoint_handle, ipc.handles.Rights.send) orelse return retErr(.BADF);

            ipc.notify(ep_tok) catch |err| return retErr(mapEndpointError(err));
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
