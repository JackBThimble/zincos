const lib = @import("lib");
const sc = lib.syscall;
const ipc = lib.ipc;

const KERNEL_PTR: u64 = 0xffff_8000_0000_0000;

const ROLE_SERVER: u64 = 1;
const ROLE_CALLER: u64 = 2;

const SCENARIO_MISSING_CALLER_OUT: u64 = 1;
const SCENARIO_REPLY_FAULT_RETRY: u64 = 2;
const SCENARIO_STRESS_CALL_REPLY: u64 = 3;
const SCENARIO_DESTROY_RACE_STRESS: u64 = 4;

const STRESS_ITERS: u64 = 100000;
const STRESS_LABEL: u32 = 0x9000;
const DESTROY_RACE_ITERS: u64 = 50000;
const DESTROY_AT_ITER: u64 = DESTROY_RACE_ITERS / 2;
const DESTROY_RACE_LABEL: u32 = 0xa000;

pub export fn _start(role: u64, endpoint: u64, scenario: u64) callconv(.c) noreturn {
    switch (role) {
        ROLE_SERVER => runServer(endpoint, scenario),
        ROLE_CALLER => runCaller(endpoint, scenario),
        else => lib.writeFmt("IPC-CONF invalid role={}\n", .{role}),
    }

    sc.sysExit(0);
    unreachable;
}

fn runServer(endpoint: u64, scenario: u64) void {
    switch (scenario) {
        SCENARIO_MISSING_CALLER_OUT => scenarioServerMissingCallerOut(endpoint),
        SCENARIO_REPLY_FAULT_RETRY => scenarioServerReplyFaultRetry(endpoint),
        SCENARIO_STRESS_CALL_REPLY => scenarioServerStressCallReply(endpoint),
        SCENARIO_DESTROY_RACE_STRESS => scenarioServerDestroyRace(endpoint),
        else => lib.writeFmt("IPC-CONF server unknown scenario={}\n", .{scenario}),
    }
}

fn runCaller(endpoint: u64, scenario: u64) void {
    switch (scenario) {
        SCENARIO_MISSING_CALLER_OUT => scenarioCallerMissingCallerOut(endpoint),
        SCENARIO_REPLY_FAULT_RETRY => scenarioCallerReplyFaultRetry(endpoint),
        SCENARIO_STRESS_CALL_REPLY => scenarioCallerStressCallReply(endpoint),
        SCENARIO_DESTROY_RACE_STRESS => scenarioCallerDestroyRace(endpoint),
        else => lib.writeFmt("IPC-CONF caller unknown scenario={}\n", .{scenario}),
    }
}

// S1: server must reject call message when caller-out pointer is omitted
fn scenarioServerMissingCallerOut(endpoint: u64) void {
    var req: ipc.Message = .{};
    const rc = sysIpcReceiveRaw(endpoint, @intFromPtr(&req), 0);
    if (isErrno(rc, .INVAL)) {
        lib.writeLit("IPC-CONF S1 SERVER PASS\n");
    } else {
        lib.writeFmt("IPC-CONF S1 SERVER FAIL rc=0x{x}\n", .{rc});
    }
}

// S1 caller should wake with error (not hang) when server omits caller-out.
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

// S2: bad reply pointer must not consume caller capability.
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

fn scenarioServerStressCallReply(endpoint: u64) void {
    var i: u64 = 0;
    while (i < STRESS_ITERS) : (i += 1) {
        var req: ipc.Message = .{};
        var caller: u64 = 0;

        const recv_rc = sysIpcReceiveRaw(endpoint, @intFromPtr(&req), @intFromPtr(&caller));
        if (isErr(recv_rc) or caller == 0) {
            lib.writeFmt("IPC-CONF S3 SERVER FAIL recv i={} rc=0x{x} caller={}\n", .{
                i, recv_rc, caller,
            });
            return;
        }

        if (req.label() != STRESS_LABEL or req.data[0] != i) {
            lib.writeFmt("IPC-CONF S3 SERVER FAIL req i={} label=0x{x} data0={}\n", .{ i, req.label(), req.data[0] });
            return;
        }

        var rep = ipc.Message.init(STRESS_LABEL + 1, 1);
        rep.data[0] = i;
        const rep_rc = sysIpcReplyRaw(caller, @intFromPtr(&rep));
        if (isErr(rep_rc)) {
            lib.writeFmt("IPC-CONF S3 SERVER FAIL reply i={} rc=0x{x}\n", .{ i, rep_rc });
            return;
        }
    }

    lib.writeFmt("IPC-CONF S3 SERVER PASS iters={}\n", .{STRESS_ITERS});
}

// S3 caller: stress call loop validating reply payload.
fn scenarioCallerStressCallReply(endpoint: u64) void {
    var i: u64 = 0;
    while (i < STRESS_ITERS) : (i += 1) {
        var req = ipc.Message.init(STRESS_LABEL, 1);
        req.data[0] = i;
        var reply: ipc.Message = .{};

        const rc = sysIpcCallRaw(endpoint, @intFromPtr(&req), @intFromPtr(&reply));
        if (isErr(rc)) {
            lib.writeFmt("IPC-CONF S3 CALLER FAIL call i={} rc=0x{x}\n", .{ i, rc });
            return;
        }

        if (reply.label() != STRESS_LABEL + 1 or reply.data[0] != i) {
            lib.writeFmt(
                "IPC-CONF S3 CALLER FAIL reply i={} label=0x{x} data0={}\n",
                .{ i, reply.label(), reply.data[0] },
            );
            return;
        }
    }

    lib.writeFmt("IPC-CONF S3 CALLER PASS iters={}\n", .{STRESS_ITERS});
}

// S4: race endpoint destroy against in-flight calls; caller must
// wake with PIPE (not hang).
fn scenarioServerDestroyRace(endpoint: u64) void {
    var i: u64 = 0;
    while (i < DESTROY_AT_ITER) : (i += 1) {
        var req: ipc.Message = .{};
        var caller: u64 = 0;

        const recv_rc = sysIpcReceiveRaw(endpoint, @intFromPtr(&req), @intFromPtr(&caller));
        if (isErr(recv_rc) or caller == 0) {
            lib.writeFmt("IPC-CONF S4 SERVER FAIL recv i={} rc=0x{x} caller={}\n", .{
                i, recv_rc, caller,
            });
            return;
        }

        if (req.label() != DESTROY_RACE_LABEL or req.data[0] != i) {
            lib.writeFmt("IPC-CONF S4 SERVER FAIL req i={} label=0x{x} data0={}\n", .{
                i, req.label(), req.data[0],
            });
            return;
        }

        var rep = ipc.Message.init(DESTROY_RACE_LABEL + 1, 1);
        rep.data[0] = i;
        const rep_rc = sysIpcReplyRaw(caller, @intFromPtr(&rep));
        if (isErr(rep_rc)) {
            lib.writeFmt("IPC-CONF S4 SERVER FAIL reply i={} rc=0x{x}\n", .{ i, rep_rc });
            return;
        }
    }

    const d_rc = sysIpcDestroyEndpoint(endpoint);
    if (isErr(d_rc)) {
        lib.writeFmt("IPC-CONF S4 SERVER FAIL destroy rc=0x{x}\n", .{d_rc});
        return;
    }

    var req_after: ipc.Message = .{};
    var caller_after: u64 = 0;
    const recv_after = sysIpcReceiveRaw(endpoint, @intFromPtr(&req_after), @intFromPtr(&caller_after));
    if (!isEndpointGone(recv_after)) {
        lib.writeFmt("IPC-CONF S4 SERVER FAIL post-destroy receive not-gone rc=0x{x}\n", .{recv_after});
        return;
    }

    lib.writeFmt("IPC-CONF S4 SERVER PASS replied={} destroy_at={}\n", .{ DESTROY_AT_ITER, DESTROY_AT_ITER });
}

fn scenarioCallerDestroyRace(endpoint: u64) void {
    var ok_count: u64 = 0;
    var i: u64 = 0;
    while (i < DESTROY_RACE_ITERS) : (i += 1) {
        var req = ipc.Message.init(DESTROY_RACE_LABEL, 1);
        req.data[0] = i;
        var reply: ipc.Message = .{};

        const rc = sysIpcCallRaw(endpoint, @intFromPtr(&req), @intFromPtr(&reply));
        if (!isErr(rc)) {
            if (reply.label() != DESTROY_RACE_LABEL + 1 or reply.data[0] != i) {
                lib.writeFmt("IPC-CONF S4 CALLER FAIL reply i={} label=0x{x} data0={}\n", .{
                    i, reply.label(), reply.data[0],
                });
                return;
            }
            ok_count += 1;
            continue;
        }

        if (isEndpointGone(rc)) {
            if (ok_count != DESTROY_AT_ITER) {
                lib.writeFmt("IPC-CONF S4 CALLER FAIL ok_count={} expected={}\n", .{ ok_count, DESTROY_AT_ITER });
                return;
            }
            lib.writeFmt("IPC-CONF S4 CALLER PASS ok={} pipe_after={}\n", .{ ok_count, i });
            return;
        }
        lib.writeFmt("IPC-CONF S4 CALLER FAIL unexpected-not-gone rc=0x{x} i={}\n", .{ rc, i });
        return;
    }

    lib.writeFmt("IPC-CONF S4 CALLER FAIL no-PIPE ok={}\n", .{ok_count});
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

fn isEndpointGone(ret: u64) bool {
    return isErrno(ret, .PIPE) or isErrno(ret, .INVAL) or isErrno(ret, .BADF);
}

fn sysIpcDestroyEndpoint(ep: u64) u64 {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> u64),
        : [num] "{rax}" (@intFromEnum(sc.Number.ipc_destroy_endpoint)),
          [ep] "{rdi}" (ep),
        : .{ .rcx = true, .r11 = true, .memory = true });
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
