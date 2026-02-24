const lib = @import("lib");
const sc = lib.syscall;
const ipc = lib.ipc;

const KERNEL_PTR: u64 = 0xffff_8000_0000_0000;

const ROLE_SERVER: u64 = 1;
const ROLE_CALLER: u64 = 2;

const SCENARIO_MISSING_CALLER_OUT: u64 = 1;
const SCENARIO_REPLY_FAULT_RETRY: u64 = 2;

pub export fn _start(role: u64, endpoint: u64, scenario: u64) callconv(.c) noreturn {
    switch (role) {
        ROLE_SERVER => runServer(endpoint, scenario),
        ROLE_CALLER => runCaller(endpoint, scenario),
        else => lib.writeFmt("IPC-CONF invalid role={}\n", .{role}),
    }

    while (true) sc.sysSchedYield();
}

fn runServer(endpoint: u64, scenario: u64) void {
    switch (scenario) {
        SCENARIO_MISSING_CALLER_OUT => scenarioServerMissingCallerOut(endpoint),
        SCENARIO_REPLY_FAULT_RETRY => scenarioServerReplyFaultRetry(endpoint),
        else => lib.writeFmt("IPC-CONF server unknown scenario={}\n", .{scenario}),
    }
}

fn runCaller(endpoint: u64, scenario: u64) void {
    switch (scenario) {
        SCENARIO_MISSING_CALLER_OUT => scenarioCallerMissingCallerOut(endpoint),
        SCENARIO_REPLY_FAULT_RETRY => scenarioCallerReplyFaultRetry(endpoint),
        else => lib.writeFmt("IPC-CONF caller unknown scenario={}\n", .{scenario}),
    }
}

fn scenarioServerMissingCallerOut(endpoint: u64) void {
    var req: ipc.Message = .{};
    const rc = sysIpcReceiveRaw(endpoint, @intFromPtr(&req), 0);
    if (isErrno(rc, .INVAL)) {
        lib.writeLit("IPC-CONF S1 SERVER PASS\n");
    } else {
        lib.writeFmt("IPC-CONF S1 SERVER FAIL rc=0x{x}\n", .{rc});
    }
}

fn scenarioCallerMissingCallerOut(endpoint: u64) void {
    var req = ipc.Message.init(0x41, 0);
    var reply: ipc.Message = .{};
    const rc = sysIpcCallRaw(endpoint, @intFromPtr(&req), @intFromPtr(&reply));

    if (isErr(rc)) {
        lib.writeLit("IPC-CONF S1 CALLER PASS\n");
    } else {
        lib.writeFmt("IPC-CONF S1 CALLER FAIL rc=0x{x}\n", .{rc});
    }
}

fn scenarioServerReplyFaultRetry(endpoint: u64) void {
    var req: ipc.Message = .{};
    var caller: u64 = 0;
    const recv_rc = sysIpcReceiveRaw(endpoint, @intFromPtr(&req), @intFromPtr(&caller));
    if (isErr(recv_rc) or caller == 0) {
        lib.writeFmt("IPC-CONF S2 SERVER FAIL recv=0x{x} caller={}\n", .{ recv_rc, caller });
        return;
    }

    const r0 = sysIpcReplyRaw(caller, KERNEL_PTR);
    if (!isErrno(r0, .FAULT)) {
        lib.writeFmt("IPC-CONF S2 SERVER FAIL bad-reply rc=0x{x}\n", .{r0});
        return;
    }

    var rep = ipc.Message.init(0x77, 0);
    const r1 = sysIpcReplyRaw(caller, @intFromPtr(&rep));
    if (isErr(r1)) {
        lib.writeFmt("IPC-CONF S2 SERVER FAIL good-reply rc=0x{x}\n", .{r1});
        return;
    }

    lib.writeLit("IPC-CONF S2 SERVER PASS\n");
}

fn scenarioCallerReplyFaultRetry(endpoint: u64) void {
    var req = ipc.Message.init(0x55, 0);
    var reply: ipc.Message = .{};
    const rc = sysIpcCallRaw(endpoint, @intFromPtr(&req), @intFromPtr(&reply));
    if (isErr(rc)) {
        lib.writeFmt("IPC-CONF S2 CALLER FAIL call rc=0x{x}\n", .{rc});
        return;
    }

    if (reply.label() != 0x77) {
        lib.writeFmt("IPC-CONF S2 CALLER FAIL reply-label=0x{x}\n", .{reply.label()});
        return;
    }
    lib.writeLit("IPC-CONF S2 CALLER PASS\n");
}

fn isErr(ret: u64) bool {
    return @as(i64, @bitCast(ret)) < 0;
}

fn errnoOf(ret: u64) i64 {
    const v: i64 = @bitCast(ret);
    return -v;
}

fn isErrno(ret: u64, e: sc.Errno) bool {
    return isErr(ret) and errnoOf(ret) == @intFromEnum(e);
}

fn sysIpcCallRaw(ep: u64, req_ptr: u64, reply_ptr: u64) u64 {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> u64),
        : [num] "{rax}" (@intFromEnum(sc.Number.ipc_call)),
          [ep] "{rdi}" (ep),
          [req] "{rsi}" (req_ptr),
          [reply] "{rdx}" (reply_ptr),
        : .{ .rcx = true, .r11 = true, .memory = true });
}

fn sysIpcReceiveRaw(ep: u64, out_msg_ptr: u64, out_caller_ptr: u64) u64 {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> u64),
        : [num] "{rax}" (@intFromEnum(sc.Number.ipc_receive)),
          [ep] "{rdi}" (ep),
          [msg] "{rsi}" (out_msg_ptr),
          [caller] "{rdx}" (out_caller_ptr),
        : .{ .rcx = true, .r11 = true, .memory = true });
}

fn sysIpcReplyRaw(caller: u64, msg_ptr: u64) u64 {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> u64),
        : [num] "{rax}" (@intFromEnum(sc.Number.ipc_reply)),
          [caller] "{rdi}" (caller),
          [msg] "{rsi}" (msg_ptr),
        : .{ .rcx = true, .r11 = true, .memory = true });
}
