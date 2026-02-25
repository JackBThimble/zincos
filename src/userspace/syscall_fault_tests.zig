const lib = @import("lib");
const sc = lib.syscall;
const ipc = lib.ipc;

const KERNEL_PTR: u64 = 0xffff_8000_0000_0000;
const OVERFLOW_PTR: u64 = 0xffff_ffff_ffff_fff0;

pub export fn _start() callconv(.c) noreturn {
    run();
    terminateSelf();
}

fn terminateSelf() noreturn {
    asm volatile ("ud2");
    unreachable;
}

fn run() void {
    var passed: usize = 0;
    var failed: usize = 0;
    var skipped: usize = 0;

    check(testSysWriteKernelPtr(), "sys_write kernel ptr", &passed, &failed);
    check(testSysWriteOverflowPtr(), "sys_write overflow ptr", &passed, &failed);
    check(testSysWriteNullPtr(), "sys_write null ptr", &passed, &failed);
    check(testIpcSendBadMsgPtr(), "ipc_send bad msg ptr", &passed, &failed);
    check(testIpcCallBadReqPtr(), "ipc_call bad req ptr", &passed, &failed);
    check(testIpcReceiveBadOutMsgPtr(), "ipc_receive bad out msg ptr", &passed, &failed);
    check(testIpcReceiveBadCallerOutPtr(), "ipc_receive bad caller out ptr", &passed, &failed);
    check(testSysWriteValid(), "sys_write valid", &passed, &failed);
    check(testIpcNotifyReceiveValid(), "ipc notify/receive valid", &passed, &failed);
    check(testIpcDestroyStaleHandle(), "ipc destroy stale handle", &passed, &failed);
    check(testIpcDestroyDoubleDestroy(), "ipc destroy double", &passed, &failed);
    check(testIpcCallClosedEndpoint(), "ipc_call closed endpoint", &passed, &failed);

    skip("ipc_receive call missing caller out (needs 2 procs)", &skipped);
    skip("ipc_reply bad ptr keeps caller handle (needs 2 procs)", &skipped);

    lib.writeFmt("fault-tests: passed={} failed={} skipped={}\n", .{
        passed,
        failed,
        skipped,
    });
    if (failed == 0) {
        lib.writeLit("ALL TESTS PASS\n");
    } else {
        lib.writeLit("TESTS FAILED\n");
    }
}

fn skip(name: []const u8, skipped: *usize) void {
    skipped.* += 1;
    lib.writeLit("SKIP ");
    writeBytes(name);
    lib.writeLit("\n");
}

fn check(ok: bool, name: []const u8, passed: *usize, failed: *usize) void {
    if (ok) {
        passed.* += 1;
        lib.writeLit("PASS ");
        writeBytes(name);
        lib.writeLit("\n");
    } else {
        failed.* += 1;
        lib.writeLit("FAIL ");
        writeBytes(name);
        lib.writeLit("\n");
    }
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

fn testIpcCallClosedEndpoint() bool {
    return isErr(sysIpcCall(0xffff_ffff, KERNEL_PTR, KERNEL_PTR));
}

fn sysIpcDestroyEndpoint(ep: u64) u64 {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> u64),
        : [num] "{rax}" (@intFromEnum(sc.Number.ipc_destroy_endpoint)),
          [ep] "{rdi}" (ep),
        : .{ .rcx = true, .r11 = true, .memory = true });
}

fn testIpcDestroyStaleHandle() bool {
    const ep = sysIpcCreateEndpoint();
    if (isErr(ep) or ep == 0) return false;

    const d0 = sysIpcDestroyEndpoint(ep);
    if (isErr(d0)) return false;

    const s = sysIpcSend(ep, KERNEL_PTR);
    return isErr(s);
}

fn testIpcDestroyDoubleDestroy() bool {
    const ep = sysIpcCreateEndpoint();
    if (isErr(ep) or ep == 0) return false;

    const d0 = sysIpcDestroyEndpoint(ep);
    if (isErr(d0)) return false;

    const d1 = sysIpcDestroyEndpoint(ep);
    return isErr(d1);
}

fn testSysWriteKernelPtr() bool {
    const ret = sysWriteRaw(1, KERNEL_PTR, 16);
    return isErrno(ret, .FAULT);
}

fn testSysWriteOverflowPtr() bool {
    const ret = sysWriteRaw(1, OVERFLOW_PTR, 64);
    return isErrno(ret, .FAULT);
}

fn testSysWriteNullPtr() bool {
    const ret = sysWriteRaw(1, 0, 1);
    return isErrno(ret, .FAULT);
}

fn testIpcSendBadMsgPtr() bool {
    const ep = sysIpcCreateEndpoint();
    if (isErr(ep) or ep == 0) return false;

    const ret = sysIpcSend(ep, KERNEL_PTR);
    defer _ = sysIpcDestroyEndpoint(ep);
    return isErrno(ret, .FAULT);
}

fn testIpcCallBadReqPtr() bool {
    const ep = sysIpcCreateEndpoint();
    if (isErr(ep) or ep == 0) return false;

    var reply: ipc.Message = .{};
    const ret = sysIpcCall(ep, KERNEL_PTR, @intFromPtr(&reply));
    defer _ = sysIpcDestroyEndpoint(ep);
    return isErrno(ret, .FAULT);
}

// Uses notify first so receive returns immediately (no blocking sender needed).
fn testIpcReceiveBadOutMsgPtr() bool {
    const ep = sysIpcCreateEndpoint();
    if (isErr(ep) or ep == 0) return false;

    if (isErr(sysIpcNotify(ep))) return false;

    const ret = sysIpcReceive(ep, KERNEL_PTR, 0);
    defer _ = sysIpcDestroyEndpoint(ep);
    return isErrno(ret, .FAULT);
}

// Also uses notify; out_msg valid, caller_out invalid.
fn testIpcReceiveBadCallerOutPtr() bool {
    const ep = sysIpcCreateEndpoint();
    if (isErr(ep) or ep == 0) return false;

    if (isErr(sysIpcNotify(ep))) return false;

    var out_msg: ipc.Message = .{};
    const ret = sysIpcReceive(ep, @intFromPtr(&out_msg), KERNEL_PTR);
    defer _ = sysIpcDestroyEndpoint(ep);
    return isErrno(ret, .FAULT);
}

fn testSysWriteValid() bool {
    const s = "ok\n";
    const ret = sysWriteRaw(1, @intFromPtr(s.ptr), s.len);
    return !isErr(ret) and ret == s.len;
}

fn testIpcNotifyReceiveValid() bool {
    const ep = sysIpcCreateEndpoint();
    if (isErr(ep) or ep == 0) return false;

    if (isErr(sysIpcNotify(ep))) return false;

    var out_msg: ipc.Message = .{};
    var caller_out: u64 = 12345;
    const ret = sysIpcReceive(ep, @intFromPtr(&out_msg), @intFromPtr(&caller_out));
    if (isErr(ret)) return false;
    if (caller_out != 0) return false; // notify has no caller
    defer _ = sysIpcDestroyEndpoint(ep);
    return true;
}

// -------------------- syscall wrappers --------------------

fn sysWriteRaw(fd: u64, buf: u64, len: usize) u64 {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> u64),
        : [num] "{rax}" (@intFromEnum(sc.Number.sys_write)),
          [fd] "{rdi}" (fd),
          [buf] "{rsi}" (buf),
          [len] "{rdx}" (@as(u64, @intCast(len))),
        : .{ .rcx = true, .r11 = true, .memory = true });
}

fn sysIpcCreateEndpoint() u64 {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> u64),
        : [num] "{rax}" (@intFromEnum(sc.Number.ipc_create_endpoint)),
        : .{ .rcx = true, .r11 = true, .memory = true });
}

fn sysIpcSend(ep: u64, msg_ptr: u64) u64 {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> u64),
        : [num] "{rax}" (@intFromEnum(sc.Number.ipc_send)),
          [ep] "{rdi}" (ep),
          [msg] "{rsi}" (msg_ptr),
        : .{ .rcx = true, .r11 = true, .memory = true });
}

fn sysIpcReceive(ep: u64, out_msg_ptr: u64, out_caller_ptr: u64) u64 {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> u64),
        : [num] "{rax}" (@intFromEnum(sc.Number.ipc_receive)),
          [ep] "{rdi}" (ep),
          [out_msg] "{rsi}" (out_msg_ptr),
          [out_caller] "{rdx}" (out_caller_ptr),
        : .{ .rcx = true, .r11 = true, .memory = true });
}

fn sysIpcCall(ep: u64, req_ptr: u64, reply_ptr: u64) u64 {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> u64),
        : [num] "{rax}" (@intFromEnum(sc.Number.ipc_call)),
          [ep] "{rdi}" (ep),
          [req] "{rsi}" (req_ptr),
          [reply] "{rdx}" (reply_ptr),
        : .{ .rcx = true, .r11 = true, .memory = true });
}

fn sysIpcNotify(ep: u64) u64 {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> u64),
        : [num] "{rax}" (@intFromEnum(sc.Number.ipc_notify)),
          [ep] "{rdi}" (ep),
        : .{ .rcx = true, .r11 = true, .memory = true });
}

fn sysSchedYield() void {
    _ = asm volatile ("syscall"
        : [ret] "={rax}" (-> u64),
        : [num] "{rax}" (@intFromEnum(sc.Number.sched_yield)),
        : .{ .rcx = true, .r11 = true, .memory = true });
}

fn writeBytes(s: []const u8) void {
    _ = sysWriteRaw(1, @intFromPtr(s.ptr), s.len);
}
